import Foundation
import Metal
import simd

/// Floating-point stroke-local pigment fields. R is deposited coverage, G is
/// pressure-weighted coverage. Blending uses the unweighted deposit as source
/// alpha, so repeated dabs build to the requested contribution, not past it.
final class BrushV2Session {
    let a: MTLTexture
    private(set) var b: MTLTexture?
    private(set) var range: MTLTexture?
    var initializedTiles: Set<Int> = []
    var initializedPigmentTiles: [Set<Int>] = [[], [], []]
    var stampCounts = [0, 0, 0]
    var lastVariants = [-1, -1, -1]
    var averageOpacity: [Float] = [0, 0, 0]

    init?(device: MTLDevice, width: Int, height: Int,
          needsSecondary: Bool = false, needsRange: Bool = false) {
        guard let a = Self.makePigmentTexture(device: device, width: width, height: height) else { return nil }
        self.a = a
        guard ensureFields(needsSecondary: needsSecondary, needsRange: needsRange) else { return nil }
    }

    /// Ordinary brushes need only A; most compound brushes need A and B.
    /// Retain allocated fields until stroke completion, including if a caller
    /// temporarily disables one. Each field initializes its own touched tiles.
    func ensureFields(needsSecondary: Bool, needsRange: Bool) -> Bool {
        let secondary = needsSecondary && b == nil
            ? Self.makePigmentTexture(device: a.device, width: a.width, height: a.height) : b
        let clipping = needsRange && range == nil
            ? Self.makePigmentTexture(device: a.device, width: a.width, height: a.height) : range
        guard !needsSecondary || secondary != nil, !needsRange || clipping != nil else { return false }
        b = secondary
        range = clipping
        return true
    }

    private static func makePigmentTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }
}

struct BrushV2Stamp {
    var center: SIMD2<Float>
    var radius: Float
    var rotation: Float
    var canvas: SIMD2<Float>
    var shape: UInt32
    var roundness: Float
    var flow: Float
    var contribution: Float
    var contrast: Float
    var softness: Float
    var averageOpacity: Float
}

private struct BrushV2Composite {
    var color: SIMD4<Float>
    var selectionBounds: SIMD4<Float>
    var mode: UInt32
    var clipRange: UInt32
    var selection: UInt32
    var alphaLock: UInt32
    var eraser: UInt32
    var compound: UInt32
    var material: UInt32
    var preservesAlpha: UInt32
}

final class BrushV2Renderer {
    private let device: MTLDevice
    private let stampPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let washPipeline: MTLComputePipelineState
    private let zeroTile: MTLTexture
    private let whiteTip: MTLTexture
    private var tips: [Data: MTLTexture] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Stamp { float2 center; float radius; float rotation; float2 canvas;
          uint shape; float roundness; float flow; float contribution; float contrast; float softness; float averageOpacity; };
        struct Out { float4 position [[position]]; float2 local; uint index [[flat]]; };
        vertex Out stampVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                               const device Stamp *stamps [[buffer(0)]]) {
          const float2 corners[4] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
          Stamp s = stamps[instance]; float2 q = corners[id];
          // A rotated square needs sqrt(2) extra bounds. Transform local UVs
          // back into the actual stamp, keeping the original image unwarped.
          float2 pixel = s.center + q * s.radius * 1.415;
          Out o; o.position = float4(pixel.x/s.canvas.x*2-1,1-pixel.y/s.canvas.y*2,0,1);
          o.local=q*1.415; o.index=instance; return o;
        }
        float sampleMask(Stamp s, float2 local, float aa, texture2d<float> tip) {
          float c=cos(s.rotation), sn=sin(s.rotation);
          float2 q=float2(c*local.x+sn*local.y,-sn*local.x+c*local.y);
          q.x/=max(s.roundness,0.05);
          if(any(abs(q)>1)) return 0;
          float mask;
          if(s.shape==3) {
            constexpr sampler smp(coord::normalized,address::clamp_to_zero,filter::linear);
            mask=tip.sample(smp,q*0.5+0.5).r;
            // Neutral contrast is exact source grayscale. Edge softness never
            // raises the entire imported image to an invisible exponent.
            mask=clamp((mask-0.5)*s.contrast+0.5,0.0,1.0);
            float edge=min(1-abs(q.x),1-abs(q.y));
            mask*=smoothstep(0.0,max(aa,s.softness*0.08),edge);
          } else if(s.shape==2) { mask=1; }
          else if(s.shape==1) { mask=pow(max(1-length(q),0.0),2.0); }
          else { mask=1-smoothstep(1-aa,1.0,length(q)); }
          return clamp(mask,0.0,1.0);
        }
        fragment float4 stampFragment(Out in [[stage_in]],
             const device Stamp *stamps [[buffer(0)]], texture2d<float> tip [[texture(0)]]) {
          Stamp s=stamps[in.index];
          float mask=sampleMask(s,in.local,max(fwidth(length(in.local)),0.001),tip);
          float deposit=clamp(mask*s.flow,0.0,1.0);
          // R = unweighted paint; G = contribution-limited paint.
          return float4(deposit,deposit*s.contribution,0,deposit);
        }
        // Ordered per-pixel wash accumulation. Unlike contribution-weighted
        // source-over, easing pressure cannot erase paint already laid down.
        // Flow interpolates toward the pressure-defined ceiling, independently
        // of the eventual A/B overlay. Each dispatch owns distinct pixels.
        kernel void washStamps(uint2 gid [[thread_position_in_grid]],
          constant uint4 &region [[buffer(0)]], constant uint &count [[buffer(1)]],
          const device Stamp *stamps [[buffer(2)]], texture2d<float> tip [[texture(0)]],
          texture2d<float,access::read_write> paint [[texture(1)]]) {
          if(any(gid>=region.zw)) return;
          uint2 xy=gid+region.xy; float2 value=paint.read(xy).rg;
          for(uint i=0;i<count;i++) {
            Stamp s=stamps[i]; float2 q=(float2(xy)+0.5-s.center)/s.radius;
            if(any(abs(q)>1.415)) continue;
            float mask=sampleMask(s,q,max(1.0/s.radius,0.001),tip);
            float target=s.contribution; float full=value.g;
            if(s.averageOpacity>target) {
              if(s.averageOpacity>value.g) {
                full=mix(mask*target,s.averageOpacity,value.g/max(s.averageOpacity,0.00001));
              }
            } else if(target>value.g) { full=mix(value.g,target,mask); }
            value.g=mix(value.g,full,s.flow);
            value.r+=mask*s.flow*(1-value.r);
            // Persist at the same precision after every dab, regardless of
            // whether the OS delivered one event or a coalesced packet.
            value=float2(half2(value));
          }
          paint.write(float4(value,0,0),xy);
        }
        struct Composite { float4 color; float4 selectionBounds; uint mode; uint clipRange; uint selection;
          uint alphaLock; uint eraser; uint compound; uint material; uint preservesAlpha; };
        struct Full { float4 position [[position]]; };
        vertex Full fullVertex(uint id [[vertex_id]]) {
          const float2 q[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
          Full o; o.position=float4(q[id],0,1); return o;
        }
        float3 linearColor(float3 c) {
          return select(c/12.92,pow((c+0.055)/1.055,float3(2.4)),c>0.04045);
        }
        fragment float4 compositeFragment(Full in [[stage_in]], constant Composite &u [[buffer(0)]],
          texture2d<float,access::read> original [[texture(0)]],
          texture2d<float,access::read> a [[texture(1)]],
          texture2d<float,access::read> b [[texture(2)]],
          texture2d<float,access::read> range [[texture(3)]],
          texture2d<float,access::read> selection [[texture(4)]],
          texture2d<float,access::read> locked [[texture(5)]],
          texture2d<float,access::read> material [[texture(6)]]) {
          uint2 xy=uint2(in.position.xy); float4 dst=original.read(xy);
          float2 av=a.read(xy).rg;
          float coverage=av.g;
          if(u.compound!=0) {
            float2 bv=b.read(xy).rg;
            if(u.mode==2) {
              coverage=av.g<=0.5 ? 2*av.g*bv.g : 1-2*(1-av.g)*(1-bv.g);
            } else { coverage=u.mode==0 ? min(av.g+bv.g,1.0)
              : av.g + max(av.r-av.g,0.0)*bv.g; }
          }
          if(u.clipRange!=0) coverage*=range.read(xy).r;
          if(u.selection==1) coverage*=selection.read(xy).r;
          else if(u.selection>=2) {
            float2 q=(float2(xy)+0.5-u.selectionBounds.xy)/max(u.selectionBounds.zw,float2(0.0001));
            if(any(q<0)||any(q>=1)) coverage=0;
            if(u.selection==3 && length(q*2-1)>1) coverage=0;
          }
          float alpha=clamp(coverage*u.color.a,0.0,1.0);
          if(u.alphaLock!=0 && u.preservesAlpha==0) alpha*=locked.read(xy).a;
          if(u.alphaLock!=0 && locked.read(xy).a<=0) return dst;
          bool preserve=u.alphaLock!=0 && u.preservesAlpha!=0;
          if(u.eraser!=0) return preserve
            ? float4(dst.rgb*(1-alpha),dst.a) : dst*(1-alpha);
          float targetAlpha=preserve ? dst.a : alpha+dst.a*(1-alpha);
          float3 rgb=linearColor(u.color.rgb);
          if(u.material!=0) { float4 m=material.read(xy); if(m.a>0.001) rgb=m.rgb/m.a; }
          return float4(rgb*alpha*(preserve ? dst.a:1.0)+dst.rgb*(1-alpha),targetAlpha);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        washPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "washStamps")!)
        let stamp = MTLRenderPipelineDescriptor()
        stamp.vertexFunction = library.makeFunction(name: "stampVertex")
        stamp.fragmentFunction = library.makeFunction(name: "stampFragment")
        stamp.colorAttachments[0].pixelFormat = .rg16Float
        stamp.colorAttachments[0].isBlendingEnabled = true
        stamp.colorAttachments[0].sourceRGBBlendFactor = .one
        stamp.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        stampPipeline = try device.makeRenderPipelineState(descriptor: stamp)
        let composite = MTLRenderPipelineDescriptor()
        composite.vertexFunction = library.makeFunction(name: "fullVertex")
        composite.fragmentFunction = library.makeFunction(name: "compositeFragment")
        composite.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        compositePipeline = try device.makeRenderPipelineState(descriptor: composite)
        let tile = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float,
            width: 256, height: 256, mipmapped: false)
        tile.storageMode = .shared
        let createdZeroTile = device.makeTexture(descriptor: tile)!
        zeroTile = createdZeroTile
        let zeros = [UInt8](repeating: 0, count: 256*256*4)
        zeros.withUnsafeBytes { createdZeroTile.replace(region: MTLRegionMake2D(0,0,256,256),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256*4) }
        let white = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
            width: 1, height: 1, mipmapped: false)
        white.storageMode = .shared
        whiteTip = device.makeTexture(descriptor: white)!
        var pixel: UInt8 = 255
        whiteTip.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 1)
    }

    func encode(stroke: StrokeDescriptor, streams: [[StampSample]],
                session: OpacityCapSessionResources, target: MTLTexture,
                commandBuffer: MTLCommandBuffer, selection: MTLTexture?, alphaLock: MTLTexture?, preservesAlpha: Bool,
                materialProvider: (BrushPixelBounds) -> MTLTexture?) -> BrushPixelBounds? {
        guard let config = stroke.brush.engineV2 else { return nil }
        if session.v2 == nil { session.v2 = BrushV2Session(device: device, width: target.width, height: target.height) }
        guard let state = session.v2,
              state.ensureFields(needsSecondary: stroke.brush.compoundBrush.enabled,
                                 needsRange: config.clipsToRange) else { return nil }
        let isOverlay = config.combination == .overlayMask
        let tips = [stroke.brush.compoundBrush.enabled ? stroke.brush.resolvedCompoundPrimaryTip : stroke.brush.primaryTipAsCompoundSecondary,
                    stroke.brush.compoundBrush.secondary, stroke.brush.primaryTipAsCompoundSecondary]
        var allStamps: [[BrushV2Stamp]] = [[],[],[]]
        var bounds: BrushPixelBounds?
        for role in 0..<3 {
            let tip = tips[role]
            allStamps[role] = streams[role].map { sample in
                let p = config.pressure(sample.point.pressure)
                let globalSize = stroke.brush.compoundBrush.enabled
                    ? BrushSettings.resolvedPressureFactor(responseAmount: stroke.brush.compoundBrush.globalPressureSizeAmount,
                        curvedPressure: p) : 1
                let radius = max(0.5, tip.resolvedBaseSize(for: stroke.brush.size)*tip.resolvedSizeFactor(for:p)*globalSize*sample.sizeMultiplier/2)
                let opacityFactor = isOverlay ? tip.resolvedOpacityFactor(for: p)
                    : BrushSettings.resolvedPressureFactor(responseAmount: tip.pressureOpacityAmount, curvedPressure: p)
                let overallOpacity = stroke.brush.compoundBrush.enabled
                    ? BrushSettings.resolvedPressureFactor(responseAmount: stroke.brush.compoundBrush.globalPressureOpacityAmount, curvedPressure: p) : 1
                let weight = !isOverlay && stroke.brush.compoundBrush.enabled && role < 2
                    ? config.contribution(primary: role==0, pressure: sample.point.pressure) : 1
                let flow = role==2 ? 1 : (role==1 && (config.combination == .stampMask || isOverlay)
                    ? config.secondaryFlow : config.resolvedFlow(sample.point.pressure) * (role==0 ? config.primaryFlow : config.secondaryFlow))
                let targetOpacity = role==2 ? 1 : weight*tip.opacity*opacityFactor*overallOpacity
                state.averageOpacity[role] = max(targetOpacity, state.averageOpacity[role]*0.9 + targetOpacity*0.1)
                // The authored rotation may combine fuzzy-dab and pressure.
                let angle = isOverlay && !tip.followsStrokeDirection
                    ? tip.angleDegrees + (sample.angleDegrees-tip.angleDegrees)*(1-tip.pressureRotationAmount+tip.pressureRotationAmount*p)
                    : sample.angleDegrees
                let s = BrushV2Stamp(center: SIMD2(Float(sample.point.x),Float(sample.point.y)),
                    radius: radius, rotation: angle * .pi/180,
                    canvas: SIMD2(Float(target.width),Float(target.height)),
                    shape: tip.tipShape == .customRound && tip.customTipMaskData != nil ? 3 : (tip.tipShape == .square ? 2 : (tip.tipShape == .softRound ? 1 : 0)),
                    roundness: tip.roundness, flow: flow,
                    contribution: targetOpacity,
                    contrast: role==2 ? 1 : (role==0 ? config.primaryContrast : config.secondaryContrast),
                    softness: tip.softness, averageOpacity: state.averageOpacity[role])
                let r = Double(radius*1.415+2)
                let x=max(0,Int(floor(sample.point.x-r))), y=max(0,Int(floor(sample.point.y-r)))
                let right=min(target.width,Int(ceil(sample.point.x+r))), bottom=min(target.height,Int(ceil(sample.point.y+r)))
                if right>x && bottom>y {
                    let b=BrushPixelBounds(originX:x,originY:y,width:right-x,height:bottom-y)
                    bounds=bounds.map{$0.union(b)} ?? b
                }
                return s
            }
        }
        guard let bounds else { return nil }
        guard initializeTiles(bounds: bounds, state: state, original: session.originalTexture,
                              target: target, commandBuffer: commandBuffer) else { return nil }
        let textures=[state.a,state.b,state.range]
        for role in 0..<3 where !allStamps[role].isEmpty {
            guard let pigment = textures[role] else { return nil }
            let descriptor=MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture=pigment
            descriptor.colorAttachments[0].loadAction = .load
            descriptor.colorAttachments[0].storeAction = .store
            let variants = role==0 ? config.primaryVariants : (role==1 ? config.secondaryVariants : [])
            let sources = [tips[role].customTipMaskData] + variants.map { Optional($0) }
            // Batch the common single-image case. Multi-image tips choose a new
            // frame per dab and keep that choice stable for replay.
            var batches: [(MTLTexture,[BrushV2Stamp])] = []
            for s in allStamps[role] {
                var index = 0
                if sources.count>1 {
                    let n=state.stampCounts[role]
                    var hash=UInt32(truncatingIfNeeded:n) &* 747796405 &+ stroke.paintVariationSeed &+ UInt32(role)*2891336453
                    hash = ((hash >> ((hash >> 28) &+ 4)) ^ hash) &* 277803737
                    index=Int(hash % UInt32(sources.count-1))
                    if index >= state.lastVariants[role] { index += 1 }
                    index %= sources.count
                }
                state.stampCounts[role] += 1; state.lastVariants[role]=index
                let texture=tipTexture(sources[index])
                if let last=batches.indices.last, batches[last].0 === texture { batches[last].1.append(s) }
                else { batches.append((texture,[s])) }
            }
            if isOverlay && role<2 {
                for (texture, stamps) in batches {
                    encodeWash(stamps, tip: texture, target: pigment, commandBuffer: commandBuffer)
                }
                continue
            }
            guard let encoder=commandBuffer.makeRenderCommandEncoder(descriptor:descriptor) else { continue }
            encoder.setRenderPipelineState(stampPipeline)
            for (texture, stamps) in batches {
                guard let buffer=stamps.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }) else { continue }
                encoder.setVertexBuffer(buffer,offset:0,index:0)
                encoder.setFragmentBuffer(buffer,offset:0,index:0)
                encoder.setFragmentTexture(texture,index:0)
                encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4,instanceCount:stamps.count)
            }
            encoder.endEncoding()
        }
        let material = materialProvider(bounds)
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        if let encoder=commandBuffer.makeRenderCommandEncoder(descriptor:pass) {
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setScissorRect(MTLScissorRect(x:bounds.originX,y:bounds.originY,width:bounds.width,height:bounds.height))
            let shape=stroke.selectionShape
            let selectionKind: UInt32 = selection != nil ? 1 : (shape?.kind == .rectangle ? 2 : (shape?.kind == .ellipse ? 3 : 0))
            let sb=shape?.bounds
            var u=BrushV2Composite(color:SIMD4(stroke.color.red,stroke.color.green,stroke.color.blue,stroke.color.alpha*stroke.brush.opacity),
                selectionBounds:SIMD4(Float(sb?.minX ?? 0),Float(sb?.minY ?? 0),Float(sb?.size.x ?? 0),Float(sb?.size.y ?? 0)),
                mode:isOverlay ? 2 : (config.combination == .pressureBlend ? 0:1), clipRange:config.clipsToRange ? 1:0,
                selection:selectionKind,alphaLock:alphaLock == nil ? 0:1,eraser:stroke.tool == .eraser ? 1:0,
                compound:stroke.brush.compoundBrush.enabled ? 1:0, material:material == nil ? 0:1,
                preservesAlpha:preservesAlpha ? 1:0)
            encoder.setFragmentBytes(&u,length:MemoryLayout<BrushV2Composite>.stride,index:0)
            // Inactive fields are not sampled. Bind A as a valid full-size
            // fallback without allocating or reading unused pigment surfaces.
            for (index,texture) in [session.originalTexture,state.a,state.b ?? state.a,state.range ?? state.a,selection ?? whiteTip,alphaLock ?? whiteTip,material ?? whiteTip].enumerated() {
                encoder.setFragmentTexture(texture,index:index)
            }
            encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4)
            encoder.endEncoding()
        }
        return bounds
    }

    private func encodeWash(_ stamps: [BrushV2Stamp], tip: MTLTexture, target: MTLTexture,
                            commandBuffer: MTLCommandBuffer) {
        // Bound each dispatch, so a short dab batch never scans the full canvas.
        var left=target.width, top=target.height, right=0, bottom=0
        for s in stamps {
            let r=s.radius*1.415+2
            left=min(left,max(0,Int(floor(s.center.x-r)))); top=min(top,max(0,Int(floor(s.center.y-r))))
            right=max(right,min(target.width,Int(ceil(s.center.x+r)))); bottom=max(bottom,min(target.height,Int(ceil(s.center.y+r))))
        }
        guard right>left, bottom>top,
              let buffer=stamps.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),
              let encoder=commandBuffer.makeComputeCommandEncoder() else { return }
        var region=SIMD4<UInt32>(UInt32(left),UInt32(top),UInt32(right-left),UInt32(bottom-top))
        var count=UInt32(stamps.count)
        encoder.setComputePipelineState(washPipeline)
        encoder.setBytes(&region,length:MemoryLayout<SIMD4<UInt32>>.stride,index:0)
        encoder.setBytes(&count,length:4,index:1)
        encoder.setBuffer(buffer,offset:0,index:2)
        encoder.setTexture(tip,index:0);encoder.setTexture(target,index:1)
        encoder.dispatchThreads(MTLSize(width:right-left,height:bottom-top,depth:1),
                                threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
        encoder.endEncoding()
    }

    private func tipTexture(_ data: Data?) -> MTLTexture {
        guard let data, !data.isEmpty else { return whiteTip }
        if let cached=tips[data] { return cached }
        let side=Int(Double(data.count).squareRoot())
        guard side*side==data.count else { return whiteTip }
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Unorm,width:side,height:side,mipmapped:false)
        d.storageMode = .shared; d.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:d) else { return whiteTip }
        data.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,side,side),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:side) }
        if tips.count>64 { tips.removeAll() }
        tips[data]=texture
        return texture
    }

    private func initializeTiles(bounds: BrushPixelBounds,state:BrushV2Session,original:MTLTexture,target:MTLTexture,commandBuffer:MTLCommandBuffer) -> Bool {
        guard let encoder=commandBuffer.makeBlitCommandEncoder() else { return false }
        let across=(target.width+255)/256
        let textures = [state.a, state.b, state.range]
        for y in bounds.originY/256...(bounds.originY+bounds.height-1)/256 {
            for x in bounds.originX/256...(bounds.originX+bounds.width-1)/256 {
                let tile = y*across+x
                let origin=MTLOrigin(x:x*256,y:y*256,z:0)
                let size=MTLSize(width:min(256,target.width-origin.x),height:min(256,target.height-origin.y),depth:1)
                if state.initializedTiles.insert(tile).inserted {
                    encoder.copy(from:target,sourceSlice:0,sourceLevel:0,sourceOrigin:origin,sourceSize:size,
                        to:original,destinationSlice:0,destinationLevel:0,destinationOrigin:origin)
                }
                for (role, texture) in textures.enumerated() {
                    guard let texture, state.initializedPigmentTiles[role].insert(tile).inserted else { continue }
                    encoder.copy(from:zeroTile,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:size,
                        to:texture,destinationSlice:0,destinationLevel:0,destinationOrigin:origin)
                }
            }
        }
        encoder.endEncoding()
        return true
    }
}

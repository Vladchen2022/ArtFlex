import MetalKit
import SwiftUI

/// The editor draws into the same sRGB Metal surface and stroke-session engine
/// as the canvas. No alpha-only reconstruction, CPU image copies, or GPU waits
/// occur in pointer handlers. Pen-up flushes the existing session exactly once.
struct BrushEditorMetalPreview: NSViewRepresentable {
    let brush: BrushSettings
    let color: RGBAColor
    let pigmentPalette: BrushPigmentPalette
    let pressure: Float
    let background: CompoundBrushPreviewBackground
    let clearToken: Int
    let seed: UInt32
    let pattern: CompoundBrushPreviewPath?
    let patternToken: Int
    let onPressure: (Float, Bool) -> Void

    func makeNSView(context: Context) -> BrushEditorMetalView {
        let view = BrushEditorMetalView()
        updateNSView(view,context:context)
        return view
    }
    func updateNSView(_ view: BrushEditorMetalView,context: Context) {
        view.update(brush:brush,color:color,pigmentPalette:pigmentPalette,pressure:pressure,background:background,
            clearToken:clearToken,seed:seed,pattern:pattern,patternToken:patternToken,onPressure:onPressure)
    }
}

final class BrushEditorMetalView: MTKView, MTKViewDelegate {
    private let extent = 512
    private var queue: MTLCommandQueue?
    private var renderer: StageOneBrushRenderer?
    private var surface: MTLTexture?
    private var presentation: MTLRenderPipelineState?
    private var brush = BrushSettings.v2Default
    private var color = RGBAColor.black
    private var pigmentPalette = BrushPigmentPalette.empty
    private var pressure: Float = 0.5
    private var previewBackground: CompoundBrushPreviewBackground = .light
    private var seed: UInt32 = 1
    private var clearToken = -1
    private var patternToken = -1
    private var generatedPattern: CompoundBrushPreviewPath?
    private var strokes: [[StrokePoint]] = []
    private var active: [StrokePoint] = []
    private var sampling: BrushStrokeSamplingState?
    private var session: OpacityCapSessionResources?
    private var needsReplay = true
    private var lastPressure: Float?
    private var onPressure: ((Float,Bool)->Void)?

    init() {
        let device=MTLCreateSystemDefaultDevice()
        super.init(frame:.zero,device:device)
        colorPixelFormat = .bgra8Unorm_srgb
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        guard let device else { return }
        queue=device.makeCommandQueue()
        renderer=try? StageOneBrushRenderer(device:device)
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:extent,height:extent,mipmapped:false)
        d.storageMode = .private; d.usage = [.renderTarget,.shaderRead]
        surface=device.makeTexture(descriptor:d)
        let source="""
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V previewVertex(uint i [[vertex_id]]) {
          const float2 p[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
          V v;v.position=float4(p[i],0,1);v.uv=float2(p[i].x*0.5+0.5,0.5-p[i].y*0.5);return v;
        }
        fragment float4 previewFragment(V v [[stage_in]],texture2d<float> paint [[texture(0)]],constant uint &bg [[buffer(0)]]) {
          constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
          float4 c=paint.sample(s,v.uv);float b=bg==0 ? 1.0:0.006;
          if(bg==2) b=(int(v.position.x/12)+int(v.position.y/12))%2==0 ? 0.16:0.24;
          return float4(c.rgb+b*(1-c.a),1);
        }
        """
        if let library=try? device.makeLibrary(source:source,options:nil) {
            let p=MTLRenderPipelineDescriptor()
            p.vertexFunction=library.makeFunction(name:"previewVertex")
            p.fragmentFunction=library.makeFunction(name:"previewFragment")
            p.colorAttachments[0].pixelFormat=colorPixelFormat
            presentation=try? device.makeRenderPipelineState(descriptor:p)
        }
        setAccessibilityLabel("实时试笔画布")
    }

    @available(*,unavailable) required init(coder:NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    func update(brush:BrushSettings,color:RGBAColor,pigmentPalette:BrushPigmentPalette,pressure:Float,background:CompoundBrushPreviewBackground,
                clearToken:Int,seed:UInt32,pattern:CompoundBrushPreviewPath?,patternToken:Int,
                onPressure:@escaping(Float,Bool)->Void) {
        self.onPressure=onPressure
        if self.brush != brush || self.color != color || self.pigmentPalette != pigmentPalette || self.seed != seed {
            self.brush=brush;self.color=color;self.pigmentPalette=pigmentPalette;self.seed=seed;needsReplay=true
        }
        if self.clearToken != clearToken {
            self.clearToken=clearToken;strokes=[];active=[];generatedPattern=nil;needsReplay=true
        }
        if self.patternToken != patternToken {
            self.patternToken=patternToken;generatedPattern=pattern
            strokes=pattern.map{[$0.points(resolution:extent,pressure:pressure)]} ?? []
            needsReplay=true
        } else if self.pressure != pressure,let pattern=generatedPattern {
            strokes=[pattern.points(resolution:extent,pressure:pressure)];needsReplay=true
        }
        self.pressure=pressure;self.previewBackground=background
        needsDisplay=true
    }

    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) { needsDisplay=true }

    func draw(in view:MTKView) {
        guard let queue,let buffer=queue.makeCommandBuffer(),let surface,
              let presentation,let descriptor=currentRenderPassDescriptor,let drawable=currentDrawable else { return }
        if needsReplay && active.isEmpty {
            let clear=MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture=surface
            clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
            clear.colorAttachments[0].storeAction = .store
            buffer.makeRenderCommandEncoder(descriptor:clear)?.endEncoding()
            for (index,points) in strokes.enumerated() {
                beginSession()
                encode(points:points,continuation:false,strokeIndex:index,buffer:buffer)
                flush(strokeIndex:index,buffer:buffer)
            }
            session=nil;sampling=nil;needsReplay=false
        }
        if let encoder=buffer.makeRenderCommandEncoder(descriptor:descriptor) {
            encoder.setRenderPipelineState(presentation)
            encoder.setFragmentTexture(surface,index:0)
            var bg: UInt32 = previewBackground == .light ? 0:(previewBackground == .dark ? 1:2)
            encoder.setFragmentBytes(&bg,length:4,index:0)
            encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4)
            encoder.endEncoding()
        }
        buffer.present(drawable);buffer.commit()
    }

    private func beginSession() {
        sampling=nil
        if let renderer,let surface,let queue,brush.requiresStrokeMaskSession {
            session=renderer.makeOpacityCapSession(for:surface,commandQueue:queue,reusesCachedTextures:false)
        } else { session=nil }
    }

    private func encode(points:[StrokePoint],continuation:Bool,strokeIndex:Int,buffer:MTLCommandBuffer) {
        guard let renderer,let surface,let queue else { return }
        let stroke=StrokeDescriptor(tool:.brush,color:color,brush:brush,points:points,selectionShape:nil,
            skipLeadingStamp:continuation,paintVariationSeed:seed &+ UInt32(strokeIndex) &* 2654435761,
            pigmentPalette:pigmentPalette)
        if let session {
            renderer.encodeOpacityCapStroke(stroke:stroke,session:session,into:surface,commandBuffer:buffer,samplingState:&sampling)
        } else {
            renderer.encodeStroke(stroke:stroke,into:surface,commandQueue:queue,commandBuffer:buffer,samplingState:&sampling)
        }
    }

    private func flush(strokeIndex:Int,buffer:MTLCommandBuffer) {
        var s=sampling ?? BrushStrokeSamplingState();s.isFlushing=true;sampling=s
        encode(points:[],continuation:true,strokeIndex:strokeIndex,buffer:buffer)
    }

    private func point(_ event:NSEvent)->StrokePoint {
        let local=convert(event.locationInWindow,from:nil)
        let tablet=event.subtype == .tabletPoint || event.type == .tabletPoint || event.type == .pressure
        let value=tablet ? resolveBrushInputPressure(rawPressure:event.pressure,isTabletLikeEvent:true,
            eventSubtypeIsTabletPoint:true,sawTabletAuxiliaryEvent:false,lastPressure:lastPressure,
            strokeInputSampleCount:active.count,minimumTabletPressure:0.005,debugForceConstantPressure:false) : pressure
        lastPressure=value
        onPressure?(value,tablet)
        return StrokePoint(x:Double(local.x/max(bounds.width,1))*Double(extent),
            y:Double((bounds.height-local.y)/max(bounds.height,1))*Double(extent),pressure:value)
    }

    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        if needsReplay { draw() }
        lastPressure=nil;generatedPattern=nil
        active=[point(event)]
        beginSession()
        guard let buffer=queue?.makeCommandBuffer() else { return }
        encode(points:[active[0],active[0]],continuation:false,strokeIndex:strokes.count,buffer:buffer)
        buffer.commit();needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent) {
        guard let previous=active.last,let buffer=queue?.makeCommandBuffer() else { return }
        let next=point(event);active.append(next)
        encode(points:[previous,next],continuation:true,strokeIndex:strokes.count,buffer:buffer)
        buffer.commit();needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        guard !active.isEmpty,let buffer=queue?.makeCommandBuffer() else { return }
        let next=point(event)
        if next != active.last { encode(points:[active.last!,next],continuation:true,strokeIndex:strokes.count,buffer:buffer);active.append(next) }
        flush(strokeIndex:strokes.count,buffer:buffer)
        buffer.commit();strokes.append(active);active=[];session=nil;sampling=nil;needsDisplay=true
    }
}

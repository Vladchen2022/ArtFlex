import Foundation
import Metal
import Testing
@testable import ArtFlex

struct BrushEngineV2Tests {
    @Test func metalPipelineCompiles() throws {
        _ = try BrushV2Renderer(device: #require(MTLCreateSystemDefaultDevice()))
    }
    @Test func overlayUsesActualPressureCurvesAndRecoversFullPrimary() throws {
        var brush=BrushSettings.v2Default
        brush.size=24;brush.engineV2?.combination = .overlayMask;brush.engineV2?.inputMaximum=1
        brush.compoundBrush.enabled=true
        var a=brush.primaryTipAsCompoundSecondary
        a.pressureOpacityAmount=1;a.opacityPressureCurve = .identity;a.spacingPercent=6
        var b=a
        b.tipShape = .customRound;b.customTipMaskData=Data(repeating:64,count:32*32)
        b.spacingPercent=1000;b.pressureOpacityAmount=0
        brush.compoundBrush.primary=a;brush.compoundBrush.secondary=b
        let points=[StrokePoint(x:20,y:64,pressure:0.25),StrokePoint(x:108,y:64,pressure:0.25)]
        let light=try render(brush,points:points)
        // At x=20, B is 64/255 and A approaches 25%: overlay ~= 12.5%.
        #expect(light[(64*128+20)*4+3] < 40)
        #expect(light[(64*128+20)*4+3] > 15)
        let heavy=try render(brush,points:points.map{StrokePoint(x:$0.x,y:$0.y,pressure:1)})
        #expect(heavy[(64*128+64)*4+3]>=254)
        // No B at this pixel. Overlay still preserves an opaque A, unlike multiply.
        #expect(light[(64*128+64)*4+3]==0)
    }

    @Test func overlayWashNeverThinsExistingPaintWhenPressureDrops() throws {
        var brush=BrushSettings.v2Default;brush.size=24
        brush.engineV2?.combination = .overlayMask;brush.engineV2?.inputMaximum=1
        brush.pressureOpacityAmount=1;brush.opacityPressureCurve = .identity
        let points=[StrokePoint(x:20,y:64,pressure:1),StrokePoint(x:108,y:64,pressure:1),
                    StrokePoint(x:20,y:64,pressure:0.1)]
        let bytes=try render(brush,points:points,packets:true)
        #expect(bytes[(64*128+64)*4+3]>=254)
        #expect(try render(brush,points:points)==bytes)
    }

    @Test func importedKritaReferenceProducesPressureGrainInsteadOfUniformFading() throws {
        guard let path=ProcessInfo.processInfo.environment["ARTFLEX_KRITA_REFERENCE"] else {return}
        let imported=try KritaMaskedBrushImporter.load(url:URL(fileURLWithPath:path))
        #expect(imported.name=="06-01-蜡笔")
        var brush=imported.brush;brush.size=36
        #expect(brush.resolvedCompoundPrimaryTip.pressureSizeAmount==0)
        #expect(brush.resolvedCompoundPrimaryTip.followsStrokeDirection==false)
        #expect(brush.resolvedCompoundPrimaryTip.customTipMaskData?.count==36*36)
        #expect(brush.compoundBrush.secondary.customTipMaskData?.count==90*90)
        #expect(abs(brush.compoundBrush.secondary.relativeSizeRatio-1.5454545)<0.00001)
        #expect(brush.compoundBrush.secondary.spacingPercent==75)
        #expect(abs(brush.compoundBrush.secondary.resolvedOpacityFactor(for:0.1)-0.6925)<0.001)
        #expect(brush.compoundBrush.secondary.resolvedOpacityFactor(for:0.3)==1)
        let points=(0...40).map {i in StrokePoint(x:Double(i)*2.5+14,y:64,pressure:Float(i)/40)}
        let full=try render(brush,points:points)
        #expect(full == (try render(brush,points:points,packets:true)))
        let strip=(20..<109).map { x in Int(full[(64*128+x)*4+3]) }
        #expect(strip.suffix(20).reduce(0,+)>strip.prefix(20).reduce(0,+)*2)
        #expect(strip.max()!>240)
        #expect(try JSONDecoder().decode(BrushSettings.self,from:JSONEncoder().encode(brush))==brush)
    }

    private func render(_ brush: BrushSettings, points: [StrokePoint], packets: Bool = false,
                        repetitions: Int = 1, selection: SelectionShape? = nil, locksHalfTransparentWhite: Bool = false) throws -> [UInt8] {
        let device=try #require(MTLCreateSystemDefaultDevice())
        let renderer=try StageOneBrushRenderer(device:device)
        let queue=try #require(device.makeCommandQueue())
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:128,height:128,mipmapped:false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.renderTarget]
        let texture=try #require(device.makeTexture(descriptor:descriptor))
        var bytes=[UInt8](repeating:0,count:128*128*4)
        if locksHalfTransparentWhite {
            for i in stride(from:0,to:bytes.count,by:4) { bytes[i]=188;bytes[i+1]=188;bytes[i+2]=188;bytes[i+3]=128 }
        }
        bytes.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,128,128),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:128*4) }
        let lockTexture = locksHalfTransparentWhite ? device.makeTexture(descriptor:descriptor) : nil
        if let lockTexture {
            bytes.withUnsafeBytes { lockTexture.replace(region:MTLRegionMake2D(0,0,128,128),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:128*4) }
        }
        for _ in 0..<repetitions {
            let session=try #require(renderer.makeOpacityCapSession(for:texture,commandQueue:queue,reusesCachedTextures:false))
            var state: BrushStrokeSamplingState?
            let chunks: [[StrokePoint]] = packets ? points.indices.map { index in [points[max(0,index-1)],points[index]] } : [[points[0]]+points]
            for (index,chunk) in chunks.enumerated() {
                let buffer=try #require(queue.makeCommandBuffer())
                let stroke=StrokeDescriptor(tool:.brush,color:RGBAColor(red:0.7,green:0.2,blue:0.1,alpha:1),brush:brush,
                    points:chunk,selectionShape:selection,skipLeadingStamp:index>0,paintVariationSeed:47)
                renderer.encodeOpacityCapStroke(stroke:stroke,session:session,into:texture,commandBuffer:buffer,alphaLockTexture:lockTexture,samplingState:&state)
                buffer.commit();buffer.waitUntilCompleted()
                #expect(buffer.status == .completed)
            }
            let buffer=try #require(queue.makeCommandBuffer())
            state?.isFlushing=true
            renderer.encodeOpacityCapStroke(stroke:StrokeDescriptor(tool:.brush,color:RGBAColor(red:0.7,green:0.2,blue:0.1,alpha:1),
                brush:brush,points:[],selectionShape:selection,skipLeadingStamp:true,paintVariationSeed:47),
                session:session,into:texture,commandBuffer:buffer,alphaLockTexture:lockTexture,samplingState:&state)
            buffer.commit();buffer.waitUntilCompleted()
            #expect(buffer.status == .completed)
        }
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:128*4,from:MTLRegionMake2D(0,0,128,128),mipmapLevel:0) }
        return bytes
    }

    @Test func trueIncrementalReplayMatchesWholeStrokeIncludingPressureAndVariants() throws {
        var brush=BrushSettings.v2Crayon
        brush.size=20;brush.engineV2?.pressureFlow=0.6
        brush.compoundBrush.globalPressureSizeAmount=0.5
        let points=(0...40).map { i in StrokePoint(x:Double(i)*2.5+14,y:64+sin(Double(i)/9)*22,pressure:Float(i)/40) }
        let a=try render(brush,points:points)
        let b=try render(brush,points:points,packets:true)
        #expect(a==b)
    }

    @Test func opacityCapsOneStrokeAndLiftedStrokesAccumulate() throws {
        var brush=BrushSettings.v2Default;brush.size=24;brush.opacity=0.5
        let points=[StrokePoint(x:20,y:64,pressure:0.5),StrokePoint(x:108,y:64,pressure:0.5)]
        let once=try render(brush,points:points)
        let twice=try render(brush,points:points,repetitions:2)
        #expect(abs(Int(once[(64*128+64)*4+3])-128)<=1)
        #expect(abs(Int(twice[(64*128+64)*4+3])-192)<=1)
        brush.opacity=1
        let opaque=try render(brush,points:points)
        #expect(abs(Int(opaque[(64*128+64)*4+2])-179)<=1)
        #expect(abs(Int(opaque[(64*128+64)*4+1])-51)<=1)
        #expect(abs(Int(opaque[(64*128+64)*4])-26)<=1)
    }

    @Test func colorVariationStillWorksThroughSharedPigmentShader() throws {
        var brush=BrushSettings.v2Crayon;brush.size=24
        let points=[StrokePoint(x:20,y:64,pressure:0.75),StrokePoint(x:108,y:64,pressure:0.75)]
        let plain=try render(brush,points:points)
        brush.compoundBrush.globalPaintJitterAmount=0.8
        let varied=try render(brush,points:points)
        #expect(plain != varied)
        #expect(varied[(64*128+64)*4+3]>=254)
    }

    @Test func quickControlsAndDefaultPressureMixHaveConsistentSemantics() {
        var brush=BrushSettings.v2Crayon
        brush.quickSpacingPercent=33;brush.quickSizeJitterAmount=0.2
        #expect(brush.resolvedCompoundPrimaryTip.spacingPercent==33)
        #expect(brush.resolvedCompoundPrimaryTip.sizeJitterAmount==0.2)
        let primary=brush.resolvedCompoundPrimaryTip
        brush.setCompoundBrushEnabledUsingArtistDefault(false)
        brush.setCompoundBrushEnabledUsingArtistDefault(true)
        #expect(brush.resolvedCompoundPrimaryTip==primary)
        let config=BrushEngineV2()
        for raw in stride(from:Float(0),through:1,by:0.05) {
            #expect(abs(config.contribution(primary:true,pressure:raw)+config.contribution(primary:false,pressure:raw)-1)<0.0001)
        }
    }
    private func alpha(_ brush: BrushSettings, pressure: Float = 0.5) throws -> [UInt8] {
        var state: BrushStrokeSamplingState?
        return try #require(StageOneBrushPreviewRasterizer.strokeAlphaBytes(
            for: brush, resolution: 128,
            points: [StrokePoint(x:20,y:64,pressure:pressure),StrokePoint(x:108,y:64,pressure:pressure)],
            samplingState: &state, paintVariationSeed: 13, flushPendingSamples: true))
    }

    @Test func newSingleTipReachesFullColorWithoutHardPressure() throws {
        var brush=BrushSettings.v2Default
        brush.size=24; brush.spacingPercent=10
        let bytes=try alpha(brush,pressure:0.2)
        #expect(bytes[64*128+64] >= 254)
    }

    @Test func equalABHasNoMidPressureDensityDip() throws {
        var brush=BrushSettings.v2Default
        brush.size=24; brush.spacingPercent=10
        let single=try alpha(brush)
        brush.compoundBrush.enabled=true
        brush.compoundBrush.primary=brush.primaryTipAsCompoundSecondary
        brush.compoundBrush.secondary=brush.primaryTipAsCompoundSecondary
        brush.engineV2?.primaryContribution = .balanced
        brush.engineV2?.secondaryContribution = .balanced
        let dual=try alpha(brush)
        let maximumDifference=zip(single,dual).map{abs(Int($0)-Int($1))}.max() ?? 255
        #expect(maximumDifference <= 2)
    }

    @Test func stampMaskPreservesPrimaryAtHeavyPressureAndHonorsSecondaryContribution() throws {
        var brush=BrushSettings.v2Default
        brush.size=24;brush.compoundBrush.enabled=true
        brush.compoundBrush.primary=brush.primaryTipAsCompoundSecondary
        brush.compoundBrush.secondary=brush.primaryTipAsCompoundSecondary
        brush.engineV2?.combination = .stampMask
        brush.engineV2?.secondaryContribution = .primaryOnly
        let light=try alpha(brush,pressure:0)
        #expect(light[64*128+64]>=254)
        brush.engineV2?.secondaryContribution = .secondaryOnly
        #expect(try alpha(brush,pressure:0).max()==0)
        #expect(try alpha(brush,pressure:0.75)[64*128+64]>=254)
    }

    @Test func independentRangeClipsActualPaintAndOffCanvasStartStillDraws() throws {
        var brush=BrushSettings.v2Default;brush.size=24
        let points=[StrokePoint(x:-40,y:64,pressure:0.75),StrokePoint(x:108,y:64,pressure:0.75)]
        let outside=try render(brush,points:points,packets:true)
        #expect(outside[(64*128)*4+3]>=254)
        brush.compoundBrush.enabled=true
        brush.compoundBrush.primary=brush.primaryTipAsCompoundSecondary
        brush.compoundBrush.secondary=brush.primaryTipAsCompoundSecondary
        brush.customTipMaskData=Data(repeating:0,count:32*32);brush.tipShape = .customRound
        brush.engineV2?.clipsToRange=true
        let clipped=try render(brush,points:points)
        #expect(clipped.allSatisfy{$0==0})
        brush.engineV2?.clipsToRange=false
        #expect(try render(brush,points:points)[(64*128+64)*4+3]>=254)
    }

    @Test func selectionAndAlphaLockPreservePixelContract() throws {
        var brush=BrushSettings.v2Default;brush.size=24
        let points=[StrokePoint(x:20,y:64,pressure:0.75),StrokePoint(x:108,y:64,pressure:0.75)]
        let selection=SelectionShape(kind:.rectangle,bounds:CanvasRect(origin:.init(x:50,y:50),size:.init(x:20,y:30)),pathPoints:[])
        let selected=try render(brush,points:points,selection:selection)
        #expect(selected[(64*128+40)*4+3]==0)
        #expect(selected[(64*128+60)*4+3]>=254)
        let locked=try render(brush,points:points,locksHalfTransparentWhite:true)
        #expect(locked[(64*128+64)*4+3]==128)
        // Linear premultiplied red = sRGBToLinear(0.7) * 128/255;
        // encoded back to sRGB this is approximately 130, not a white fringe.
        #expect(abs(Int(locked[(64*128+64)*4+2])-130)<=1)
    }

    @Test func sourceGrayIsPreservedAndFlowBuildsInsideStroke() throws {
        var brush=BrushSettings.v2Default
        brush.tipShape = .customRound
        brush.customTipMaskData=Data(repeating:128,count:32*32)
        brush.customTipSoftness=0.5
        brush.size=24; brush.spacingPercent=100
        let sparse=try alpha(brush)
        #expect(sparse[64*128+20] >= 125)
        brush.spacingPercent=5
        let dense=try alpha(brush)
        #expect(dense[64*128+64] >= 250)
        brush.opacity=0.4
        let limited=try alpha(brush)
        #expect(abs(Int(limited[64*128+64])-102)<=2)
    }

    @Test func bothMaterialsReallyPaintAtTheirAssignedPressure() throws {
        var brush=BrushSettings.v2Default
        brush.size=24; brush.compoundBrush.enabled=true
        brush.compoundBrush.primary=brush.primaryTipAsCompoundSecondary
        brush.compoundBrush.secondary=brush.primaryTipAsCompoundSecondary
        brush.compoundBrush.secondary.tipShape = .customRound
        brush.compoundBrush.secondary.customTipMaskData=Data(repeating:0,count:32*32)
        let heavy=try alpha(brush,pressure:0.75)
        let light=try alpha(brush,pressure:0)
        #expect(heavy[64*128+64]>=254)
        #expect(light.max()==0)
    }

    @Test func legacyAndNewSettingsSurviveArchiveWithoutImplicitConversion() throws {
        let old=BrushSettings.stageOneDefault
        let oldCopy=try JSONDecoder().decode(BrushSettings.self,from:JSONEncoder().encode(old))
        #expect(oldCopy.engineV2==nil)
        var new=BrushSettings.v2Default
        new.engineV2?.flow=0.73
        new.engineV2?.secondaryVariants=[Data(repeating:72,count:64)]
        #expect(try JSONDecoder().decode(BrushSettings.self,from:JSONEncoder().encode(new))==new)
        #expect(old.engineV2==nil)
    }
}

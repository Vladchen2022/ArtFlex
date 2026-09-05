import Foundation
import CoreGraphics
import ImageIO
import Testing
import zlib
@testable import ArtFlex

struct KritaMaskedBrushImporterTests {
    private func fixture(mode: String="overlay", sizeEnabled: Bool=false, compressed: Bool=false) throws -> Data {
        let pixels: [UInt8]=[0,0,0,255, 128,128,128,255]
        let provider=try #require(CGDataProvider(data:Data(pixels) as CFData))
        let image=try #require(CGImage(width:2,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let png=NSMutableData()
        let destination=try #require(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil)
        #expect(CGImageDestinationFinalize(destination))
        let resource=(png as Data).base64EncodedString()
        func param(_ key:String,_ value:String)->String { "<param name=\"\(key)\"><![CDATA[\(value)]]></param>" }
        let definition="<Brush type=\"png_brush\" brushApplication=\"0\" filename=\"tip.png\" scale=\"16\" spacing=\"0.06\"/>"
        let params=[param("MaskingBrush/Enabled","true"),param("MaskingBrush/MaskingCompositeOp",mode),
            param("CompositeOp","normal"),param("PressureSize",sizeEnabled ? "true":"false"),
            param("brush_definition",definition),param("MaskingBrush/Preset/brush_definition",definition),
            param("OpacityUseCurve","true"),param("OpacitySensor","<params id=\"pressure\"/>"),
            param("OpacitycommonCurve","0,0.49;0.25,1;"),param("MaskingBrush/UseMasterSize","true"),param("PaintOpAction","2")].joined()
        let xml="<Preset name=\"Test\" paintopid=\"paintbrush\"><resources><resource filename=\"tip.png\">\(resource)</resource></resources>\(params)</Preset>"
        return try kpp(xml,compressed:compressed)
    }

    private func kpp(_ xml:String,compressed:Bool=false) throws -> Data {
        var bytes=Array(xml.utf8)
        if compressed {
            var length=compressBound(uLong(bytes.count))
            var out=[UInt8](repeating:0,count:Int(length))
            #expect(compress(&out,&length,bytes,uLong(bytes.count))==Z_OK)
            bytes=Array(out.prefix(Int(length)))
        }
        let payload=Array("preset".utf8)+[0,compressed ? 1:0,0,0,0]+bytes
        var size=UInt32(payload.count).bigEndian
        var data=Data([137,80,78,71,13,10,26,10])
        withUnsafeBytes(of:&size){data.append(contentsOf:$0)}
        data.append(Data("iTXt".utf8));data.append(contentsOf:payload);data.append(Data(repeating:0,count:4))
        return data
    }

    @Test func actualImageLuminanceAndAspectArePreserved() throws {
        let result=try KritaMaskedBrushImporter.parse(fixture())
        let tip=result.brush.resolvedCompoundPrimaryTip
        #expect(tip.customTipMaskData==Data([255,127,0,0]))
        #expect(result.brush.size==32)
        #expect(tip.followsStrokeDirection==false)
        #expect(tip.pressureSizeAmount==0)
        #expect(tip.opacityPressureCurve?.points.last?.x==0.25)
        #expect(abs(tip.resolvedOpacityFactor(for:0.125)-0.745)<0.0001)
    }

    @Test func compressedMetadataMatchesPlainMetadata() throws {
        #expect(try KritaMaskedBrushImporter.parse(fixture(compressed:true)).brush == KritaMaskedBrushImporter.parse(fixture()).brush)
    }

    @Test func unsupportedFeaturesAndMalformedFilesFailInsteadOfMakingAnotherBrush() throws {
        #expect(throws:(any Error).self) {try KritaMaskedBrushImporter.parse(fixture(mode:"multiply"))}
        #expect(throws:(any Error).self) {try KritaMaskedBrushImporter.parse(fixture(sizeEnabled:true))}
        #expect(throws:(any Error).self) {try KritaMaskedBrushImporter.parse(Data([1,2,3]))}
        let valid=try fixture()
        #expect(throws:(any Error).self) {try KritaMaskedBrushImporter.parse(valid.dropLast(10))}
        #expect(throws:(any Error).self) {try KritaMaskedBrushImporter.parse(kpp("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><Preset/>"))}
    }
}

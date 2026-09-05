import Foundation
import ImageIO
import CoreGraphics
import zlib

/// Deliberately bounded import, not a general KPP compatibility claim. All
/// resources stay in the user's preset; nothing is copied into app resources.
enum KritaMaskedBrushImporter {
    struct Result {
        var name: String
        var brush: BrushSettings
        var notes: [String]
    }
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(reason) = self { return reason }; return nil }
    }

    static func load(url: URL) throws -> Result {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Result {
        let text = try presetXML(data)
        guard !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw Failure.invalid("不允许预设引用外部实体。") }
        let document = try XMLDocument(xmlString: text, options: .nodeLoadExternalEntitiesNever)
        guard let root=document.rootElement(), root.name == "Preset",
              root.attribute(forName:"paintopid")?.stringValue == "paintbrush" else {
            throw Failure.invalid("目前只支持 Krita 像素引擎的 PNG 双笔尖叠加蒙版预设。")
        }
        var parameters: [String:String] = [:]
        for node in root.elements(forName:"param") {
            if let key=node.attribute(forName:"name")?.stringValue { parameters[key]=node.stringValue ?? "" }
        }
        func enabled(_ key: String) -> Bool { parameters[key] == "true" || parameters[key] == "1" }
        func number(_ key: String, _ fallback: Float=1) -> Float {
            guard let value=Float(parameters[key] ?? ""), value.isFinite else { return fallback }; return value
        }
        guard enabled("MaskingBrush/Enabled"), parameters["MaskingBrush/MaskingCompositeOp"] == "overlay" else {
            throw Failure.invalid("此导入器只接受已启用的叠加（Overlay）蒙版；其他混合模式不会被悄悄替换。")
        }
        guard parameters["CompositeOp"] == "normal", !enabled("Texture/Pattern/Enabled") else {
            throw Failure.invalid("此预设使用了额外图案或非正常颜色混合，当前不能完整导入。")
        }
        guard parameters["PaintOpAction"] == "2",enabled("MaskingBrush/UseMasterSize") else {
            throw Failure.invalid("目前仅支持 Wash 绘画模式、蒙版尺寸跟随主笔尖的预设。")
        }
        // These enabled modules need their own semantics, not approximations.
        let unsupported = ["PressureSize","PressureRatio","PressureMirror","PressureScatter","PressureSoftness",
            "PressureSharpness","PressureDarken","PressureMix","Pressureh","Pressures","Pressurev",
            "PressureSpacing","PressureLightnessStrength","PaintOpSettings/isAirbrushing"]
        for prefix in ["","MaskingBrush/Preset/"] {
            for key in unsupported where enabled(prefix+key) {
                throw Failure.invalid("尚不支持已开启的 \(prefix+key)，已中止导入，原画笔没有改变。")
            }
        }
        guard !enabled("FlowUseCurve"), !enabled("MaskingBrush/Preset/FlowUseCurve") else {
            throw Failure.invalid("此预设带有流量传感器，目前仅支持恒定流量的叠加蒙版。")
        }
        var resources: [String:Data] = [:]
        for resource in root.elements(forName:"resources").flatMap({$0.elements(forName:"resource")}) {
            if let filename=resource.attribute(forName:"filename")?.stringValue,
               let bytes=Data(base64Encoded:resource.stringValue ?? "",options:.ignoreUnknownCharacters) {
                resources[filename]=bytes
            }
        }
        var brush=BrushSettings.v2Default
        brush.compoundBrush.enabled=true
        brush.engineV2?.combination = .overlayMask
        brush.engineV2?.inputMaximum=1 // Import does not silently recalibrate pressure.
        brush.engineV2?.referenceName=root.attribute(forName:"name")?.stringValue ?? "Krita 蒙版笔刷"
        brush.compoundBrush.globalPressureSizeAmount=0
        brush.compoundBrush.globalPressureOpacityAmount=0
        brush.opacity=1
        var tips: [CompoundSecondaryTipSettings] = []
        for (index,prefix) in ["","MaskingBrush/Preset/"].enumerated() {
            guard let definition=parameters[prefix+"brush_definition"],
                  !definition.contains("<!"),
                  let xml=try XMLDocument(xmlString:definition,options:.nodeLoadExternalEntitiesNever).rootElement() else {
                throw Failure.invalid("预设缺少笔尖定义。")
            }
            func attr(_ key:String)->String { xml.attribute(forName:key)?.stringValue ?? "" }
            guard attr("type")=="png_brush", attr("brushApplication")=="0",
                  let png=resources[attr("filename")] else {
                throw Failure.invalid("笔尖必须是预设内嵌的 PNG 透明度蒙版；不支持的素材不会改成圆头。")
            }
            guard attr("useAutoSpacing") != "1" else {throw Failure.invalid("自动间距尚未实现等价导入。")}
            guard Float(attr("ContrastAdjustment")) ?? 0 == 0,
                  Float(attr("BrightnessAdjustment")) ?? 0 == 0 else {
                throw Failure.invalid("暂不支持笔尖亮度或对比度预处理。")
            }
            let mask=try alphaMask(png)
            var tip=brush.primaryTipAsCompoundSecondary
            tip.tipShape = .customRound;tip.sourceSemantic = .customMask
            tip.customTipMaskData=mask.data;tip.tipAssetID=nil
            tip.sizeMode = .relativeToPrimary;tip.relativeSizeRatio=1
            tip.spacingPercent=(Float(attr("spacing")) ?? 0.1)*100
            tip.softness=0;tip.roundness=1
            tip.followsStrokeDirection=false;tip.angleDegrees=(Float(attr("angle")) ?? 0)*180 / .pi
            tip.pressureSizeAmount=0;tip.sizeJitterAmount=0;tip.scatterAmount=0
            tip.angleJitterAmount=0;tip.pressureRotationAmount=0
            tip.opacity=min(max(number(prefix+"OpacityValue"),0),1)
            tip.pressureOpacityAmount=enabled(prefix+"OpacityUseCurve") ? 1:0
            if enabled(prefix+"OpacityUseCurve") {
                let sensor=parameters[prefix+"OpacitySensor"] ?? ""
                guard sensor.contains("id=\"pressure\""), !sensor.contains("ChildSensor") else {
                    throw Failure.invalid("不透明度当前仅支持单独的压力传感器。")
                }
                guard parameters[prefix+"OpacityUseSameCurve"] != "false" else {
                    throw Failure.invalid("仅支持统一的不透明度压感曲线。")
                }
                guard parameters[prefix+"OpacitycurveMode"] == nil || parameters[prefix+"OpacitycurveMode"] == "0" else {
                    throw Failure.invalid("不透明度曲线使用了尚未支持的合成方式。")
                }
                let raw=parameters[prefix+"OpacitycommonCurve"] ?? "0,0;1,1;"
                let points=try raw.split(separator:";").map { pair -> CurveControlPoint in
                    let values=pair.split(separator:",").compactMap {Float($0)}
                    guard values.count==2, values.allSatisfy({$0.isFinite && $0>=0 && $0<=1}) else {
                        throw Failure.invalid("压感曲线数据无效。")
                    }
                    return CurveControlPoint(x:values[0],y:values[1])
                }
                guard points.count==2,points[1].x>points[0].x,points[1].y>=points[0].y else {
                    throw Failure.invalid("目前只忠实导入两点线性压感曲线（含提前达到满值的曲线）。")
                }
                // Keep the real domain endpoint: x=0.25 is not x=1.
                tip.opacityPressureCurve=CurveChannelState(points:points)
            }
            if enabled(prefix+"PressureRotation") {
                let sensor=parameters[prefix+"RotationSensor"] ?? ""
                guard sensor.contains("id=\"fuzzy\""),
                      parameters[prefix+"RotationUseSameCurve"] != "false",
                      parameters[prefix+"RotationcurveMode"] == nil || parameters[prefix+"RotationcurveMode"] == "0",
                      (parameters[prefix+"RotationcommonCurve"] ?? "0,0;1,1;")=="0,0;1,1;" else {
                    throw Failure.invalid("此旋转传感器组合尚不支持。")
                }
                tip.angleJitterAmount=number(prefix+"RotationValue")
                tip.pressureRotationAmount=sensor.contains("id=\"pressure\"") ? 1:0
            }
            if index==0 { brush.size=Float(mask.width)*(Float(attr("scale")) ?? 1) }
            tips.append(tip)
        }
        tips[1].relativeSizeRatio=number("MaskingBrush/MasterSizeCoeff")
        brush.compoundBrush.primary=tips[0];brush.compoundBrush.secondary=tips[1]
        brush.engineV2?.primaryFlow=number("FlowValue")
        brush.engineV2?.secondaryFlow=number("MaskingBrush/Preset/FlowValue")
        return Result(name:brush.engineV2!.referenceName!,brush:brush,
            notes:["已导入真实 PNG 素材、间距、相对尺寸、恒定流量和两条不透明度压感曲线。",
                   "随机数序列、像素插值与 Krita 不同；不是逐像素兼容。"])
    }

    static func presetXML(_ data: Data) throws -> String {
        let bytes=[UInt8](data)
        guard bytes.count<32*1024*1024, bytes.prefix(8)==[137,80,78,71,13,10,26,10] else { throw Failure.invalid("不是有效的 KPP 文件。") }
        var offset=8
        while offset+12<=bytes.count {
            let length=bytes[offset..<offset+4].reduce(0){($0<<8)+Int($1)}
            guard length<=bytes.count-offset-12 else { throw Failure.invalid("KPP 数据已截断。") }
            let kind=String(bytes:bytes[offset+4..<offset+8],encoding:.ascii)
            let chunk=Array(bytes[offset+8..<offset+8+length])
            if kind=="iTXt",let end=chunk.firstIndex(of:0),String(bytes:chunk[..<end],encoding:.utf8)=="preset" {
                guard end+3<chunk.count,
                      chunk[end+1]<=1,chunk[end+2]==0,
                      let languageEnd=chunk[(end+3)...].firstIndex(of:0),
                      let translatedEnd=chunk[(languageEnd+1)...].firstIndex(of:0) else { throw Failure.invalid("KPP 元数据无效。") }
                var payload=Array(chunk[(translatedEnd+1)...])
                guard payload.count<=8*1024*1024 else { throw Failure.invalid("KPP 元数据超出大小限制。") }
                if chunk[end+1]==1 {
                    var decoded=[UInt8](repeating:0,count:8*1024*1024)
                    var size=uLongf(decoded.count)
                    let code=uncompress(&decoded,&size,payload,uLong(payload.count))
                    guard code==Z_OK else { throw Failure.invalid("KPP 元数据解压失败或超出大小限制。") }
                    payload=Array(decoded.prefix(Int(size)))
                }
                guard let xml=String(bytes:payload,encoding:.utf8) else { throw Failure.invalid("KPP 文字编码无效。") }
                return xml
            }
            offset+=length+12
        }
        throw Failure.invalid("KPP 不含可读取的笔刷参数。")
    }

    private static func alphaMask(_ png: Data) throws -> (data: Data,width: Int) {
        guard let source=CGImageSourceCreateWithData(png as CFData,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,
              let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,max(width,height)<=2048,
              let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw Failure.invalid("笔尖图像无效或过大。") }
        // PNG tips in Krita use inverted RGB luminance times alpha. Do not use
        // alpha alone (that turns opaque grayscale material into a solid box).
        var rgba=[UInt8](repeating:0,count:width*height*4)
        let ok=rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard ok else { throw Failure.invalid("无法解码笔尖图像。") }
        let side=max(width,height)
        var mask=[UInt8](repeating:0,count:side*side)
        for y in 0..<height { for x in 0..<width {
            let i=(y*width+x)*4
            let gray=(11*Int(rgba[i])+16*Int(rgba[i+1])+5*Int(rgba[i+2]))/32
            mask[(y+(side-height)/2)*side+x+(side-width)/2]=UInt8(max(0,Int(rgba[i+3])-gray))
        } }
        return (Data(mask),width)
    }
}

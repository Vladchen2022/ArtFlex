import AppKit

@MainActor
enum AppBuildIdentity {
    static func showAbout() {
        let bundle = Bundle.main
        let manifest = bundle.url(forResource: "BuildManifest", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "开发构建"
        let commit = (manifest["gitCommit"] as? String).map { String($0.prefix(12)) } ?? "未记录"
        let dirty = manifest["sourceDirty"] as? Bool == true ? "（含未提交改动）" : ""
        let fingerprint = (manifest["sourceFingerprint"] as? String).map { String($0.prefix(12)) } ?? "未记录"
        let credits = NSAttributedString(string: "代码版本：\(commit)\(dirty)\n源码指纹：\(fingerprint)\n运行位置：\(bundle.bundlePath)",
            attributes: [.font: NSFont.systemFont(ofSize: 11)])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "ArtFlex", .applicationVersion: version,
            .version: "", .credits: credits])
    }
}

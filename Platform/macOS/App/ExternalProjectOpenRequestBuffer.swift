import Foundation

struct ExternalProjectOpenRequestBuffer {
    private(set) var pendingURL: URL?

    mutating func receive(_ urls: [URL], isHandlerReady: Bool) -> URL? {
        guard let projectURL = urls.lazy.compactMap(FilePanelService.normalizedProjectOpenURL).first else {
            return nil
        }
        if isHandlerReady {
            return projectURL
        }
        // ArtFlex currently presents one document window. If Finder sends more
        // requests during launch, the most recent explicit request should win.
        pendingURL = projectURL
        return nil
    }

    mutating func takePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}

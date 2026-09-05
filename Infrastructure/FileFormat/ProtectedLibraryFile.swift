import Foundation

/// A failed load is not an empty library. Keep the original file write-protected until
/// a successful explicit reload, and retain the previous validated JSON before replacement.
/// Each controller owns one instance; its lock also serializes load/save state across queues.
final class ProtectedLibraryFile: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?

    var loadFailureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func load<Value>(from url: URL, decode: (Data) throws -> Value) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard let data = try readIfPresent(url) else { return nil }
            let value = try decode(data)
            failure = nil
            return value
        } catch {
            failure = protectedMessage(url: url, error: error)
            return nil
        }
    }

    func save(_ data: Data, to url: URL, validate: (Data) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw ProtectionError(message: failure) }
        try validate(data)
        let existing: Data?
        do {
            existing = try readIfPresent(url)
            if let existing { try validate(existing) }
        } catch {
            let message = protectedMessage(url: url, error: error)
            failure = message
            throw ProtectionError(message: message)
        }
        if let existing, existing != data {
            // Failure to preserve the previous version aborts before touching the live file.
            try existing.write(to: Self.previousVersionURL(for: url), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    static func previousVersionURL(for url: URL) -> URL {
        url.appendingPathExtension("previous")
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError { return nil }
    }

    private func protectedMessage(url: URL, error: Error) -> String {
        "无法读取资源库 \(url.lastPathComponent)，已阻止覆盖原文件：\(error.localizedDescription)"
    }

    private struct ProtectionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

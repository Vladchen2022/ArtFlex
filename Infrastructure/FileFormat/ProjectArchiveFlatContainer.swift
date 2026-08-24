import AppleArchive
import Foundation
import System

enum ProjectArchiveFlatContainerError: LocalizedError, Equatable {
    case sourceIsNotDirectory
    case sourceIsNotRegularFile
    case emptyArchive
    case archiveTooLarge(Int)
    case unsupportedArchiveEntry(String)
    case archiveOperationFailed(operation: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .sourceIsNotDirectory:
            return "待封装的 ArtFlex 工程不是目录"
        case .sourceIsNotRegularFile:
            return "ArtFlex 单文件工程不是普通文件"
        case .emptyArchive:
            return "ArtFlex 单文件工程为空"
        case .archiveTooLarge(let byteCount):
            return "ArtFlex 单文件工程超出读取上限（\(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))）"
        case .unsupportedArchiveEntry(let path):
            return "ArtFlex 单文件工程包含不安全的归档条目：\(path)"
        case .archiveOperationFailed(let operation, let reason):
            return "ArtFlex 单文件工程\(operation)失败：\(reason)"
        }
    }
}

/// Flat-file transport for the existing checked V2 package. AppleArchive supplies the container;
/// the V2 manifest remains the authoritative schema and integrity layer.
final class ProjectArchiveFlatContainer {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func encodePackage(at packageURL: URL, to archiveURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectArchiveFlatContainerError.sourceIsNotDirectory
        }
        // Project entries only need type, relative path, data, and POSIX mode. Omitting UID/GID
        // keeps documents portable across volumes whose inherited group ownership differs from
        // the app's extraction directory. The checked V2 manifest enforces content integrity.
        guard let portableArchiveKeySet = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD") else {
            throw ProjectArchiveFlatContainerError.archiveOperationFailed(
                operation: "封装",
                reason: "无法创建归档字段集合"
            )
        }

        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(archiveURL.path),
                mode: .writeOnly,
                options: [.create, .truncate],
                permissions: FilePermissions(rawValue: 0o600)
            ) { fileStream in
                try ArchiveStream.withEncodeStream(writingTo: fileStream) { encodeStream in
                    try encodeStream.writeDirectoryContents(
                        archiveFrom: FilePath(packageURL.path),
                        keySet: portableArchiveKeySet
                    )
                }
            }
        } catch let error as ProjectArchiveFlatContainerError {
            throw error
        } catch {
            throw ProjectArchiveFlatContainerError.archiveOperationFailed(
                operation: "封装",
                reason: error.localizedDescription
            )
        }
    }

    func withExtractedPackage<T>(
        from archiveURL: URL,
        limits: ProjectArchiveReadLimits,
        _ body: (URL) throws -> T
    ) throws -> T {
        let values = try archiveURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ProjectArchiveFlatContainerError.sourceIsNotRegularFile
        }
        let fileSize = values.fileSize ?? 0
        guard fileSize > 0 else {
            throw ProjectArchiveFlatContainerError.emptyArchive
        }
        let maximumContainerBytes = Self.maximumContainerByteCount(for: limits)
        guard fileSize <= maximumContainerBytes else {
            throw ProjectArchiveFlatContainerError.archiveTooLarge(fileSize)
        }

        let extractionRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "ArtFlex-Open-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: extractionRoot) }

        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(archiveURL.path),
                mode: .readOnly,
                options: [],
                permissions: []
            ) { fileStream in
                try ArchiveStream.withDecodeStream(readingFrom: fileStream) { decodeStream in
                    try ArchiveStream.withExtractStream(
                        extractingTo: FilePath(extractionRoot.path),
                        flags: [.ignoreOperationNotPermitted]
                    ) { extractStream in
                        _ = try ArchiveStream.process(
                            readingFrom: decodeStream,
                            writingTo: extractStream
                        )
                    }
                }
            }
            try validateExtractedEntries(in: extractionRoot)
            return try body(extractionRoot)
        } catch let error as ProjectArchiveFlatContainerError {
            throw error
        } catch {
            throw ProjectArchiveFlatContainerError.archiveOperationFailed(
                operation: "解包",
                reason: error.localizedDescription
            )
        }
    }

    private func validateExtractedEntries(in rootURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw ProjectArchiveFlatContainerError.archiveOperationFailed(
                operation: "校验",
                reason: "无法检查归档内容"
            )
        }

        for case let entryURL as URL in enumerator {
            let values = try entryURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw ProjectArchiveFlatContainerError.unsupportedArchiveEntry(
                    entryURL.lastPathComponent
                )
            }
        }
    }

    private static func maximumContainerByteCount(for limits: ProjectArchiveReadLimits) -> Int {
        let overheadAllowance = 32 * 1024 * 1024
        let (value, overflow) = limits.maximumTotalUncompressedBytes.addingReportingOverflow(
            overheadAllowance
        )
        return overflow ? Int.max : value
    }
}

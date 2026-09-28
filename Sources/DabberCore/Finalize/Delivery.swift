import Foundation

public enum DeliveryError: LocalizedError, Equatable {
    case otherVolume
    case folderMissing(String)
    case copyMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .otherVolume: return "not on the same volume"
        case .folderMissing(let path): return "folder not found: \(path)"
        case .copyMismatch(let folder): return "copy of \(folder) did not match"
        }
    }
}

public struct DeliveryFailed: Error {
    public let dir: URL
    public let reason: String
}

public struct Mover: Sendable {
    public var move: @Sendable (URL, URL) throws -> Void
    public var copy: @Sendable (URL, URL) throws -> Void

    public init(move: @escaping @Sendable (URL, URL) throws -> Void, copy: @escaping @Sendable (URL, URL) throws -> Void) {
        self.move = move
        self.copy = copy
    }

    public static let live = Mover(
        move: { from, to in
            guard try sameVolume(from, to.deletingLastPathComponent()) else { throw DeliveryError.otherVolume }
            try FileManager.default.moveItem(at: from, to: to)
        },
        copy: { try FileManager.default.copyItem(at: $0, to: $1) })

    static func sameVolume(_ a: URL, _ b: URL) throws -> Bool {
        let ids = try [a, b].map { try $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
        return ids[0] != nil && ids[0] == ids[1]
    }
}

public enum Delivery {
    public static let partialSuffix = ".partial"
    private static let lock = NSLock()

    public static func finishAndDeliver(_ dir: URL, output: URL, mover: Mover = .live) throws -> URL {
        try lock.withLock {
            let done = try Finalizer.finish(dir)
            let moved: URL
            do {
                moved = try deliver(done, into: output, mover: mover)
            } catch {
                throw DeliveryFailed(dir: done, reason: error.localizedDescription)
            }
            if let failure = deliverPending(from: done.deletingLastPathComponent(), to: output, mover: mover) {
                throw DeliveryFailed(dir: moved, reason: failure)
            }
            return moved
        }
    }

    public static func recover(
        _ dirs: [URL], work: URL, output: URL, mover: Mover = .live,
        onError: (URL, any Error) -> Void = { _, _ in }, onReport: (URL, FinalizeReport) -> Void = { _, _ in }
    ) -> String? {
        lock.withLock {
            Finalizer.recoverAll(dirs: dirs, onError: onError, onReport: onReport)
            return deliverPending(from: work, to: output, mover: mover)
        }
    }

    public static func deliverPending(from work: URL, to output: URL, mover: Mover = .live) -> String? {
        var failure: String?
        for dir in Finalizer.sessionFolders(root: work) where (try? SessionManifest.load(from: dir))?.finalize != nil {
            do {
                _ = try deliver(dir, into: output, mover: mover)
            } catch {
                failure = failure ?? error.localizedDescription
            }
        }
        return failure
    }

    public static func adoptUnfinished(from legacy: URL, into work: URL) throws -> [URL] {
        let unfinished = Finalizer.sessionFolders(root: legacy).filter(Finalizer.needsRecovery)
        guard !unfinished.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return try unfinished.map { dir in
            try place(dir.lastPathComponent, in: work) { try FileManager.default.moveItem(at: dir, to: $0) }
        }
    }

    public static func deliver(_ dir: URL, into output: URL, mover: Mover = .live) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDir), isDir.boolValue else {
            throw DeliveryError.folderMissing(output.path)
        }
        let name = try SessionManifest.load(from: dir).name
        do {
            return try place(name, in: output) { try mover.move(dir, $0) }
        } catch DeliveryError.otherVolume {
            let copy = output.appendingPathComponent("." + dir.lastPathComponent + partialSuffix)
            try? FileManager.default.removeItem(at: copy)
            do {
                try mover.copy(dir, copy)
                guard try listing(copy) == listing(dir) else { throw DeliveryError.copyMismatch(dir.lastPathComponent) }
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            let target = try place(name, in: output) { try FileManager.default.moveItem(at: copy, to: $0) }
            try FileManager.default.removeItem(at: dir)
            return target
        }
    }

    private static func listing(_ dir: URL) throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        for file in try FileManager.default.subpathsOfDirectory(atPath: dir.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)
            sizes[file] = attrs[.type] as? FileAttributeType == .typeDirectory ? -1 : attrs[.size] as? Int
        }
        return sizes
    }

    static func place(_ name: String, in parent: URL, _ move: (URL) throws -> Void) throws -> URL {
        var n = 1
        while true {
            let target = parent.appendingPathComponent(n == 1 ? name : "\(name) \(n)")
            do {
                try move(target)
                return target
            } catch CocoaError.fileWriteFileExists {
                n += 1
            }
        }
    }
}

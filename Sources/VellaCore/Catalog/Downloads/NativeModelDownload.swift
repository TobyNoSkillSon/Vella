import Foundation
import CryptoKit

/// The Hub is only a source of data. Neither repository code nor a Hub-provided
/// path is ever executed; every byte is checked against the pinned revision's blob identity.
/// Its mutable state is guarded by `lock` (URLSession calls the delegate on its own queue).
public final class NativeModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct SourceFile {
        let repository: String
        let revision: String
        let name: String
        let size: Int64
        let etag: String
    }
    enum DownloadError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    private let baseURL: URL
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var transfer:
        (handle: FileHandle, continuation: CheckedContinuation<Void, Error>, expected: Int64, offset: Int64, received: Int64, responseAccepted: Bool, report: (Int64) -> Void)?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false
    private var lastReport = Date.distantPast
    private let progress: (String, Int64?, Int64?) -> Void
    private let catalogURL: URL

    public init(
        baseURL: URL = URL(string: "https://huggingface.co")!, configuration: URLSessionConfiguration = .default, catalogURL: URL,
        progress: @escaping (String, Int64?, Int64?) -> Void
    ) {
        self.baseURL = baseURL; self.configuration = configuration; self.catalogURL = catalogURL; self.progress = progress
    }
    public func cancel() {
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel()
    }
    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        try Task.checkCancellation()
    }
    private func url(_ segments: [String], query: String? = nil) throws -> URL {
        guard
            let value = URL(
                string: segments.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? "" }.joined(
                    separator: "/"), relativeTo: baseURL)?.absoluteURL,
            value.host == baseURL.host
        else { throw DownloadError.invalid("Invalid pinned Hub URL") }
        return query.flatMap { URL(string: value.absoluteString + "?" + $0) } ?? value
    }
    private static func safe(_ name: String) -> Bool {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") } && !name.hasPrefix(".") && !name.contains("/.cache/")
            && !name.contains("\0")
    }
    private static func allowed(_ name: String, processor: Set<String>?) -> Bool {
        if name.hasSuffix(".py") { return false }
        if let processor { return processor.contains(name) }
        let extensionAllowed = ["json", "safetensors", "tiktoken", "txt", "model", "mvn"].contains(URL(fileURLWithPath: name).pathExtension)
        return extensionAllowed || name == "README.md" || name.hasPrefix("LICENSE")
    }
    private func metadata(repository: String, revision: String, processor: Set<String>?) async throws -> [SourceFile] {
        guard repository.split(separator: "/").count == 2,
            repository.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_/ .".contains($0)) }),
            revision.count == 40, revision.allSatisfy({ $0.isHexDigit })
        else { throw DownloadError.invalid("Invalid pinned repository or revision") }
        let endpoint = try url(["api", "models"] + repository.split(separator: "/").map(String.init) + ["revision", revision], query: "blobs=true")
        var request = URLRequest(url: endpoint); request.timeoutInterval = 20
        let metadataSession = URLSession(configuration: configuration)
        defer { metadataSession.invalidateAndCancel() }
        let (data, response) = try await metadataSession.data(for: request)
        try checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            document["sha"] as? String == revision,
            let siblings = document["siblings"] as? [[String: Any]]
        else { throw DownloadError.invalid("Hub did not return the pinned revision metadata") }
        var result: [SourceFile] = []
        for sibling in siblings {
            guard let name = sibling["rfilename"] as? String, Self.allowed(name, processor: processor) else { continue }
            guard Self.safe(name) else { throw DownloadError.invalid("Unsafe repository filename") }
            let lfs = sibling["lfs"] as? [String: Any]
            guard let number = sibling["size"] as? NSNumber, number.int64Value >= 0 else { throw DownloadError.invalid("Hub did not supply a file size") }
            guard let etag = (lfs?["sha256"] as? String) ?? (sibling["blobId"] as? String),
                [40, 64].contains(etag.count), etag.allSatisfy({ $0.isHexDigit })
            else { throw DownloadError.invalid("Hub did not supply a content identity") }
            result.append(SourceFile(repository: repository, revision: revision, name: name, size: number.int64Value, etag: etag))
        }
        return result
    }
    /// Verify a downloaded file against its Hub identity (SHA-256 for LFS, git blob SHA-1 otherwise).
    static func digest(_ file: URL, size: Int64, etag: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        // Each read returns an autoreleased buffer; on a Swift concurrency thread nothing drains them until the task
        // ends, so without a pool per chunk verifying a multi-GB checkpoint kept the whole file in heap (the
        // same pattern as FastPathGate.key).
        func each(_ body: (Data) -> Void) throws {
            while try autoreleasepool(invoking: {
                guard let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty else { return false }
                body(data)
                return true
            }) {}
        }
        if etag.count == 64 {
            var hash = SHA256()
            try each { hash.update(data: $0) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == etag.lowercased()
        }
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(size)\0".utf8))
        try each { hash.update(data: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == etag.lowercased()
    }
    private static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
    private func paths(_ file: SourceFile, destination: URL) -> (final: URL, partial: URL, metadata: URL) {
        let final = destination.appendingPathComponent(file.name)
        let meta = destination.appendingPathComponent(".cache/huggingface/download").appendingPathComponent(file.name + ".metadata")
        let hash = Data(Insecure.SHA1.hash(data: Data(meta.lastPathComponent.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/", with: "_")
        return (final, meta.deletingLastPathComponent().appendingPathComponent("\(hash).\(file.etag).incomplete"), meta)
    }
    private func unlinked(_ url: URL, root: URL) throws {
        var cursor = url
        while cursor.path.hasPrefix(root.path + "/") || cursor == root {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path) {
                if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
                    || ((attributes[.type] as? FileAttributeType) == .typeRegular && (attributes[.referenceCount] as? Int ?? 1) > 1)
                {
                    throw DownloadError.invalid("Linked/shared model asset preserved: \(cursor.path)")
                }
            }
            if cursor == root { break }; cursor.deleteLastPathComponent()
        }
    }
    public func download(_ model: ModelRecommendation, modelsDirectory: URL) async throws -> URL {
        guard Self.safe(model.id), !model.repository.isEmpty else { throw DownloadError.invalid("Only curated models can be downloaded") }
        try checkCancellation()
        let destination = modelsDirectory.appendingPathComponent(model.id)
        try unlinked(destination, root: modelsDirectory)
        progress("Checking pinned Hugging Face files…", nil, nil)
        var files = try await metadata(repository: model.repository, revision: model.revision, processor: nil)
        // Processor files override the same names in the primary source, exactly as snapshot_download does.
        if let recipe = try processorSource(model) {
            let extra = try await metadata(repository: recipe.repository, revision: recipe.revision, processor: Set(recipe.files))
            var byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })
            for file in extra { byName[file.name] = file }
            files = Array(byName.values)
        }
        guard !files.isEmpty else { throw DownloadError.invalid("Pinned model contains no allowed data files") }
        files.sort { $0.name < $1.name }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var completed: Int64 = 0
        for file in files {
            try checkCancellation()
            let location = paths(file, destination: destination)
            for path in [location.final, location.partial, location.metadata] { try unlinked(path, root: modelsDirectory) }
            try FileManager.default.createDirectory(at: location.metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: location.final.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = (try? location.metadata.readText())?.components(separatedBy: .newlines) ?? []
            if existing.count >= 2 && existing[1] == file.etag && Self.size(location.final) == file.size,
                try Self.digest(location.final, size: file.size, etag: file.etag)
            {
                completed += file.size; progress("Downloading from Hugging Face…", min(completed, Int64(Double(total) * 0.99)), total)
                continue
            }
            var offset = Self.size(location.partial) ?? 0
            if offset > file.size { try FileManager.default.removeItem(at: location.partial); offset = 0 }
            if offset != file.size {
                progress("Downloading from Hugging Face…", min(completed + offset, Int64(Double(total) * 0.99)), total)
                try await fetch(file, to: location.partial, from: offset) { [progress] bytes in
                    progress("Downloading from Hugging Face…", min(completed + bytes, Int64(Double(total) * 0.99)), total)
                }
            }
            guard Self.size(location.partial) == file.size else { throw DownloadError.invalid("Downloaded file size mismatch: \(file.name)") }
            guard try Self.digest(location.partial, size: file.size, etag: file.etag) else {
                try? FileManager.default.removeItem(at: location.partial)
                throw DownloadError.invalid("Downloaded content checksum mismatch: \(file.name)")
            }
            if FileManager.default.fileExists(atPath: location.final.path) { try FileManager.default.removeItem(at: location.final) }
            try FileManager.default.moveItem(at: location.partial, to: location.final)
            try "\(file.revision)\n\(file.etag)\n\(Date().timeIntervalSince1970)\n".write(to: location.metadata, atomically: true, encoding: .utf8)
            completed += file.size
        }
        progress("Verifying downloaded model…", Int64(Double(total) * 0.99), total)
        try NativeModelDownload.validate(destination, expected: model)
        try checkCancellation()
        return destination
    }
    private func processorSource(_ model: ModelRecommendation) throws -> ProcessorSource? {
        // Catalog metadata is decoded by the caller; optional recipes are looked up in its exact catalog (v2 or legacy).
        try VellaCore.processorSource(variant: model.id, catalogURL: catalogURL)
    }

    private func fetch(_ file: SourceFile, to partial: URL, from offset: Int64, report: @escaping (Int64) -> Void) async throws {
        let endpoint = try url(file.repository.split(separator: "/").map(String.init) + ["resolve", file.revision] + file.name.split(separator: "/").map(String.init))
        var request = URLRequest(url: endpoint); request.timeoutInterval = 120
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            transfer = (handle, continuation, file.size, offset, offset, false, report)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            let stopped = cancelled
            lock.unlock()
            task.resume()
            if stopped { task.cancel() }
        }
        try checkCancellation()
        report(file.size)
    }
    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock(); defer { lock.unlock() }
        guard var state = transfer, let http = response as? HTTPURLResponse,
            http.statusCode == 200 || http.statusCode == 206
        else { completionHandler(.cancel); return }
        if http.statusCode == 206 {
            guard state.offset > 0, http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(state.offset)-") == true else { completionHandler(.cancel); return }
            do { try state.handle.seekToEnd() } catch { completionHandler(.cancel); return }
        } else {
            do { try state.handle.truncate(atOffset: 0); try state.handle.seek(toOffset: 0) } catch { completionHandler(.cancel); return }
            state.received = 0
        }
        state.responseAccepted = true; transfer = state; completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var state = transfer, state.responseAccepted else { lock.unlock(); dataTask.cancel(); return }
        var notification: (() -> Void)?
        var failed = false
        do {
            try state.handle.write(contentsOf: data); state.received += Int64(data.count); transfer = state
            if Date().timeIntervalSince(lastReport) >= 0.25 {
                lastReport = Date(); notification = { state.report(state.received) }
            }
        } catch { failed = true }
        lock.unlock()
        notification?()
        if failed { dataTask.cancel() }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let state = transfer; transfer = nil; self.task = nil; self.session = nil; lock.unlock()
        guard let state else { return }
        try? state.handle.close()
        if cancelled {
            state.continuation.resume(throwing: CancellationError())
        } else if let error {
            state.continuation.resume(throwing: error)
        } else if !state.responseAccepted || state.received != state.expected {
            state.continuation.resume(throwing: DownloadError.invalid("Downloaded file size mismatch or invalid range response (\(state.received)/\(state.expected))"))
        } else {
            state.continuation.resume()
        }
    }
    public static func validate(_ folder: URL, expected: ModelRecommendation) throws {
        let manager = FileManager.default
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("config.json"))) as? [String: Any]
        let architecture = checkpointArchitecture(config) ?? ""
        guard architecture == expected.architecture else { throw DownloadError.invalid("Model architecture does not match recommendation") }
        for name in ["config.json", "tokenizer_config.json"] {
            let path = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: path.path), let data = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any], data["auto_map"] != nil {
                throw DownloadError.invalid("Custom remote-code mappings are not supported")
            }
        }
        if let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let path as URL in enumerator {
                if path.pathExtension == "py" { throw DownloadError.invalid("Model directory contains executable repository code") }
                if (try path.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw DownloadError.invalid("Linked model asset is not supported") }
            }
        }
        let quant = (config?["quantization"] ?? config?["quantization_config"]) as? [String: Any]
        let bits = quant?["bits"] as? Int
        let expectedBits = Int(expected.quantization.split(separator: "-").first ?? "")
        guard expectedBits == nil ? bits == nil : bits == expectedBits else {
            throw DownloadError.invalid(expectedBits == nil ? "Expected unquantized weights" : "Quantization does not match recommendation")
        }
        guard try manager.contentsOfDirectory(atPath: folder.path).contains(where: { $0.hasSuffix(".safetensors") }) else {
            throw DownloadError.invalid("Model weights are missing")
        }
    }
}

private extension URL {
    func readText() throws -> String { try String(contentsOf: self, encoding: .utf8) }
}

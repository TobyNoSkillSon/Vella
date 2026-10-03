import Foundation
import VellaCore

/// The dictation models the API can use, as the app knows them.
@MainActor protocol APIModelSource: AnyObject {
    /// Dictation models whose weights are on this Mac, each at the precision a request would load (loaded, else last
    /// loaded, else recommended, else any downloaded one).
    func models() -> [APIModel]
    /// Why an id is not usable (not downloaded, a streaming model); nil when it is unknown.
    func unavailableReason(_ id: String) -> String?
    /// Files for a model returned by `models()` (a precision made on this Mac is prepared here).
    func prepare(_ model: APIModel) throws -> APIModel
}

/// Routes: `GET /status`, `GET /v1/models`, `GET /v1/models/{id}`, `POST /v1/audio/transcriptions` (OpenAI-compatible).
@MainActor final class APIService: APIHandling {
    /// Names that mean "the current dictation model" (OpenAI SDK examples send whisper-1).
    static let currentAliases: Set<String> = ["", "whisper-1", "vella", "default", "current"]
    let transcriber: APITranscriber
    var controls: ModelControls?
    /// Strong: the service is the source's only owner (APIHost creates it inline). A weak reference here freed it at
    /// once, so the shipped 1.0.0 (b33) listed no models and resolved no model name.
    var models: APIModelSource?
    var runtime: Runtime { transcriber.backend.runtime }
    /// The dictation state for /status ("idle", "recording", "transcribing").
    var dictationState: () -> String = { "idle" }
    let version: String
    /// Upload scratch space (parts of multipart bodies); removed per request.
    let scratch: URL
    /// The per-launch secret a JSON `path` request must send as `X-Vella-Token` (from worker-status.json).
    var pathToken: String? { runtime.apiToken }

    init(
        transcriber: APITranscriber, models: APIModelSource?, scratch: URL,
        version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    ) {
        self.transcriber = transcriber; self.models = models; self.scratch = scratch; self.version = version
    }

    func handle(_ request: APIRequest) async -> APIResponse {
        guard let route = APIRoute.match(request.head.path) else { return .error(APIError(404, "no route \(request.head.path)")) }
        do {
            switch route {
            case .catalog: return .json(200, ["object": "list", "data": controls?.catalog() ?? (models?.models() ?? []).map(modelObject)])
            case .settings:
                guard let controls else { throw APIError(503, "Model controls are not attached") }
                return .json(200, controls.settings())
            case .modelAction(let id, let action):
                let fields = try controlFields(request)
                guard let controls else { throw APIError(503, "Model controls are not attached") }
                return .json(200, try await controls.perform(action, id: id, fields: fields))
            case .settingAction(let action):
                let fields = try controlFields(request)
                guard let controls else { throw APIError(503, "Model controls are not attached") }
                return .json(200, try controls.setting(action, fields: fields))
            case .status: return .json(200, status())
            case .models: return .json(200, ["object": "list", "data": (models?.models() ?? []).map(modelObject)])
            case .model(let id):
                guard let model = try resolve(id, allowAlias: false) else { throw APIError(404, "unknown model \(id)", param: "model", code: "model_not_found") }
                return .json(200, modelObject(model))
            case .transcriptions: return try await transcribe(request)
            }
        } catch let error as APIError {
            return .error(error)
        } catch is CancellationError {
            ModelLibrary.downloadLog.notice(
                "API \(request.head.method, privacy: .public) \(request.head.path, privacy: .public) ended cancelled: \(APIJobCancellation.current?.source ?? "request task", privacy: .public)")
            return .error(APIError(499, "request cancelled"))
        } catch {
            return .error(APIError(500, error.localizedDescription))
        }
    }

    /// Fixed work for every same-length candidate; token length is public, content is not.
    static func tokensEqual(_ candidate: String?, _ expected: String) -> Bool {
        guard let candidate else { return false }
        let supplied = Array(candidate.utf8), secret = Array(expected.utf8)
        guard supplied.count == secret.count else { return false }
        var difference: UInt8 = 0
        for index in secret.indices { difference |= supplied[index] ^ secret[index] }
        return difference == 0
    }

    private func controlFields(_ request: APIRequest) throws -> [String: Any] {
        guard let token = pathToken, Self.tokensEqual(request.head.headers["x-vella-token"], token) else {
            throw APIError(403, "Model and settings controls need X-Vella-Token from worker-status.json")
        }
        guard case .memory(let data) = request.body, data.count <= apiMaxJSONBytes,
            let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw APIError(400, "Model controls need a JSON object")
        }
        return fields
    }

    // MARK: Status

    func status() -> [String: Any] {
        var object: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(runtime.status), let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { object = decoded }
        object["api"] = vellaAPIVersion
        object["app"] = "Vella"
        object["version"] = version
        object["pid"] = Int(getpid())
        if let port = runtime.apiPort { object["port"] = port }
        object.removeValue(forKey: "api_token")
        object["dictation"] = dictationState()
        let available = models?.models() ?? []
        object["dictation_model"] =
            available.first(where: \.current).map { m -> [String: Any] in
                var o: [String: Any] = ["id": m.id, "name": m.name, "precision": m.precision]
                if let s = m.selection { o["selection"] = selectionObject(s) }
                return o
            } ?? NSNull()
        object["api_jobs"] = ["running": transcriber.running, "waiting": transcriber.waiting, "completed": transcriber.completed]
        return object
    }

    /// `selection`: what the model runs (loaded) or would run (tier, Standard/Optimized, Exact/Fast); `requested_selection`
    /// only when an Optimized selection runs on stock MLX (its self-test failed, or a runtime fallback).
    func modelObject(_ model: APIModel) -> [String: Any] {
        var o: [String: Any] = [
            "id": model.id, "object": "model", "created": 0, "owned_by": "vella", "name": model.name, "precision": model.precision,
            "languages": model.languages, "loaded": model.loaded, "current": model.current
        ]
        if let s = model.selection { o["selection"] = selectionObject(s) }
        if let r = model.requested { o["requested_selection"] = selectionObject(r) }
        return o
    }

    // MARK: Models

    /// A family id (case-insensitive), or an alias of the current dictation model. Nil when unknown.
    func resolve(_ requested: String, allowAlias: Bool = true) throws -> APIModel? {
        let available = models?.models() ?? []
        let key = requested.trimmingCharacters(in: .whitespaces).lowercased()
        if allowAlias, Self.currentAliases.contains(key) {
            guard let current = available.first(where: \.current) else {
                throw APIError(404, "No dictation model is selected yet. Load one in Vella → Models…, or name one from GET /v1/models.", param: "model", code: "model_not_found")
            }
            return current
        }
        if let model = available.first(where: { $0.id.lowercased() == key }) { return model }
        if let reason = models?.unavailableReason(requested) { throw APIError(404, reason, param: "model", code: "model_not_found") }
        return nil
    }

    // MARK: Transcription

    private func transcribe(_ request: APIRequest) async throws -> APIResponse {
        let options: TranscriptionOptions
        let audio: URL
        var cleanup: URL?
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        switch request.body {
        case .memory(let data):
            guard let token = pathToken, Self.tokensEqual(request.head.headers["x-vella-token"], token) else {
                throw APIError(
                    403, "a JSON request that names a local file needs X-Vella-Token (api_token in worker-status.json); or upload the file as multipart/form-data", param: "path")
            }
            let parsed = try TranscriptionOptions.validate(json: data)
            options = parsed.options
            let url = URL(fileURLWithPath: parsed.path).standardizedFileURL
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey])
            guard values?.isRegularFile == true, values?.isReadable == true else {
                throw APIError(400, "path is not a readable file: \(parsed.path)", param: "path")
            }
            guard Int64(values?.fileSize ?? 0) <= apiMaxPathFileBytes else { throw APIError(413, "the file is larger than 4 GB", param: "path") }
            audio = url
        case .file(let body):
            let boundary = Multipart.boundary(request.head.headers["content-type"] ?? "") ?? ""
            let data = try Data(contentsOf: body, options: .alwaysMapped)
            let parts = try Multipart.parse(data, boundary: boundary)
            var fields: [String: [String]] = [:]
            var file: MultipartPart?
            for part in parts {
                if part.name == "file" {
                    guard file == nil else { throw APIError(400, "file was sent more than once", param: "file") }
                    file = part; continue
                }
                guard part.range.count <= 64 * 1024 else { throw APIError(400, "field \(part.name) is too large", param: part.name) }
                guard let value = String(data: data.subdata(in: part.range), encoding: .utf8) else { throw APIError(400, "field \(part.name) is not UTF-8", param: part.name) }
                fields[part.name, default: []].append(value)
            }
            options = try TranscriptionOptions.validate(fields)
            guard let file, !file.range.isEmpty else { throw APIError(400, "file is required: the audio file as a multipart/form-data upload", param: "file") }
            // Resolve the model before copying anything, so a bad name costs nothing.
            _ = try model(for: options)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = scratch.appendingPathComponent(UUID().uuidString + Self.fileExtension(file.filename))
            cleanup = url; audio = url
            // Written from the mapped body in slices: a 200 MB upload is never copied into memory.
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                let handle = try? FileHandle(forWritingTo: url)
            else { throw APIError(507, "Vella could not store the upload") }
            defer { try? handle.close() }
            var offset = file.range.lowerBound
            while offset < file.range.upperBound {
                let end = min(offset + 8 << 20, file.range.upperBound)
                do { try handle.write(contentsOf: data[(data.startIndex + offset)..<(data.startIndex + end)]) } catch { throw APIError(507, "Vella could not store the upload") }
                offset = end
            }
        case .none:
            throw APIError(400, "file is required: the audio file as a multipart/form-data upload", param: "file")
        }
        // Resolved again when the request's turn comes and before each segment: the current model and the precision
        // the user committed may change while it waits.
        let result = try await transcriber.transcribe(
            audio,
            resolve: { [weak self] in
                guard let self else { throw CancellationError() }
                let chosen = try self.model(for: options)
                return try self.models?.prepare(chosen) ?? chosen
            }, current: { [weak self] in (self?.models?.models() ?? []).first(where: \.current)?.id })
        let rendered = TranscriptFormatter.render(
            options.format, text: result.text, segments: result.segments,
            duration: result.duration, language: options.language)
        return APIResponse(status: 200, contentType: rendered.contentType, body: rendered.body)
    }
    private func model(for options: TranscriptionOptions) throws -> APIModel {
        guard let model = try resolve(options.model) else {
            throw APIError(404, "unknown model \(options.model); see GET /v1/models", param: "model", code: "model_not_found")
        }
        return model
    }
    /// ".mp3" from "talk.MP3": a hint for AVFoundation's format detection; letters and digits only.
    static func fileExtension(_ filename: String?) -> String {
        guard let ext = filename.map({ URL(fileURLWithPath: $0).pathExtension.lowercased() }), (1...5).contains(ext.count),
            ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return "" }
        return "." + ext
    }
}

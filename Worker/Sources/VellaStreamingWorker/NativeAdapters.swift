import Foundation
import MLX
import MLXAudioSTT

final class NemotronNative: StreamingNative {
    var text = ""
    private var model: NemotronASRModel?
    private var session: VellaNemotronSession?
    init(_ path: URL) throws {
        model = try NemotronASRModel.fromDirectory(path)
        VellaNemotronNumerics.useReferencePositionTable(model!)
        if VellaNemotronOptions.f32Weights { VellaNemotronNumerics.convertFloat32Weights(model!) }
        try reset()
    }
    func reset() throws {
        VellaStreamProfile.flush()
        session = nil; text = ""; deferred = false
        session = try VellaNemotronSession(model: model!)
        Memory.clearCache()
    }
    private var deferred = false
    private let coalesce = VellaNemotronOptions.coalesce
    func push(_ samples: [Float], final: Bool) throws {
        // Coalesce: the frontend ingests every 20-ms block as before (lazy graph);
        // the encoder, decoder and host sync run once per request in flush().
        if coalesce && !final { session!.ingest(samples); deferred = true; return }
        _ = try flush()
        text += try session!.push(samples, final: final)
    }
    func flush() throws -> Bool {
        guard deferred else { return false }
        deferred = false
        text += try session!.push([], final: false)
        return true
    }
    func close() { VellaStreamProfile.flush(); session = nil; model = nil; Stream.gpu.synchronize(); Memory.clearCache() }
}
func loadStreamingNative(_ path: URL) throws -> any StreamingNative {
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("config.json"))) as! [String: Any]
    if config["model_type"] as? String == "nemotron_asr" { return try NemotronNative(path) }
    return try VoxtralNative(path)
}
final class VoxtralNative: StreamingNative {
    var text = ""
    private var model: VoxtralRealtimeModel?
    private var session: VellaVoxtralSession?
    private var pending: [Float] = []
    init(_ path: URL) throws { model = try VoxtralRealtimeModel.fromDirectory(path); try reset() }
    func reset() throws {
        session = nil; text = ""; pending.removeAll()
        session = VellaVoxtralSession(model: model!)
        Memory.clearCache()
    }
    func push(_ samples: [Float], final: Bool) throws {
        guard let session, !session.done else { throw StreamingFailure.inference }
        pending += samples
        if !final && pending.count < 1280 { return }
        try session.feed(pending, final: final); pending.removeAll(keepingCapacity: true)
        text += session.step()
        if final {
            for _ in 0..<32 { if session.done { break }; text += session.step() }
            guard session.done else { throw StreamingFailure.inference }
        } else if session.done { throw StreamingFailure.inference }
    }
    func close() { session = nil; model = nil; pending.removeAll(); Stream.gpu.synchronize(); Memory.clearCache() }
}

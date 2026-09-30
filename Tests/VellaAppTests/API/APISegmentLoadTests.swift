import XCTest
@testable import Vella
@testable import VellaCore

/// A file whose later segment needs a model that is not loaded (another one selected, or its model unloaded, between
/// segments) loads it outside the request lane: a dictation that finishes during that load runs at once instead of
/// waiting for the load and the API segment after it.
final class APISegmentLoadTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vella-api-segment-load-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(5)
        while !condition() && Date() < until { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    /// A model the fake worker takes 1 s to load (its folder name contains `delayload`).
    private func slowModel() throws -> APIModel {
        let folder = root.appendingPathComponent("gamma-delayload")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return APIModel(id: "gamma-delayload", name: "Gamma", precision: "", path: folder.path)
    }
    /// Starts a multi-segment file and holds it after its first segment until `between` has run. The backend's
    /// metrics are set only by a finished transcription (loads leave them empty), so they mark the first segment done.
    @MainActor private func fileHeldBetweenSegments(_ f: TwoFamilyFixture, resolve: @escaping () -> APIModel,
                                                    between: () async throws -> Void) async throws -> Task<APITranscript, Error> {
        let transcriber = APITranscriber(backend: f.backend, root: root.appendingPathComponent("api-jobs"))
        transcriber.pollNanoseconds = 5_000_000
        let backend = f.backend
        XCTAssertTrue(backend.lastMetrics.isEmpty, "nothing transcribed yet")
        var released = false
        transcriber.dictationActive = { !backend.lastMetrics.isEmpty && !released }
        let audio = root.appendingPathComponent("file.wav")
        try writeTestWAV(audio) // several segments
        let job = Task { try await transcriber.transcribe(audio, resolve: resolve, current: { "alpha" }) }
        try await waitUntil { !backend.lastMetrics.isEmpty && !backend.isBusy && transcriber.running == 1 }
        try await between()
        released = true
        return job
    }
    /// While the API's model loads: the request lane is free and a dictation on its loaded model finishes before
    /// that load does.
    @MainActor private func assertDictationRunsDuringTheLoad(_ f: TwoFamilyFixture, of id: String, dictationModel: String) async throws {
        try await waitUntil { f.runtime.status.loading == id }
        XCTAssertFalse(f.backend.isBusy, "the model loads outside the request lane")
        let clip = root.appendingPathComponent("dictation-\(UUID()).wav")
        try writeTestWAV(clip, bursts: [0.2], gap: 0.01)
        let started = Date()
        let text = try await f.backend.transcribe(clip, config: Configuration(model: dictationModel))
        XCTAssertEqual(text, "Fixture recognized speech.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8, "the dictation did not wait for the API's model to load")
        XCTAssertEqual(f.runtime.status.loading, id, "the dictation finished while that model was still loading")
    }

    @MainActor func testModelSelectedBetweenSegmentsLoadsOutsideTheRequestLane() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.alpha, "4b")
        let alpha = APIModel(id: "alpha", name: "Alpha", precision: "4b", path: try f.path(f.alpha, "4b"))
        let slow = try slowModel()
        var switched = false
        let job = try await fileHeldBetweenSegments(f, resolve: { switched ? slow : alpha }, between: { switched = true })
        try await assertDictationRunsDuringTheLoad(f, of: slow.id, dictationModel: alpha.path)
        let result = try await job.value
        XCTAssertEqual(result.model.path, slow.path, "the later segments used the model selected meanwhile")
        XCTAssertTrue(f.runtime.isLoaded(slow.id))
    }

    @MainActor func testModelUnloadedBetweenSegmentsReloadsOutsideTheRequestLane() async throws {
        let f = try TwoFamilyFixture(root); defer { f.close() }
        try await f.load(f.alpha, "4b")
        let alpha = try f.path(f.alpha, "4b")
        let slow = try slowModel()
        let job = try await fileHeldBetweenSegments(f, resolve: { slow }, between: {
            XCTAssertTrue(f.runtime.isLoaded(slow.id))
            await f.runtime.unload(slow.id)
            try await waitUntil { !f.runtime.isLoaded(slow.id) }
        })
        try await assertDictationRunsDuringTheLoad(f, of: slow.id, dictationModel: alpha)
        let result = try await job.value
        XCTAssertEqual(result.model.path, slow.path)
        XCTAssertTrue(f.runtime.isLoaded(slow.id))
    }
}

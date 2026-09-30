import XCTest
import VellaTestSupport

/// Golden gate strings. Every persisted fast-path verdict is keyed by the gate version, each model's fast-path
/// revision and a few key tokens (FastPathGate.key). Moving or splitting worker files must never change one of them,
/// or every Mac requalifies (or, worse, reuses a verdict for different code). The worker package needs MLX to build,
/// so the literals are checked from source: each must appear exactly once anywhere under Worker/Sources.
final class GateStringTests: XCTestCase {
    static let root = Repository.root

    func workerSources() throws -> [(URL, String)] {
        let sources = Self.root.appendingPathComponent("Worker/Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try files.map { ($0, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func occurrences(_ needle: String, in sources: [(URL, String)]) -> Int {
        sources.reduce(0) { $0 + $1.1.components(separatedBy: needle).count - 1 }
    }

    /// Gate version, model revisions and key tokens, as they appear in source (quoted where a bare token is ambiguous).
    static let golden = [
        #"static let version = "native-kernels-10""#,
        #""parakeet-r2-dense-encoder""#,
        #""+nax2+smallm-""#,
        #"tileRevision = "tile-1""#,
        #"gemvRevision = "gemv-1""#,
        #"qtileRevision = "qtile-1""#,
        #""+int8-2+smallm-""#,
        #""+int4-2+smallm-""#,
        #""whisper-3-f16-model""#,
        #""whisper-3""#,
        #""qwen3-asr-3-f32-encoder-p3""#,
        #""nemotron-stream-5""#,
        #""stub-1""#,
        #""\(gpuFamily):\(osBuild):\(version)""#,
        #"":\(revision)""#,
        #"":components=\(components)""#,
        #"":recipe=exact""#,
        #"manifestName = "vella-derived.json""#
    ]

    func testGoldenGateStringsAppearExactlyOnce() throws {
        let sources = try workerSources()
        XCTAssertFalse(sources.isEmpty)
        for literal in Self.golden {
            XCTAssertEqual(occurrences(literal, in: sources), 1, literal)
        }
    }
}

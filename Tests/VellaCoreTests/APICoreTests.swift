import XCTest
@testable import VellaCore

final class APICoreTests: XCTestCase {
    private func head(_ text: String) -> HTTPHead { HTTPHead.parse(Data(text.utf8))! }
    private let port = 5555

    func testWordTimestampsRefuseWithAnActionable400ForFormAndJSON() throws {
        for fields in [["timestamp_granularities[]": ["word"], "response_format": ["verbose_json"]], ["timestamp_granularities": ["word"], "response_format": ["verbose_json"]]] {
            XCTAssertThrowsError(try TranscriptionOptions.validate(fields)) { error in
                let api = error as? APIError
                XCTAssertEqual(api?.status, 400); XCTAssertTrue(api?.message.contains("Word timestamps are not supported") == true)
                XCTAssertTrue(api?.message.contains("segment") == true)
            }
        }
        let json = Data(#"{"path":"/fixture.wav","timestamp_granularities":["word"],"response_format":"verbose_json"}"#.utf8)
        XCTAssertThrowsError(try TranscriptionOptions.validate(json: json))
    }

    func testHeadParsingRecordsDuplicatesAndRejectsGarbage() {
        let h = head("POST /v1/audio/transcriptions?x=1 HTTP/1.1\r\nHost: 127.0.0.1:5555\r\nContent-Type: a\r\ncontent-type: b")
        XCTAssertEqual(h.method, "POST"); XCTAssertEqual(h.path, "/v1/audio/transcriptions")
        XCTAssertEqual(h.duplicates, ["content-type"])
        XCTAssertNil(HTTPHead.parse(Data("GET / HTTP/1.1 extra".utf8)))
        XCTAssertNil(HTTPHead.parse(Data("GET nopath HTTP/1.1".utf8)))
        XCTAssertNil(HTTPHead.parse(Data("GET / HTTP/1.1\r\nno colon here".utf8)))
    }

    func testSecurityRefusalsComeFromTheHeadAlone() {
        let ok = "Host: 127.0.0.1:5555\r\nContent-Length: 10\r\nContent-Type: multipart/form-data; boundary=x"
        func refusal(_ line: String, _ headers: String) -> Int? { APIRequestCheck.refusal(head(line + "\r\n" + headers), port: port)?.status }
        let post = "POST /v1/audio/transcriptions HTTP/1.1"
        XCTAssertNil(refusal(post, ok))
        XCTAssertNil(refusal(post, ok + "\r\nAuthorization: Bearer sk-anything")) // SDK keys are accepted and ignored
        XCTAssertNil(refusal(post, ok.replacingOccurrences(of: "127.0.0.1", with: "localhost")))
        XCTAssertEqual(refusal(post, ok + "\r\nOrigin: https://evil.example"), 403)
        XCTAssertEqual(refusal(post, ok + "\r\nOrigin: null"), 403)
        XCTAssertEqual(refusal(post, ok.replacingOccurrences(of: "127.0.0.1:5555", with: "evil.example:5555")), 403)
        XCTAssertEqual(refusal(post, ok.replacingOccurrences(of: "5555", with: "80")), 403)
        XCTAssertEqual(refusal(post, "Content-Length: 1\r\nContent-Type: application/json"), 403) // no Host
        XCTAssertEqual(refusal(post, ok + "\r\nHost: 127.0.0.1:5555"), 403) // repeated Host
        XCTAssertEqual(refusal(post, ok + "\r\nContent-Type: application/json"), 400) // repeated Content-Type
        XCTAssertEqual(refusal(post, ok + "\r\nContent-Length: 10"), 400)
        XCTAssertEqual(refusal(post, "Host: 127.0.0.1:5555\r\nContent-Length: 3\r\nContent-Type: text/plain"), 415)
        XCTAssertEqual(refusal(post, "Host: 127.0.0.1:5555\r\nContent-Length: 3\r\nContent-Type: application/x-www-form-urlencoded"), 415)
        XCTAssertEqual(refusal(post, "Host: 127.0.0.1:5555\r\nContent-Length: 3"), 415)
        XCTAssertEqual(refusal(post, "Host: 127.0.0.1:5555\r\nContent-Length: 3\r\nContent-Type: multipart/form-data"), 400) // no boundary
        XCTAssertEqual(refusal(post, "Host: 127.0.0.1:5555\r\nContent-Type: multipart/form-data; boundary=x"), 411)
        XCTAssertEqual(refusal(post, ok + "\r\nTransfer-Encoding: chunked"), 411)
        XCTAssertEqual(refusal(post, "Host: 127.0.0.1:5555\r\nContent-Length: -1\r\nContent-Type: application/json"), 400)
        XCTAssertEqual(refusal(post, "Host: 127.0.0.1:5555\r\nContent-Length: \(apiMaxBodyBytes + 1)\r\nContent-Type: multipart/form-data; boundary=x"), 413)
        XCTAssertEqual(refusal(post, "Host: 127.0.0.1:5555\r\nContent-Length: \(apiMaxJSONBytes + 1)\r\nContent-Type: application/json"), 413)
        XCTAssertEqual(refusal("GET /v1/audio/transcriptions HTTP/1.1", "Host: 127.0.0.1:5555"), 405)
        XCTAssertEqual(refusal("POST /status HTTP/1.1", ok), 405)
        XCTAssertEqual(refusal("GET /status HTTP/1.1", "Host: 127.0.0.1:5555\r\nContent-Length: 5"), 400)
        XCTAssertEqual(refusal("GET /v1/nothing HTTP/1.1", "Host: 127.0.0.1:5555"), 404)
        XCTAssertEqual(refusal("POST /v1/audio/translations HTTP/1.1", ok), 404)
        XCTAssertNil(refusal("GET /v1/models HTTP/1.1", "Host: localhost:5555"))
        XCTAssertNil(refusal("GET /v1/models/parakeet-v3 HTTP/1.1", "Host: localhost:5555"))
        XCTAssertEqual(APIRoute.match("/v1/models/parakeet%2Dv3"), .model("parakeet-v3"))
    }

    func testMultipartParsing() throws {
        let boundary = "----b0und4ry"
        var body = Data("preamble\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n".utf8)
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a \\\"b\\\";c.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        let audio = Data([0, 1, 2, 13, 10, 45, 45, 255]) // contains CRLF and dashes
        body += audio + Data("\r\n--\(boundary)--\r\n".utf8)
        let parts = try Multipart.parse(body, boundary: boundary)
        XCTAssertEqual(parts.map(\.name), ["model", "file"])
        XCTAssertEqual(String(data: body.subdata(in: parts[0].range), encoding: .utf8), "whisper-1")
        XCTAssertEqual(parts[1].filename, "a \"b\";c.wav")
        XCTAssertEqual(parts[1].contentType, "audio/wav")
        XCTAssertEqual(body.subdata(in: parts[1].range), audio)
        XCTAssertEqual(Multipart.boundary("multipart/form-data; boundary=\"quoted b\""), "quoted b")
        XCTAssertNil(Multipart.boundary("multipart/form-data"))
        // Malformed: no closing delimiter, no blank line, no name.
        XCTAssertThrowsError(try Multipart.parse(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nvalue".utf8), boundary: boundary))
        XCTAssertThrowsError(try Multipart.parse(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"a\"\r\n".utf8), boundary: boundary))
        XCTAssertThrowsError(try Multipart.parse(Data("--\(boundary)\r\nContent-Type: x\r\n\r\nv\r\n--\(boundary)--".utf8), boundary: boundary))
        XCTAssertThrowsError(try Multipart.parse(Data("nothing".utf8), boundary: boundary))
    }

    func testTranscriptionOptionsValidation() throws {
        let o = try TranscriptionOptions.validate([
            "model": ["parakeet-v3"], "response_format": ["verbose_json"], "language": ["PL"],
            "temperature": ["0.2"], "timestamp_granularities[]": ["segment"], "include[]": ["logprobs"]
        ])
        XCTAssertEqual(o.model, "parakeet-v3"); XCTAssertEqual(o.format, .verbose_json); XCTAssertEqual(o.language, "pl")
        XCTAssertEqual(o.granularities, ["segment"])
        XCTAssertEqual(try TranscriptionOptions.validate([:]), TranscriptionOptions())
        func param(_ fields: [String: [String]]) -> String? {
            do { _ = try TranscriptionOptions.validate(fields); return "accepted" } catch let e as APIError { return e.param } catch { return "other" }
        }
        XCTAssertEqual(param(["response_format": ["mp3"]]), "response_format")
        XCTAssertEqual(param(["temperature": ["2"]]), "temperature")
        XCTAssertEqual(param(["temperature": ["hot"]]), "temperature")
        XCTAssertEqual(param(["language": ["en; rm -rf"]]), "language")
        XCTAssertEqual(param(["model": ["a", "b"]]), "model")
        XCTAssertEqual(param(["timestamp_granularities[]": ["char"], "response_format": ["verbose_json"]]), "timestamp_granularities")
        XCTAssertEqual(param(["timestamp_granularities[]": ["segment"]]), "timestamp_granularities") // needs verbose_json
        XCTAssertEqual(param(["stream": ["true"]]), "stream")
        let json = try TranscriptionOptions.validate(json: Data(#"{"path":"/tmp/a.wav","response_format":"srt","temperature":0,"model":null}"#.utf8))
        XCTAssertEqual(json.path, "/tmp/a.wav"); XCTAssertEqual(json.options.format, .srt)
        XCTAssertThrowsError(try TranscriptionOptions.validate(json: Data(#"{"path":"relative.wav"}"#.utf8)))
        XCTAssertThrowsError(try TranscriptionOptions.validate(json: Data(#"[1]"#.utf8)))
        XCTAssertThrowsError(try TranscriptionOptions.validate(json: Data(#"{"path":"/a","model":{"x":1}}"#.utf8)))
    }

    /// Agent friction, 8 Nov: `language` and `prompt` were accepted and silently ignored, and there was no
    /// per-request vocabulary switch. Each now reaches the model or is refused with a 400 that says why.
    func testRequestSettingsReachTheModelOrAreRefused() throws {
        let off = try TranscriptionOptions.validate(["vocabulary": ["false"], "language": ["tr"], "prompt": ["Istanbul police radio"]])
        XCTAssertFalse(off.vocabulary)
        XCTAssertEqual(off.workerOptions as NSDictionary?, ["language": "tr", "prompt": "Istanbul police radio", "vocabulary": false] as NSDictionary)
        XCTAssertNil(TranscriptionOptions().workerOptions, "a default request sends no options")
        XCTAssertNil(try TranscriptionOptions.validate(["prompt": ["  "]]).workerOptions)
        XCTAssertEqual(try TranscriptionOptions.validate(json: Data(#"{"path":"/a.wav","vocabulary":false}"#.utf8)).options.vocabulary, false)
        XCTAssertThrowsError(try TranscriptionOptions.validate(["vocabulary": ["maybe"]])) { XCTAssertEqual(($0 as? APIError)?.param, "vocabulary") }

        func refusal(_ options: TranscriptionOptions, _ family: String, languages: [String] = ["en", "tr"]) -> APIError? {
            do { try TranscriptionControls.check(options, familyID: family, name: family, languages: languages); return nil } catch { return error as? APIError }
        }
        let turkish = TranscriptionOptions(language: "tr")
        let prompted = TranscriptionOptions(prompt: "Names: Vella.")
        XCTAssertNil(refusal(turkish, "nemotron-3.5-transcribe"))
        XCTAssertNil(refusal(prompted, "nemotron-3.5-transcribe"))
        XCTAssertNil(refusal(turkish, "whisper-large-v3-turbo"))
        XCTAssertNil(refusal(turkish, "qwen3-asr-1.7b"))
        let parakeet = try XCTUnwrap(refusal(turkish, "parakeet-v3-ultra"))
        XCTAssertEqual(parakeet.status, 400); XCTAssertEqual(parakeet.param, "language"); XCTAssertEqual(parakeet.code, "unsupported_parameter")
        XCTAssertTrue(parakeet.message.contains("detects the language itself"))
        XCTAssertEqual(refusal(prompted, "whisper-large-v3")?.param, "prompt")
        XCTAssertEqual(refusal(prompted, "parakeet-v3")?.param, "prompt")
        XCTAssertEqual(refusal(TranscriptionOptions(language: "xx"), "nemotron-3.5-transcribe")?.code, "unsupported_language")
        XCTAssertNil(refusal(TranscriptionOptions(language: "pt-br"), "qwen3-asr-1.7b", languages: ["pt"]))
        // Vocabulary off is harmless everywhere; lab and test families pass through to their helper.
        XCTAssertNil(refusal(TranscriptionOptions(vocabulary: false), "parakeet-v3-ultra"))
        XCTAssertNil(refusal(TranscriptionOptions(language: "en", prompt: "x"), "fake-b", languages: []))
    }

    /// The echo of what reached the model, and a loop reported as a warning instead of a clean success (friction 2, 9).
    func testAppliedSettingsAreEchoedAndLoopsWarned() throws {
        var applied = AppliedSettings()
        applied.add(["language": "tr", "prompt": "Audio transcription. Language: Turkish.", "vocabulary": false, "vocabulary_words": 0, "loops": 0])
        applied.add(["language": "tr", "prompt": "later", "vocabulary": false, "vocabulary_words": 0, "loops": 1, "vocabulary_dropped": 2])
        XCTAssertEqual(applied.language, "tr"); XCTAssertEqual(applied.prompt, "Audio transcription. Language: Turkish.")
        XCTAssertEqual(applied.loops, 1); XCTAssertEqual(applied.vocabularyDropped, 2); XCTAssertFalse(applied.vocabulary)
        XCTAssertEqual(applied.warnings.count, 1)
        let verbose = TranscriptFormatter.render(
            .verbose_json, text: "Merhaba.", segments: [], duration: 3, language: "tr", model: "nemotron-3.5-transcribe 4b Optimized Fast", applied: applied)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: verbose.body) as? [String: Any])
        let vella = try XCTUnwrap(object["vella"] as? [String: Any])
        XCTAssertEqual(vella["language_applied"] as? String, "tr")
        XCTAssertEqual(vella["prompt"] as? String, "Audio transcription. Language: Turkish.")
        XCTAssertEqual(vella["model"] as? String, "nemotron-3.5-transcribe 4b Optimized Fast")
        XCTAssertEqual(vella["loops"] as? Int, 1)
        XCTAssertEqual((object["warnings"] as? [String])?.count, 1)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: TranscriptFormatter.render(.json, text: "x", segments: [], duration: 1, language: nil, applied: applied).body) as? [String: Any])
        XCTAssertNotNil(json["warnings"])
        // A clean transcript keeps OpenAI's plain json shape.
        let clean = try XCTUnwrap(
            JSONSerialization.jsonObject(with: TranscriptFormatter.render(.json, text: "x", segments: [], duration: 1, language: nil, applied: AppliedSettings()).body)
                as? [String: Any])
        XCTAssertEqual(Set(clean.keys), ["text", "usage"])
    }

    func testFormats() throws {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 5.25, text: "Hello there."),
            TranscriptSegment(id: 1, start: 5.25, end: 3725.5, text: "Second.")
        ]
        let text = "Hello there. Second."
        let json = TranscriptFormatter.render(.json, text: text, segments: segments, duration: 3725.5, language: nil)
        XCTAssertEqual(json.contentType, "application/json")
        XCTAssertEqual(String(decoding: json.body, as: UTF8.self), #"{"text":"Hello there. Second.","usage":{"seconds":3726,"type":"duration"}}"#)
        let srt = String(decoding: TranscriptFormatter.render(.srt, text: text, segments: segments, duration: 3725.5, language: nil).body, as: UTF8.self)
        XCTAssertEqual(srt, "1\n00:00:00,000 --> 00:00:05,250\nHello there.\n\n2\n00:00:05,250 --> 01:02:05,500\nSecond.\n")
        let vtt = String(decoding: TranscriptFormatter.render(.vtt, text: text, segments: segments, duration: 3725.5, language: nil).body, as: UTF8.self)
        XCTAssertEqual(vtt, "WEBVTT\n\n00:00:00.000 --> 00:00:05.250\nHello there.\n\n00:00:05.250 --> 01:02:05.500\nSecond.\n")
        XCTAssertEqual(String(decoding: TranscriptFormatter.render(.text, text: text, segments: segments, duration: 1, language: nil).body, as: UTF8.self), text + "\n")
        let verbose =
            try JSONSerialization.jsonObject(with: TranscriptFormatter.render(.verbose_json, text: text, segments: segments, duration: 3725.5, language: "en").body)
            as! [String: Any]
        XCTAssertEqual(verbose["language"] as? String, "en"); XCTAssertEqual(verbose["task"] as? String, "transcribe")
        XCTAssertEqual((verbose["segments"] as? [[String: Any]])?.last?["end"] as? Double, 3725.5)
        XCTAssertEqual(
            APIError(404, "x", code: "model_not_found").json as NSDictionary,
            ["error": ["message": "x", "type": "invalid_request_error", "param": NSNull(), "code": "model_not_found"]] as NSDictionary)
    }
}

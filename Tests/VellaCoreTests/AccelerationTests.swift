import XCTest
@testable import VellaCore

/// The recommended precision per Mac and the warning triangles (Toby, 15 Oct: "the recommended option would be always the
/// smallest one that has the best accelerator ... if the quality is okay"), derived from what the GPU reports, never
/// from a chip-name table, over the shipped catalog and benchmarks.
final class AccelerationTests: XCTestCase {
    private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")
    private func shipped() throws -> (ModelCatalog, BenchmarkFile) {
        (try decodeCatalog(Data(contentsOf: resources.appendingPathComponent("models.json"))),
         decodeBenchmarks(try Data(contentsOf: resources.appendingPathComponent("benchmarks.json"))))
    }

    /// Capability profiles by what Metal reports: M1/M2 class (Apple 7/8), M3/M4 class (Apple 9, no tensor units), M5
    /// class (Apple 10, tensor units on macOS 26.2+). A hypothetical later generation is judged by the same rule.
    static let m1 = GPUCapability(appleFamily: 7, architecture: "applegpu_g13g", osMajor: 26, osMinor: 6)
    static let m2 = GPUCapability(appleFamily: 8, architecture: "applegpu_g14s", osMajor: 26, osMinor: 6)
    static let m3 = GPUCapability(appleFamily: 9, architecture: "applegpu_g15c", osMajor: 26, osMinor: 6)
    static let m4 = GPUCapability(appleFamily: 9, architecture: "applegpu_g16s", osMajor: 27, osMinor: 0)
    static let m5 = GPUCapability(appleFamily: 10, architecture: "applegpu_g17s", osMajor: 26, osMinor: 6)
    static let future = GPUCapability(appleFamily: 11, architecture: "applegpu_g18d", osMajor: 27, osMinor: 1)

    func testTensorUnitsFollowMLXsRule() {
        // The same rule as MLX's is_nax_available and the worker's SmallMGEMM.tensorOpsAvailable.
        for (gpu, expected) in [(Self.m1, false), (Self.m2, false), (Self.m3, false), (Self.m4, false), (Self.m5, true), (Self.future, true)] {
            XCTAssertEqual(gpu.tensorOps, expected, gpu.architecture)
        }
        XCTAssertFalse(GPUCapability.tensorOpsAvailable(architecture: "applegpu_g17s", osMajor: 26, osMinor: 1), "macOS 26.2 is the floor")
        XCTAssertTrue(GPUCapability.tensorOpsAvailable(architecture: "applegpu_g17s", osMajor: 26, osMinor: 2))
        XCTAssertFalse(GPUCapability.tensorOpsAvailable(architecture: "applegpu_g17p", osMajor: 27, osMinor: 0), "phones need generation 18")
        XCTAssertTrue(GPUCapability.tensorOpsAvailable(architecture: "applegpu_g18p", osMajor: 27, osMinor: 0))
        XCTAssertFalse(GPUCapability.tensorOpsAvailable(architecture: "", osMajor: 27, osMinor: 0))
        XCTAssertFalse(GPUCapability.tensorOpsAvailable(architecture: "amd", osMajor: 27, osMinor: 0))
        // This Mac, read from Metal: whatever it is, the rule is the same.
        let here = GPUCapability.current
        XCTAssertEqual(here.tensorOps, GPUCapability.tensorOpsAvailable(architecture: here.architecture, osMajor: here.osMajor, osMinor: here.osMinor))
    }

    func testEveryCatalogFamilyIsClassified() throws {
        let (catalog, _) = try shipped()
        for family in catalog.families { XCTAssertNotNil(quantizedActivations[family.id], "\(family.id): how its quantized layers feed MLX") }
        // An unknown family is never over-claimed: without a tensor component its int8 is software even on an M5.
        var unknown = try XCTUnwrap(catalog.family("qwen3-asr-0.6b")); unknown.id = "someday-new-model"
        XCTAssertFalse(runsOnMatrixHardware(unknown, tier: .t8, cell: nil, gpu: Self.m5))
        XCTAssertTrue(runsOnMatrixHardware(unknown, tier: .t16, cell: nil, gpu: Self.m1), "16-bit runs on every Apple GPU's matrix path")
    }

    /// family id → (recommended tier, tiers with a triangle) in one switch position.
    private func advice(_ gpu: GPUCapability, measuredHere: Bool = false, mode: OptimizedMode = .fast) throws -> [String: (ModelTier?, Set<ModelTier>)] {
        let (catalog, file) = try shipped()
        var out: [String: (ModelTier?, Set<ModelTier>)] = [:]
        for family in catalog.families {
            let rules = SelectionRules(family: family, benchmark: file.models[family.id])
            let position: OptimizedMode = rules.switchAvailable ? mode : .fast
            let a = precisionAdvice(
                family, file.models[family.id], mode: position, tiers: rules.precisions(position).filter { rules.measured(ModelSelection(tier: $0, mode: position)) },
                gpu: gpu, measuredHere: measuredHere)
            out[family.id] = (a.recommended, Set(a.software.keys))
            XCTAssertNotNil(a.recommendedHelp, family.id)
            XCTAssertNil(a.software[.t16], "\(family.id): 16-bit always has hardware support")
            if let pick = a.recommended, pick != .t16 { XCTAssertNil(a.software[pick], "\(family.id): never recommend a triangled cell") }
        }
        return out
    }

    /// M1/M2 class and M3/M4 class: no integer matrix hardware, so int8 and int4 carry the triangle on every model and
    /// 16-bit is recommended everywhere.
    func testWithoutTensorUnitsEveryQuantizedCellIsSoftwareAnd16IsRecommended() throws {
        for gpu in [Self.m1, Self.m2, Self.m3, Self.m4] {
            for mode in OptimizedMode.allCases {
                for (id, (recommended, software)) in try advice(gpu, mode: mode) {
                    XCTAssertEqual(recommended, .t16, "\(gpu.architecture) \(id) \(mode)")
                    XCTAssertEqual(software, [.t8, .t4], "\(gpu.architecture) \(id) \(mode)")
                }
            }
        }
        let (catalog, file) = try shipped()
        let parakeet = try XCTUnwrap(catalog.family("parakeet-v3"))
        let a = precisionAdvice(parakeet, file.models[parakeet.id], mode: .fast, tiers: [.t16, .t8, .t4], gpu: Self.m4, measuredHere: false)
        XCTAssertEqual(a.software[.t8], "No hardware support for int8 on this Mac: saves memory, may be slower than bf16")
        XCTAssertEqual(a.recommendedHelp, "Recommended for this Mac: int8 has no hardware support here; int4 loses accuracy against bf16")
    }

    /// M5 class (derived, not the measured configuration): int8/int4 run on the tensor units wherever a path reaches them
    /// (Parakeet's native kernels in Fast, Nemotron's bf16 linears in Fast, MLX's quantized tensor kernel for Whisper and
    /// Qwen's 16-bit activations); the recommendation is the smallest of those that passes the quality gate.
    func testM5ClassRecommendsTheSmallestAcceleratedPrecisionThatKeepsQuality() throws {
        let fast = try advice(Self.m5)
        XCTAssertEqual(fast["parakeet-v3"]?.0, .t8, "int8 passes the gate and has the native kernel")
        XCTAssertEqual(fast["whisper-large-v3-turbo"]?.0, .t8, "int8 passes the gate; MLX's quantized tensor kernel takes fp16 activations")
        for id in ["parakeet-v3-ultra", "qwen3-asr-1.7b", "qwen3-asr-0.6b", "whisper-large-v3", "nemotron-3.5-streaming-0.6b"] {
            XCTAssertEqual(fast[id]?.0, .t16, "\(id): int8 and int4 fail the quality gate")
        }
        for (id, value) in fast { XCTAssertEqual(value.1, [], "\(id): every Fast cell reaches the tensor units on an M5") }
        // Exact drops Parakeet's native integer kernels and Nemotron's bf16 linears: float32 activations, no tensor path.
        let exact = try advice(Self.m5, mode: .exact)
        for id in ["parakeet-v3", "parakeet-v3-ultra", "nemotron-3.5-streaming-0.6b"] {
            XCTAssertEqual(exact[id]?.1, [.t8, .t4], "\(id) Exact: software int8/int4")
            XCTAssertEqual(exact[id]?.0, .t16, id)
        }
        XCTAssertEqual(exact["whisper-large-v3-turbo"]?.1, [], "Whisper's Exact = Fast recipe keeps its tensor path")
        XCTAssertEqual(Self.future.tensorOps, true)
        XCTAssertEqual(try advice(Self.future)["parakeet-v3"]?.0, .t8, "a later GPU generation is judged by what it reports")
    }

    /// On the measured M5 Max a measurement overrides the derivation: a cell measured faster than the 16-bit cell of the
    /// same switch position carries no triangle (Nemotron Exact int8/int4); one measured slower says so.
    func testOnTheMeasuredMacTheMeasurementWins() throws {
        let derived = try advice(Self.m5, mode: .exact)
        let measured = try advice(Self.m5, measuredHere: true, mode: .exact)
        XCTAssertEqual(derived["nemotron-3.5-streaming-0.6b"]?.1, [.t8, .t4], "derived: float32 Exact has no tensor path")
        XCTAssertEqual(measured["nemotron-3.5-streaming-0.6b"]?.1, [], "measured faster than bf16 on the M5 Max: no triangle")
        XCTAssertEqual(measured["parakeet-v3"]?.1, [.t8, .t4], "measured slower than bf16: the triangle stays")
        XCTAssertEqual(try advice(Self.m5, measuredHere: true)["parakeet-v3"]?.0, .t8)
        XCTAssertEqual(try advice(Self.m5, measuredHere: true)["whisper-large-v3-turbo"]?.0, .t8)
        let (catalog, file) = try shipped()
        let parakeet = try XCTUnwrap(catalog.family("parakeet-v3"))
        let a = precisionAdvice(parakeet, file.models[parakeet.id], mode: .exact, tiers: [.t16, .t8, .t4], gpu: Self.m5, measuredHere: true)
        XCTAssertEqual(a.software[.t8], "Exact runs int8 without the matrix hardware on this Mac: saves memory, measured slower than bf16 here")
        let nemotron = try XCTUnwrap(catalog.family("nemotron-3.5-streaming-0.6b"))
        let n = precisionAdvice(nemotron, file.models[nemotron.id], mode: .exact, tiers: [.t16, .t8, .t4], gpu: Self.m5, measuredHere: true)
        XCTAssertEqual(n.measuredOverride, [.t8, .t4])
        let fast = precisionAdvice(parakeet, file.models[parakeet.id], mode: .fast, tiers: [.t16, .t8, .t4], gpu: Self.m5, measuredHere: true)
        XCTAssertEqual(fast.recommendedHelp, "Recommended for this Mac: int8 keeps bf16 accuracy, uses less memory and runs on this Mac's matrix hardware")
    }

    /// The quality gate: a tier whose gate or any cell's presence check failed is never recommended, wherever it runs.
    func testQualityGateIsTheTiersGate() throws {
        let (_, file) = try shipped()
        let parakeet = try XCTUnwrap(file.models["parakeet-v3"])
        let cell8 = benchmarkCell(parakeet, ModelSelection(tier: .t8, mode: .fast))
        let cell4 = benchmarkCell(parakeet, ModelSelection(tier: .t4, mode: .fast))
        XCTAssertTrue(keepsQuality(parakeet, tier: .t8, cell: cell8))
        XCTAssertFalse(keepsQuality(parakeet, tier: .t4, cell: cell4), "int4's loss stays visible and is never recommended")
        XCTAssertTrue(keepsQuality(parakeet, tier: .t16, cell: nil))
        var pending = cell8; pending?.measured = nil
        XCTAssertFalse(keepsQuality(parakeet, tier: .t8, cell: pending), "an unmeasured cell is never recommended")
        XCTAssertEqual(precisionAdvice(try shipped().0.family("parakeet-v3")!, nil, mode: .fast, tiers: [.t16], gpu: Self.m5, measuredHere: true), PrecisionAdvice())
    }
}

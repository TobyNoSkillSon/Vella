import Foundation

/// Opt-in lever of the fast TDT decoder (spread round, 30 Sep 2026; lab/models/Parakeet/L3-RESULTS.md). Exact: a block
/// boundary only splits the same sequence of steps, so it stays inside the token-exact `decoder` component. The switch
/// is part of the gate key and appends its own revision when set; unset, the decoder, its kernels and every gate key
/// are unchanged.
enum FastParakeetDecodeOptions {
    /// `VELLA_PARAKEET_TAILBLOCK=1`: size each compiled block (8, 16 or 32 steps) to the decisions a segment's
    /// remaining frames need, instead of always 32. Every block runs all its steps (steps past the input are no-ops
    /// that still dispatch their kernels), and app segments need only ~15–95 decisions, so a fixed 32 wastes up
    /// to half the last block. Exact: a block boundary only splits the same sequence of steps.
    static let tailBlocks = ProcessInfo.processInfo.environment["VELLA_PARAKEET_TAILBLOCK"] == "1"
    /// Steps for the next block: the smallest of 8/16/32 that covers the expected decisions. Smoke-set segments took
    /// 0.33–0.63 decisions (active steps) per encoder frame, mean ~0.5; a short estimate costs one more block and host
    /// sync, a long one wasted steps.
    static func blockSteps(remainingFrames: Int) -> Int {
        let expected = Int((Double(max(remainingFrames, 0)) * decisionsPerFrame).rounded(.up))
        return expected <= 8 ? 8 : expected <= 16 ? 16 : 32
    }
    static let decisionsPerFrame = 0.5
    /// Appended to ParakeetModel.fastPathRevision only when the switch is set.
    static var revisionSuffix: String { tailBlocks ? "+tailblock-1" : "" }
}

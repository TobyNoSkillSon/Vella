/// What a helper runs for a model (`VELLA_RECIPE`), and the benchmarks.json cell of a selection:
/// `standard` = stock MLX; `optimized_exact` = only the components whose output equals stock's; `optimized_fast` = those
/// plus the gate-passing inexact ones (also the default when unset).
public enum Recipe: String, Codable, CaseIterable, Sendable {
    case standard, optimized_exact, optimized_fast
    /// The environment variable the app sets for every helper it launches.
    public static let variable = "VELLA_RECIPE"
}

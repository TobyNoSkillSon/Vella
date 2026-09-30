/// What a loaded model actually runs, as the worker status reports it: `optimized` (self-tested optimized components
/// active) or `mlx` (the stock path).
public enum Engine: String, Codable, CaseIterable, Sendable {
    case optimized, mlx
}

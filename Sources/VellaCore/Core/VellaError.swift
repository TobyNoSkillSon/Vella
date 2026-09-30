import Foundation

public enum VellaError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .message(let s): return s
        }
    }
}

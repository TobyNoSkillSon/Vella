import Foundation

/// An error in OpenAI's envelope: `{"error": {"message", "type", "param", "code"}}` with the HTTP status beside it.
public struct APIError: Error, Equatable {
    public var status: Int
    public var message: String
    public var type: String
    public var param: String?
    public var code: String?
    public init(_ status: Int, _ message: String, type: String? = nil, param: String? = nil, code: String? = nil) {
        self.status = status; self.message = message; self.param = param; self.code = code
        self.type =
            type
            ?? {
                switch status {
                case 403: return "permission_error"
                case 404: return code == "model_not_found" ? "invalid_request_error" : "not_found_error"
                case 429: return "rate_limit_error"
                case 500...: return "server_error"
                default: return "invalid_request_error"
                }
            }()
    }
    public var json: [String: Any] {
        ["error": ["message": message, "type": type, "param": param as Any? ?? NSNull(), "code": code as Any? ?? NSNull()]]
    }
}

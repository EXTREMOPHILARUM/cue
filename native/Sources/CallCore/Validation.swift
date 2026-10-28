import Foundation

public struct BridgeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Validation {
    public static func identifier(_ value: Any?) throws -> String {
        guard let s = value as? String, s.range(of: "^[a-zA-Z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw BridgeError("Invalid session identifier") }
        return s
    }
    public static func text(_ value: Any?, limit: Int = 20_000) throws -> String {
        guard let s = value as? String, s.utf8.count <= limit else { throw BridgeError("Invalid or oversized text") }
        return s
    }
    public static func originAllowed(_ origin: String?, extensionID: String) -> Bool {
        guard let origin else { return true }
        return extensionID.range(of: "^[a-p]{32}$", options: .regularExpression) != nil && origin == "chrome-extension://\(extensionID)"
    }
    public static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

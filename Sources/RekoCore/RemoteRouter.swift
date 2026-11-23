import Foundation

/// What the phone remote asked for. Commands are raw strings so this module stays UI-agnostic.
public enum RemoteRoute: Equatable, Sendable {
    case page
    case state
    case command(String)
    case cue(Int)
    case badRequest
    case forbidden
    case notFound
}

/// Turns a raw HTTP request into a route. Pure, so the security-relevant parsing is unit-tested.
public enum RemoteRouter {
    public static func route(_ raw: Data, token: String) -> RemoteRoute {
        let requestLine = String(decoding: raw.prefix(while: { $0 != 0x0D && $0 != 0x0A }), as: UTF8.self)
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[1].hasPrefix("/"), let components = URLComponents(string: String(parts[1])) else {
            return .badRequest
        }
        let supplied = components.queryItems?.first { $0.name == "t" }?.value ?? ""
        guard constantTimeEquals(supplied, token) else { return .forbidden }

        let method = parts[0]
        let path = components.path
        switch method {
        case "GET" where path == "/": return .page
        case "GET" where path == "/api/state": return .state
        case "POST" where path.hasPrefix("/api/cmd/"):
            let name = String(path.dropFirst("/api/cmd/".count))
            return name.isEmpty || name.contains("/") ? .notFound : .command(name)
        case "POST" where path.hasPrefix("/api/cue/"):
            return Int(path.dropFirst("/api/cue/".count)).map { $0 >= 0 ? .cue($0) : .notFound } ?? .notFound
        default: return .notFound
        }
    }

    /// Comparison time doesn't depend on where the strings differ.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0))
        }
        return diff == 0 && !y.isEmpty
    }
}

import Foundation

enum ProviderError: LocalizedError {
    case response(Int), invalidData(String)
    var errorDescription: String? {
        switch self {
        case .response(401), .response(403): return "This provider is not allowing access to this data. Replay remains available."
        case .response(429): return "The data provider is busy. Please try again shortly."
        case .response(let code): return "The data provider returned HTTP \(code)."
        case .invalidData(let message): return message
        }
    }
}

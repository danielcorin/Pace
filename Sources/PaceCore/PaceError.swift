import Foundation

public enum PaceError: LocalizedError, Equatable {
    case vaultLocked
    case invalidArgument(String)
    case notFound(String)
    case unavailable(String)
    case corruptStore
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "Pace is locked. Unlock it before accessing history."
        case .invalidArgument(let message),
             .notFound(let message),
             .unavailable(let message),
             .authenticationFailed(let message):
            return message
        case .corruptStore:
            return "The encrypted Pace history could not be decoded."
        }
    }

    public var code: String {
        switch self {
        case .vaultLocked: return "vault_locked"
        case .invalidArgument: return "invalid_argument"
        case .notFound: return "not_found"
        case .unavailable: return "unavailable"
        case .corruptStore: return "corrupt_store"
        case .authenticationFailed: return "authentication_failed"
        }
    }
}

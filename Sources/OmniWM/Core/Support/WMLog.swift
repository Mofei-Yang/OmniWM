import Foundation
import OSLog

enum WMLogCategory: String {
    case engine
    case platform
    case layout
    case controller
    case kernel
    case ipc
    case ui
}

enum WMLogPrivacy {
    case `private`
    case `public`
}

enum WMLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "OmniWM"

    private static func logger(for category: WMLogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    static func debug(
        _ category: WMLogCategory,
        _ message: String,
        privacy: WMLogPrivacy = .private
    ) {
        switch privacy {
        case .private:
            logger(for: category).debug("\(message, privacy: .private)")
        default:
            logger(for: category).debug("\(message, privacy: .public)")
        }
    }

    static func info(
        _ category: WMLogCategory,
        _ message: String,
        privacy: WMLogPrivacy = .private
    ) {
        switch privacy {
        case .private:
            logger(for: category).info("\(message, privacy: .private)")
        default:
            logger(for: category).info("\(message, privacy: .public)")
        }
    }

    static func error(
        _ category: WMLogCategory,
        _ message: String,
        privacy: WMLogPrivacy = .private
    ) {
        switch privacy {
        case .private:
            logger(for: category).error("\(message, privacy: .private)")
        default:
            logger(for: category).error("\(message, privacy: .public)")
        }
    }
}

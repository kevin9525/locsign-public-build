import XKit
import DeveloperAPI

enum XKitProbe {
    static let reviewedCommit = "2af0b67447d30063235e2adb7bdc77012f431d3a"

    static func touch() -> String {
        [String(describing: DeveloperServicesLoginManager.self),
         String(describing: DeveloperAPIClient.self)].joined(separator: "/")
    }
}

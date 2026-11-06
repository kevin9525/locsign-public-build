import Foundation

actor ProvisioningOperation {
    private var current = UUID()

    func begin() -> UUID {
        current = UUID()
        return current
    }

    func isCurrent(_ operation: UUID) -> Bool {
        operation == current
    }

    func commit<T: Sendable>(_ operation: UUID, body: @Sendable () throws -> T) throws -> T {
        guard operation == current else { throw ProvisioningError.cancelled }
        try Task.checkCancellation()
        return try body()
    }

    func cancel() -> UUID {
        current = UUID()
        return current
    }
}

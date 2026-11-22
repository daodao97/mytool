import Foundation

/// Late WindowServer corrections must never override a newer operation or user input.
/// Event counters contain activity metadata only, without keyboard or mouse contents.
public struct RecoveryActivityGuard {
    private let generation: Int
    private let counters: [UInt32]

    public init(generation: Int, counters: [UInt32]) {
        self.generation = generation
        self.counters = counters
    }

    public func permitsRecovery(generation: Int, counters: [UInt32], isDragging: Bool) -> Bool {
        self.generation == generation && self.counters == counters && !isDragging
    }
}

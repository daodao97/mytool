import Foundation
import MyScreenCore

/// Keeps a drop alive through WindowServer's final move/resize after mouse-up.
/// The callbacks run on the same serial AX worker as the rest of WindowService.
final class ArrangementDropApplier {
    enum Result: Equatable { case applied, limited, failed, cancelled }
    private let queue: DispatchQueue
    private let verificationDelay: TimeInterval

    init(queue: DispatchQueue, verificationDelay: TimeInterval = 0.12) {
        self.queue = queue
        self.verificationDelay = verificationDelay
    }

    func apply(target: Rect, token: WindowOperationToken, isDragging: @escaping () -> Bool,
               readFrame: @escaping () -> Rect?, setFrame: @escaping (Rect) -> Int,
               recordUndo: @escaping () -> Void, completion: @escaping (Result) -> Void) {
        attempt(target: target, token: token, isDragging: isDragging, readFrame: readFrame,
                setFrame: setFrame, recordUndo: recordUndo, undoRecorded: false, index: 0, completion: completion)
    }

    private func attempt(target: Rect, token: WindowOperationToken, isDragging: @escaping () -> Bool,
                         readFrame: @escaping () -> Rect?, setFrame: @escaping (Rect) -> Int,
                         recordUndo: @escaping () -> Void, undoRecorded: Bool, index: Int,
                         completion: @escaping (Result) -> Void) {
        guard !token.isCancelled, !isDragging() else { completion(.cancelled); return }
        let outcome = setFrame(target)
        let appliedFrame = outcome >= 0 ? readFrame() : nil
        if outcome >= 0 && !undoRecorded { recordUndo() }
        let recorded = undoRecorded || outcome >= 0
        queue.asyncAfter(deadline: .now() + verificationDelay) {
            guard !token.isCancelled, !isDragging() else { completion(.cancelled); return }
            if let actual = readFrame() {
                if Self.matches(actual, target) {
                    if !recorded { recordUndo() }
                    completion(.applied); return
                }
                if outcome == 1, let appliedFrame, Self.matches(actual, appliedFrame) { completion(.limited); return }
            }
            guard index < 2 else { completion(.failed); return }
            self.attempt(target: target, token: token, isDragging: isDragging, readFrame: readFrame,
                         setFrame: setFrame, recordUndo: recordUndo, undoRecorded: recorded,
                         index: index + 1, completion: completion)
        }
    }

    private static func matches(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) < 3 && abs(a.y - b.y) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
}

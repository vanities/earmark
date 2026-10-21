import BackgroundTasks
import Foundation

/// The system-owned task cannot be instantiated. Keep its callback/completion boundary
/// injectable so the real transfer lifecycle can be exercised in simulator tests.
@MainActor
struct TransferBackgroundExecution {
    let id = UUID()
    let setExpirationHandler: ((@Sendable () -> Void)?) -> Void
    let complete: (Bool) -> Void

    static func live(_ task: BGProcessingTask) -> Self {
        Self(setExpirationHandler: { task.expirationHandler = $0 },
             complete: { task.setTaskCompleted(success: $0) })
    }
}

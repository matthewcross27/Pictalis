import Foundation

struct TimeoutError: Error {}

// Resumes a continuation at most once, from whichever of the work/timer tasks gets there first.
private final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    // Tasks to cancel once the outcome is decided (the timer, once the work finished).
    func track(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyDecided = continuation == nil
        if !alreadyDecided { tasks.append(task) }
        lock.unlock()
        if alreadyDecided { task.cancel() }
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let toCancel = tasks
        tasks = []
        lock.unlock()
        for task in toCancel { task.cancel() }
        pending?.resume(with: result)
    }
}

// Runs `operation`, throwing TimeoutError if it hasn't finished within `timeout`.
// Deliberately unstructured: a task group would wait for every child before returning,
// so an operation that ignores cancellation (PhotosPickerItem.loadTransferable can)
// would hang the caller exactly like the call it is meant to bound. On timeout the
// operation is cancelled and abandoned; whatever it eventually returns is discarded.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = OnceGate<T>(continuation)
        let work = Task {
            do {
                gate.resume(with: .success(try await operation()))
            } catch {
                gate.resume(with: .failure(error))
            }
        }
        gate.track(work)
        gate.track(Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            gate.resume(with: .failure(TimeoutError()))
        })
    }
}

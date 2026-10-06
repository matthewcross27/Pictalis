import Foundation

// Callers waiting for any one of a set of photos to materialize, each resumed with the
// first photo that does. PhotoPipeline owns one and drives it from its state transitions.
struct MaterializationWaiters {
    private struct Waiter {
        let token: UUID
        var ids: Set<UUID>
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var waiters: [Waiter] = []

    mutating func add(token: UUID, ids: Set<UUID>, continuation: CheckedContinuation<UUID, Error>) {
        waiters.append(Waiter(token: token, ids: ids, continuation: continuation))
    }

    mutating func resume(materialized id: UUID) {
        let ready = waiters.filter { $0.ids.contains(id) }
        waiters.removeAll { $0.ids.contains(id) }
        for waiter in ready { waiter.continuation.resume(returning: id) }
    }

    // A waiter only fails once every photo it was waiting on is unavailable.
    mutating func release(unavailable id: UUID) {
        for index in waiters.indices { waiters[index].ids.remove(id) }
        let stranded = waiters.filter { $0.ids.isEmpty }
        waiters.removeAll { $0.ids.isEmpty }
        for waiter in stranded { waiter.continuation.resume(throwing: PipelineError.photoUnavailable) }
    }

    mutating func expire(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: PipelineError.timedOut)
    }
}

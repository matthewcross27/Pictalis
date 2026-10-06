import Foundation

// Brings up the cull deck. Pulled out of CullView so the ordering that matters can be
// unit-tested: the first card must never wait on the sync service. Decisions are saved
// locally first and sent later, so a late (or stalled) sync start costs nothing - the
// service is already attached to the store, and its first drain sends whatever is pending.
@MainActor
enum CullBootstrap {

    // Loads saved decisions, kicks `startSync` off in the background, then returns as soon
    // as the provider has its first card (or has nothing to show). The returned task is the
    // sync start, which the caller may ignore or cancel.
    @discardableResult
    static func run(
        store: DecisionStore,
        sessionId: UUID,
        provider: LocalCardProvider,
        startSync: @escaping @MainActor () async -> Void
    ) async -> Task<Void, Never> {
        let decidedIds = await store.load(sessionId: sessionId)
        let syncTask = Task { await startSync() }
        await provider.start(excluding: decidedIds)
        return syncTask
    }
}

import SwiftUI

// What CullView's body should render, derived from cardProvider.state + currentCard.
// Pulled out as pure state so the .ready/currentCard==nil case (the provider has queued a card
// but the view has not taken it yet) has a defined, testable outcome instead of silently
// falling through to a blank frame.
enum CullDisplayState: Equatable {
    case loading
    case stalled
    case card
    case exhausted
}

// What the stall watchdog should do when it checks the screen.
enum CullWatchdogVerdict: Equatable {
    case resolved  // a card is showing, or the deck is finished
    case stalled   // photos are on disk but no card is showing
    case waiting   // nothing is on disk yet: still legitimately loading
}

struct CullView: View {
    @Environment(APIClient.self) private var api

    let sessionId: UUID
    var pipeline: PhotoPipeline
    var onComplete: () -> Void

    @State private var decisionStore  = DecisionStore()
    @State private var cardProvider: LocalCardProvider?
    @State private var syncService: SyncService?
    @State private var currentCard: LocalCardProvider.Card?
    @State private var dragOffset: CGFloat = 0
    @State private var isFinishing      = false
    @State private var finishFailed     = false
    @State private var isStalled        = false
    @State private var watchdogTask: Task<Void, Never>?
    @State private var expandedCard: LocalCardProvider.Card?
    @State private var screenWidth: CGFloat = 390

    // How long the deck may show no card, with photos already on disk, before it is
    // reported as stalled and the user is offered a retry.
    static let watchdogDelay: Duration = .seconds(5)
    private static let watchdogPollInterval: Duration = .seconds(1)

    private var dragProgress: CGFloat { dragOffset / (screenWidth * 0.4) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.filmWhite.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar

                    switch Self.displayState(for: cardProvider?.state, currentCard: currentCard, isStalled: isStalled) {
                    case .loading:
                        Spacer()
                        ProgressView().tint(Color.amber)
                        Spacer()

                    case .stalled:
                        Spacer()
                        CullStalledView(onRetry: retry)
                        Spacer()

                    case .card:
                        if let card = currentCard {
                            Spacer()
                            cardStack(card: card)
                            Spacer()
                            bottomButtons(card: card)
                        }

                    case .exhausted:
                        Color.clear
                    }
                }
            }
            .task { await initialize() }
            .fullScreenCover(item: $expandedCard) { card in
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: card.image)
                        .resizable()
                        .scaledToFit()
                }
                .onTapGesture { expandedCard = nil }
            }
            .onDisappear { watchdogTask?.cancel() }
            .onChange(of: cardProvider?.queue.isEmpty) { _, isEmpty in
                // The deck drives the screen: a card is shown as soon as the provider has one,
                // however far initialization has got.
                if isEmpty == false { showNextCardIfNeeded() }
            }
            .onChange(of: cardProvider?.state) { _, newState in
                if newState == .exhausted { onComplete() }
            }
            .onChange(of: geo.size.width) { _, newWidth in
                screenWidth = newWidth
            }
            .onAppear {
                screenWidth = geo.size.width
            }
        }
    }

    static func displayState(
        for queueState: CullQueueState?,
        currentCard: LocalCardProvider.Card?,
        isStalled: Bool = false
    ) -> CullDisplayState {
        switch queueState ?? .loading {
        case .exhausted:
            return .exhausted
        case .ready where currentCard != nil:
            return .card
        case .ready, .loading:
            return isStalled ? .stalled : .loading
        }
    }

    // Stalled means the deck has no card to show even though photos are already on disk -
    // waiting for photos that have not materialized yet is just loading, not a fault.
    static func watchdogVerdict(
        queueState: CullQueueState?,
        currentCard: LocalCardProvider.Card?,
        materializedCount: Int
    ) -> CullWatchdogVerdict {
        if currentCard != nil || queueState == .exhausted { return .resolved }
        return materializedCount > 0 ? .stalled : .waiting
    }

    // MARK: - Initialization

    private func initialize() async {
        let provider = LocalCardProvider(pipeline: pipeline)
        let sync = SyncService(
            sessionId: sessionId,
            api: api,
            registrationState: { pipeline.registrationState(for: $0) }
        )
        // Attach before anything can be decided so flush()/syncIfNeeded() always have the
        // store, however late the sync service's own start runs.
        sync.attach(store: decisionStore)
        cardProvider = provider
        syncService  = sync
        startWatchdog()

        // The first card never waits on the sync service.
        await CullBootstrap.run(
            store: decisionStore,
            sessionId: sessionId,
            provider: provider,
            startSync: { [decisionStore] in await sync.start(store: decisionStore) }
        )
        showNextCardIfNeeded()
    }

    private func showNextCardIfNeeded() {
        guard currentCard == nil, let provider = cardProvider, !provider.queue.isEmpty else { return }
        currentCard = provider.advance()
        if currentCard != nil { isStalled = false }
    }

    // MARK: - Stall watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { await runWatchdog() }
    }

    private func runWatchdog() async {
        try? await Task.sleep(for: Self.watchdogDelay)
        while !Task.isCancelled {
            switch Self.watchdogVerdict(
                queueState: cardProvider?.state,
                currentCard: currentCard,
                materializedCount: pipeline.materializedCount
            ) {
            case .resolved:
                return
            case .stalled:
                reportStall()
                return
            case .waiting:
                try? await Task.sleep(for: Self.watchdogPollInterval)
            }
        }
    }

    private func reportStall() {
        isStalled = true
        var context = cardProvider?.snapshot() ?? ["provider_state": "none"]
        context["has_current_card"] = String(currentCard != nil)
        context["materialized_count"] = String(pipeline.materializedCount)
        context["total_count"] = String(pipeline.totalCount)
        context["decisions_count"] = String(decisionStore.decisions.count)
        context["first_items"] = pipeline.itemStateSummary(first: 5).joined(separator: ", ")
        ErrorReporter.capture(
            message: "Cull deck stalled: no card shown with photos materialized",
            context: context
        )
    }

    // Rebuilds the deck from scratch. The decision store and sync service are kept: they
    // hold the user's choices and are not what is being retried.
    private func retry() {
        cardProvider?.stop()
        isStalled   = false
        currentCard = nil
        let provider = LocalCardProvider(pipeline: pipeline)
        cardProvider = provider
        startWatchdog()
        Task {
            await provider.start(excluding: decisionStore.allDecidedIds)
            showNextCardIfNeeded()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            if pipeline.totalCount > 0 {
                let remaining = max(0, pipeline.totalCount - decisionStore.decisions.count)
                Text("\(remaining) remaining")
                    .font(.captionSerif)
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer()
            Button(isFinishing ? "Finishing…" : "Done — start comparing") {
                guard !isFinishing else { return }
                isFinishing  = true
                finishFailed = false
                Task { await finish() }
            }
            .font(.labelSerif)
            .foregroundStyle(finishFailed ? Color.red : Color.amber)
            .disabled(isFinishing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Card stack

    @ViewBuilder
    private func cardStack(card: LocalCardProvider.Card) -> some View {
        GeometryReader { geo in
            ZStack {
                // Full-size backdrop so portrait photos don't read as a narrow strip,
                // while scaledToFit keeps the whole image visible (no crop, no
                // hit-test overflow blocking the top bar).
                RoundedRectangle(cornerRadius: .photoRadius)
                    .fill(Color.grainPaper)
                Image(uiImage: card.image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay {
                if dragOffset > 0 {
                    Color.green.opacity(min(dragProgress, 1.0) * 0.35)
                        .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
                } else if dragOffset < 0 {
                    Color.red.opacity(min(-dragProgress, 1.0) * 0.35)
                        .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
                }
            }
            .overlay(alignment: .topTrailing) {
                ExpandPhotoButton { expandedCard = card }
            }
            .offset(x: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in dragOffset = value.translation.width }
                    .onEnded { value in
                        let threshold = geo.size.width * 0.4
                        if value.translation.width > threshold {
                            commitDecision(.keep, card: card)
                        } else if value.translation.width < -threshold {
                            commitDecision(.drop, card: card)
                        } else {
                            withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                        }
                    }
            )
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Bottom buttons

    @ViewBuilder
    private func bottomButtons(card: LocalCardProvider.Card) -> some View {
        HStack(spacing: 20) {
            Button(action: { commitDecision(.drop, card: card) }) {
                Label("Drop", systemImage: "xmark")
                    .font(.labelSerif)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.grainPaper)
                    .foregroundStyle(Color.ink)
                    .clipShape(RoundedRectangle(cornerRadius: .interactiveRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: .interactiveRadius)
                            .stroke(Color.divider, lineWidth: 1)
                    )
            }
            .accessibilityLabel("Skip")
            .accessibilityHint("Remove this photo from ranking")
            Button(action: { commitDecision(.keep, card: card) }) {
                Label("Keep", systemImage: "checkmark")
                    .font(.labelSerif)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.amber)
                    .foregroundStyle(Color.filmWhite)
                    .clipShape(RoundedRectangle(cornerRadius: .interactiveRadius))
            }
            .accessibilityLabel("Keep")
            .accessibilityHint("Add this photo to the ranking round")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    // MARK: - Actions

    private func commitDecision(_ decision: CullDecision, card: LocalCardProvider.Card) {
        // Hot path: zero blocking — record in-memory, pop next card from queue
        decisionStore.record(photoId: card.photoId, decision: decision)
        pipeline.setDecision(photoId: card.photoId, decision: decision)
        syncService?.syncIfNeeded()

        let flyDirection: CGFloat = decision == .keep ? 1 : -1
        withAnimation(.easeOut(duration: 0.2)) {
            dragOffset = flyDirection * screenWidth * 1.5
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            dragOffset  = 0
            currentCard = cardProvider?.advance()
        }
    }

    private func finish() async {
        // flush (not drain): every registered-photo drop MUST reach the server
        // before ranking starts, even if a background drain is mid-flight.
        await syncService?.flush()
        do {
            try await api.finishCull(sessionId: sessionId)
            onComplete()
        } catch {
            ErrorReporter.capture(error)
            finishFailed = true
        }
        isFinishing = false
    }
}

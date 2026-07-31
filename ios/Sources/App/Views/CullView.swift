import SwiftUI

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
    @State private var isInitialized    = false
    @State private var expandedCard: LocalCardProvider.Card?
    @State private var screenWidth: CGFloat = 390

    private var dragProgress: CGFloat { dragOffset / (screenWidth * 0.4) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.filmWhite.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar

                    switch cardProvider?.state ?? .loading {
                    case .loading:
                        Spacer()
                        ProgressView().tint(Color.amber)
                        Spacer()

                    case .ready:
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
            .onChange(of: cardProvider?.queue.isEmpty) { _, isEmpty in
                // Guard against firing during initialization — initialize() calls advance() itself.
                if isEmpty == false, currentCard == nil, isInitialized {
                    currentCard = cardProvider?.advance()
                }
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

    // MARK: - Initialization

    private func initialize() async {
        let provider = LocalCardProvider(pipeline: pipeline)
        let sync = SyncService(
            sessionId: sessionId,
            api: api,
            registrationState: { pipeline.registrationState(for: $0) }
        )
        cardProvider = provider
        syncService  = sync

        async let syncReady: Void = sync.start(store: decisionStore)
        let decidedIds = await decisionStore.load(sessionId: sessionId)
        await provider.start(excluding: decidedIds)
        await syncReady

        currentCard   = provider.advance()
        isInitialized = true
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

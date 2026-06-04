import SwiftUI

struct CullView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    @ObservedObject var uploadService: UploadService
    var onComplete: () -> Void

    @State private var decisionStore  = DecisionStore()
    @State private var prefetchService: CullPrefetchService?
    @State private var syncService:     SyncService?
    @State private var currentCard:     CullPrefetchService.PrefetchedCard?
    @State private var dragOffset:      CGFloat = 0
    @State private var isFinishing      = false
    @State private var finishFailed     = false
    @State private var isInitialized    = false
    @State private var expandedCard:     CullPrefetchService.PrefetchedCard?

    private var screenWidth: CGFloat  { UIScreen.main.bounds.width }
    private var dragProgress: CGFloat { dragOffset / (screenWidth * 0.4) }

    var body: some View {
        ZStack {
            Color.filmWhite.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                switch prefetchService?.state ?? .loading {
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
                    Color.clear.onAppear { onComplete() }

                case .error(let message):
                    Spacer()
                    VStack(spacing: 12) {
                        Text(message)
                            .font(.bodySerif)
                            .foregroundStyle(Color.amber)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Retry") { prefetchService?.retry() }
                            .font(.labelSerif)
                            .foregroundStyle(Color.filmWhite)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.amber)
                            .cornerRadius(.interactiveRadius)
                    }
                    Spacer()
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
        .onChange(of: prefetchService?.queue.isEmpty) { _, isEmpty in
            // Guard against firing during initialization — initialize() calls advance() itself.
            if isEmpty == false, currentCard == nil, isInitialized {
                currentCard = prefetchService?.advance()
            }
        }
    }

    // MARK: - Initialization

    private func initialize() async {
        let ps = CullPrefetchService(sessionId: sessionId, api: api, decisionStore: decisionStore)
        let ss = SyncService(sessionId: sessionId, api: api)
        prefetchService = ps
        syncService     = ss

        async let syncReady: Void = ss.start(store: decisionStore)
        let decidedIds = await decisionStore.load(sessionId: sessionId)
        await ps.start(excluding: decidedIds)
        await syncReady

        currentCard   = ps.advance()
        isInitialized = true
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            if uploadService.total > 0 {
                let remaining = max(0, uploadService.total - decisionStore.decisions.count)
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
    private func cardStack(card: CullPrefetchService.PrefetchedCard) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: card.image)
                .resizable()
                .scaledToFit()
                .cornerRadius(.photoRadius)
                .overlay(
                    Group {
                        if dragOffset > 0 {
                            Color.green.opacity(min(dragProgress, 1.0) * 0.35)
                                .cornerRadius(.photoRadius)
                        } else if dragOffset < 0 {
                            Color.red.opacity(min(-dragProgress, 1.0) * 0.35)
                                .cornerRadius(.photoRadius)
                        }
                    }
                )
                .overlay(alignment: .topTrailing) {
                    Button { expandedCard = card } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.photoOverlay)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
                .offset(x: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in dragOffset = value.translation.width }
                        .onEnded { value in
                            let threshold = screenWidth * 0.4
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
    private func bottomButtons(card: CullPrefetchService.PrefetchedCard) -> some View {
        HStack(spacing: 20) {
            Button(action: { commitDecision(.drop, card: card) }) {
                Label("Drop", systemImage: "xmark")
                    .font(.labelSerif)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.grainPaper)
                    .foregroundStyle(Color.ink)
                    .cornerRadius(.interactiveRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: .interactiveRadius)
                            .stroke(Color.divider, lineWidth: 1)
                    )
            }
            Button(action: { commitDecision(.keep, card: card) }) {
                Label("Keep", systemImage: "checkmark")
                    .font(.labelSerif)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.amber)
                    .foregroundStyle(Color.filmWhite)
                    .cornerRadius(.interactiveRadius)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    // MARK: - Actions

    private func commitDecision(_ decision: CullDecision, card: CullPrefetchService.PrefetchedCard) {
        // Hot path: zero blocking — record in-memory, pop next card from queue
        decisionStore.record(photoId: card.photoId, decision: decision)
        syncService?.syncIfNeeded()

        let flyDirection: CGFloat = decision == .keep ? 1 : -1
        withAnimation(.easeOut(duration: 0.2)) {
            dragOffset = flyDirection * screenWidth * 1.5
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            dragOffset  = 0
            currentCard = prefetchService?.advance()
        }
    }

    private func finish() async {
        await syncService?.drain()
        do {
            try await api.finishCull(sessionId: sessionId)
            onComplete()
        } catch {
            finishFailed = true
        }
        isFinishing = false
    }
}

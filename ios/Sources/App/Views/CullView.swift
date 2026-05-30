import SwiftUI

struct CullView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    @ObservedObject var uploadService: UploadService
    var onComplete: () -> Void

    @State private var card: CullCard?
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var dragOffset: CGFloat = 0
    @State private var errorMessage: String?

    // Inline submit-error banner state (does not block UI)
    @State private var submitErrorBanner: String?
    @State private var pendingRetry: (() -> Void)?

    @State private var localDecisionsMade: Int = 0

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }
    private var dragProgress: CGFloat { dragOffset / (screenWidth * 0.4) }

    var body: some View {
        ZStack {
            Color.filmWhite.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                if let errorMessage {
                    // Terminal error — full-screen takeover
                    Spacer()
                    Text(errorMessage)
                        .font(.bodySerif)
                        .foregroundStyle(Color.amber)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                } else {
                    // Normal state: card area + always-visible buttons
                    Spacer()
                    cardArea
                    Spacer()

                    // Inline submit-error banner above buttons
                    if let banner = submitErrorBanner {
                        Button(action: {
                            pendingRetry?()
                        }) {
                            Text(banner)
                                .font(.captionSerif)
                                .foregroundStyle(Color.filmWhite)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(8)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                    }

                    if let card {
                        bottomButtons(card: card)
                    }
                }
            }
        }
        .task { await fetchNext() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            if uploadService.total > 0 {
                let displayed = max(0, uploadService.total - localDecisionsMade)
                Text("\(displayed) remaining")
                    .font(.captionSerif)
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer()
            Button("Done — start comparing") {
                Task { await finish() }
            }
            .font(.labelSerif)
            .foregroundStyle(Color.amber)
            .disabled(isSubmitting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Card area (fixed slot — shows image or loading placeholder)

    @ViewBuilder
    private var cardArea: some View {
        if isLoading {
            // Card-area loading placeholder — buttons still visible below
            Color.grainPaper
                .cornerRadius(.photoRadius)
                .overlay(ProgressView().tint(Color.amber))
                .padding(.horizontal, 12)
        } else if let card {
            cardStack(card: card)
        }
    }

    // MARK: - Card stack

    @ViewBuilder
    private func cardStack(card: CullCard) -> some View {
        ZStack(alignment: .topTrailing) {
            AsyncImage(url: URL(string: card.photoUrl ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(.photoRadius)
                case .failure:
                    Color.grainPaper.cornerRadius(.photoRadius)
                default:
                    Color.grainPaper
                        .cornerRadius(.photoRadius)
                        .overlay(ProgressView().tint(Color.amber))
                }
            }
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
            .offset(x: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !isSubmitting else { return }
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        guard !isSubmitting else { return }
                        let threshold = screenWidth * 0.4
                        if value.translation.width > threshold {
                            commitDecision("keep", card: card)
                        } else if value.translation.width < -threshold {
                            commitDecision("drop", card: card)
                        } else {
                            withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                        }
                    }
            )

            if let size = card.clusterSize, size > 1 {
                Text("1 of \(size) similar")
                    .font(.captionSerif)
                    .foregroundStyle(Color.filmWhite)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.photoOverlay)
                    .cornerRadius(4)
                    .padding(12)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Bottom buttons

    @ViewBuilder
    private func bottomButtons(card: CullCard) -> some View {
        HStack(spacing: 20) {
            Button(action: { commitDecision("drop", card: card) }) {
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
            Button(action: { commitDecision("keep", card: card) }) {
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
        .disabled(isSubmitting)
    }

    // MARK: - Actions

    private func commitDecision(_ decision: String, card: CullCard) {
        guard !isSubmitting, let photoId = card.photoId else { return }
        isSubmitting = true
        submitErrorBanner = nil
        pendingRetry = nil
        localDecisionsMade += 1

        let flyDirection: CGFloat = decision == "keep" ? 1 : -1
        withAnimation(.easeOut(duration: 0.2)) {
            dragOffset = flyDirection * screenWidth * 1.5
        }

        Task {
            // Submit races with the fly animation; both must complete before advancing.
            // The server records the decision before the next nextCull call, which
            // prevents getting the same card back again.
            async let submitted: Void = submitWithRetry(
                sessionId: sessionId,
                photoId: photoId,
                decision: decision,
                totalAttempts: 3
            )
            try? await Task.sleep(for: .milliseconds(250))
            dragOffset = 0
            isLoading = true
            await submitted
            await fetchNext()
            isSubmitting = false
        }
    }

    private func finish() async {
        isSubmitting = true
        do {
            try await api.finishCull(sessionId: sessionId)
            isSubmitting = false
            onComplete()
        } catch {
            errorMessage = "Couldn't finish. Try again."
            isSubmitting = false
        }
    }

    private func fetchNext() async {
        isLoading = true
        errorMessage = nil
        do {
            let next = try await api.nextCull(sessionId: sessionId)
            if next.done {
                isLoading = false
                onComplete()
                return
            }
            card = next
        } catch {
            errorMessage = "Couldn't load next photo. Check connection."
        }
        isLoading = false
    }

    // MARK: - Submit with retry

    private nonisolated func submitWithRetry(
        sessionId: UUID,
        photoId: UUID,
        decision: String,
        totalAttempts: Int
    ) async {
        do {
            _ = try await api.submitCull(
                sessionId: sessionId,
                photoId: photoId,
                decision: decision
            )
            // Clear any lingering error banner on success
            await MainActor.run {
                submitErrorBanner = nil
                pendingRetry = nil
            }
        } catch {
            if totalAttempts > 1 {
                try? await Task.sleep(for: .milliseconds(500))
                await submitWithRetry(
                    sessionId: sessionId,
                    photoId: photoId,
                    decision: decision,
                    totalAttempts: totalAttempts - 1
                )
            } else {
                // All retries exhausted — show inline error banner
                await MainActor.run {
                    submitErrorBanner = "Couldn't save last decision — tap to retry"
                    pendingRetry = {
                        Task { @MainActor in
                            submitErrorBanner = nil
                            pendingRetry = nil
                        }
                        Task.detached(priority: .background) {
                            await submitWithRetry(
                                sessionId: sessionId,
                                photoId: photoId,
                                decision: decision,
                                totalAttempts: 3
                            )
                        }
                    }
                }
            }
        }
    }
}

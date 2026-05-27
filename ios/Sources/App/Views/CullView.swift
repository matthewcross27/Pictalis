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

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }
    private var dragProgress: CGFloat { dragOffset / (screenWidth * 0.4) }

    var body: some View {
        ZStack {
            Color.filmWhite.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.amber)
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    Text(errorMessage)
                        .font(.bodySerif)
                        .foregroundStyle(Color.amber)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                } else if let card, !card.done {
                    Spacer()
                    cardStack(card: card)
                    Spacer()
                    bottomButtons(card: card)
                }
            }
        }
        .task { await fetchNext() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            if let card, let remaining = card.cardsRemaining {
                Text("\(remaining) remaining")
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

    // MARK: - Card

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
        let flyDirection: CGFloat = decision == "keep" ? 1 : -1
        withAnimation(.easeOut(duration: 0.2)) {
            dragOffset = flyDirection * screenWidth * 1.5
        }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            isLoading = true
            dragOffset = 0
            do {
                let result = try await api.submitCull(
                    sessionId: sessionId,
                    photoId: photoId,
                    decision: decision
                )
                if result.done {
                    isSubmitting = false
                    onComplete()
                    return
                }
                await fetchNext()
            } catch {
                errorMessage = "Failed to submit. Try again."
            }
            isSubmitting = false
        }
    }

    private func finish() async {
        isSubmitting = true
        do {
            try await api.finishCull(sessionId: sessionId)
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
                onComplete()
                return
            }
            card = next
        } catch {
            errorMessage = "Couldn't load next photo. Check connection."
        }
        isLoading = false
    }
}

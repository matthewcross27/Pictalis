import SwiftUI

struct ComparisonView: View {
    @Environment(APIClient.self) private var api

    let sessionId: UUID
    var pipeline: PhotoPipeline
    var onSkipToResults: () -> Void
    var onComplete: (Int) -> Void

    @State private var pair: NextPairResponse?
    @State private var isLoading = true
    @State private var waitingForUploads = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var comparisonCount = 0
    @State private var fullscreenPhoto: PairPhoto?
    @State private var currentStage: RankingStage?
    @State private var prefetchedPair: NextPairResponse?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var isRemoving = false
    @State private var dragOffsetA: CGFloat = 0
    @State private var dragOffsetB: CGFloat = 0
    @State private var hasDraggedA = false
    @State private var hasDraggedB = false

    var body: some View {
        ZStack {
            Color.filmWhite.ignoresSafeArea()

            VStack(spacing: 0) {
                if !pipeline.failedIds.isEmpty {
                    Button {
                        pipeline.retryParked()
                    } label: {
                        Text("\(pipeline.failedIds.count) photo\(pipeline.failedIds.count == 1 ? "" : "s") couldn't be included — tap to retry")
                            .font(.captionSerif)
                            .foregroundStyle(Color.secondaryText)
                    }
                    .padding(.vertical, 6)
                }

                if isLoading {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView().tint(Color.amber)
                        Text(waitingForUploads ? "Waiting for photos to finish uploading…" : "Loading photos…")
                            .font(.captionSerif)
                            .foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    VStack(spacing: 16) {
                        Text(errorMessage)
                            .font(.bodySerif)
                            .foregroundStyle(Color.amber)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Try Again") {
                            Task { @MainActor in await fetchNextPair() }
                        }
                        .font(.labelSerif)
                        .foregroundStyle(Color.ink)
                    }
                    Spacer()
                } else if let pair {
                    Spacer()
                    VStack(spacing: 8) {
                        photoCard(photo: pair.photoA, dragOffset: $dragOffsetA, hasDragged: $hasDraggedA)
                        photoCard(photo: pair.photoB, dragOffset: $dragOffsetB, hasDragged: $hasDraggedB)
                    }
                    .padding(.horizontal, 8)
                    .opacity((isSubmitting || isRemoving) ? 0.7 : 1.0)
                    .disabled(isSubmitting || isRemoving)
                    .animation(.buttonPress, value: isSubmitting)
                    Spacer()
                }

                bottomBar
            }
        }
        .task { await fetchNextPair() }
        .onChange(of: pair?.comparisonId) { _, newId in
            dragOffsetA = 0
            dragOffsetB = 0
            hasDraggedA = false
            hasDraggedB = false
            if newId != nil { startPrefetch() }
        }
        .onDisappear {
            prefetchTask?.cancel()
            prefetchedPair = nil
        }
        .fullScreenCover(item: $fullscreenPhoto) { photo in
            ZStack {
                Color.photoBackground.ignoresSafeArea()
                AsyncImage(url: photo.signedUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        ProgressView().tint(Color.filmWhite)
                    }
                }
            }
            .onTapGesture { fullscreenPhoto = nil }
        }
    }

    // MARK: - Subviews

    private var bottomBar: some View {
        HStack {
            if let stage = currentStage {
                StageBadge(stage: stage, isComplete: false)
            }

            Spacer()

            Button("Skip") { onSkipToResults() }
                .font(.labelSerif)
                .foregroundStyle(Color.secondaryText)
                .opacity(comparisonCount < 1 ? 0.35 : 1.0)
                .disabled(comparisonCount < 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.filmWhite)
    }

    @ViewBuilder
    private func photoCard(photo: PairPhoto, dragOffset: Binding<CGFloat>, hasDragged: Binding<Bool>) -> some View {
        ZStack {
            Color.red.opacity(0.85)
                .overlay(alignment: .trailing) {
                    Label("Remove", systemImage: "trash")
                        .font(.labelSerif)
                        .foregroundStyle(.white)
                        .padding(.trailing, 20)
                }

            ZStack {
                Button {
                    guard !hasDragged.wrappedValue else { return }
                    Task { @MainActor in await choose(winner: photo) }
                } label: {
                    Color.grainPaper
                        .frame(maxWidth: .infinity)
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .overlay {
                            AsyncImage(url: photo.signedUrl) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView().tint(Color.secondaryText)
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                case .failure:
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(Color.secondaryText)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        }
                        .clipped()
                }
                .buttonStyle(PhotoTapStyle())
                .accessibilityLabel(photo.id == pair?.photoA.id ? "First photo" : "Second photo")
                .accessibilityHint("Choose this photo as your favorite")

                VStack {
                    HStack {
                        Spacer()
                        ExpandPhotoButton { fullscreenPhoto = photo }
                    }
                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
            .offset(x: min(0, dragOffset.wrappedValue))
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
        .contentShape(RoundedRectangle(cornerRadius: .photoRadius))
        .simultaneousGesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onChanged { value in
                    guard value.translation.width < 0 else { return }
                    hasDragged.wrappedValue = true
                    dragOffset.wrappedValue = value.translation.width
                }
                .onEnded { value in
                    let triggered = value.translation.width < -80
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset.wrappedValue = 0
                    }
                    if triggered {
                        Task { @MainActor in await remove(photo: photo) }
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        hasDragged.wrappedValue = false
                    }
                }
        )
    }

    // MARK: - Private

    private func startPrefetch() {
        prefetchTask?.cancel()
        prefetchedPair = nil
        prefetchTask = Task {
            guard let response = try? await api.nextPair(sessionId: sessionId) else { return }
            guard !Task.isCancelled else { return }
            prefetchedPair = response
        }
    }

    private func choose(winner: PairPhoto) async {
        guard let pair else { return }
        isSubmitting = true
        do {
            _ = try await api.submitComparison(
                comparisonId: pair.comparisonId,
                winnerId: winner.id
            )
            comparisonCount += 1
        } catch {
            print("Submit failed: \(error)")
            prefetchedPair = nil
            prefetchTask?.cancel()
            isSubmitting = false
            self.pair = nil
            await fetchNextPair()
            return
        }
        isSubmitting = false
        if let next = prefetchedPair {
            withAnimation(.pairTransition) {
                currentStage = next.stage.flatMap { RankingStage(rawValue: $0) }
                self.pair = next
            }
            prefetchedPair = nil
        } else {
            self.pair = nil
            await fetchNextPair()
        }
    }

    private func remove(photo: PairPhoto) async {
        guard !isRemoving, !isSubmitting else { return }
        isRemoving = true
        prefetchTask?.cancel()
        prefetchedPair = nil
        do {
            try await api.removePhoto(sessionId: sessionId, photoId: photo.id)
        } catch {
            print("Remove failed: \(error)")
            isRemoving = false
            return
        }
        isRemoving = false
        self.pair = nil
        if let status = try? await api.sessionStatus(sessionId: sessionId), status.isComplete {
            onComplete(status.totalComparisons)
        } else {
            await fetchNextPair()
        }
    }

    private func fetchNextPair() async {
        isLoading = true
        errorMessage = nil

        // A pair only needs 2 registered photos; registeredCount increments
        // as register-photo succeeds — wait on local state instead of
        // burning network round trips on guaranteed 422s.
        while pipeline.registeredCount < 2 {
            if pipeline.isComplete {
                let failed = pipeline.failedIds.count
                errorMessage = failed > 0
                    ? "\(failed) photo upload\(failed == 1 ? "" : "s") failed. Please go back and try again."
                    : "Not enough photos could be uploaded. Please go back and try again."
                waitingForUploads = false
                isLoading = false
                return
            }
            waitingForUploads = true
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        waitingForUploads = false

        var delay: Duration = .milliseconds(500)
        for _ in 0..<6 {
            if Task.isCancelled { return }
            do {
                let response = try await api.nextPair(sessionId: sessionId)
                currentStage = response.stage.flatMap { RankingStage(rawValue: $0) }
                pair = response
                isLoading = false
                return
            } catch APIError.httpError(statusCode: 422, _) {
                // 422 with photos registered means the session finished (or is
                // about to be marked finished) — confirm and exit to results.
                if let status = try? await api.sessionStatus(sessionId: sessionId),
                   status.isComplete {
                    prefetchTask?.cancel()
                    prefetchedPair = nil
                    isLoading = false
                    onComplete(status.totalComparisons)
                    return
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(4))
            } catch {
                errorMessage = "Failed to load next pair: \(error.localizedDescription)"
                isLoading = false
                return
            }
        }
        errorMessage = "Couldn't load the next pair."
        isLoading = false
    }
}

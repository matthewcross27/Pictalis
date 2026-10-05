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
    @State private var photoAspects: [UUID: CGFloat] = [:]

    private let cardSpacing: CGFloat = 8

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

                ZStack {
                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView().tint(Color.amber)
                            Text(waitingForUploads ? "Waiting for photos to finish uploading…" : "Loading photos…")
                                .font(.captionSerif)
                                .foregroundStyle(Color.secondaryText)
                        }
                    } else if let errorMessage {
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
                    } else if let pair {
                        GeometryReader { proxy in
                            pairLayout(for: pair, in: proxy.size)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                        .padding(.horizontal, 8)
                        .opacity((isSubmitting || isRemoving) ? 0.7 : 1.0)
                        .disabled(isSubmitting || isRemoving)
                        .animation(.buttonPress, value: isSubmitting)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
            }
        }
        .task { await fetchNextPair() }
        .onChange(of: pair?.comparisonId) { _, newId in
            dragOffsetA = 0
            dragOffsetB = 0
            hasDraggedA = false
            hasDraggedB = false
            // Aspect ratios are only needed for the current pair; the image cache
            // supplies them again if a photo comes back around.
            let currentIds = [pair?.photoA.id, pair?.photoB.id].compactMap { $0 }
            photoAspects = photoAspects.filter { currentIds.contains($0.key) }
            if newId != nil { startPrefetch() }
        }
        .onDisappear {
            prefetchTask?.cancel()
            prefetchedPair = nil
        }
        .fullScreenCover(item: $fullscreenPhoto) { photo in
            PhotoExpandedView(id: photo.id, signedUrl: photo.signedUrl, background: .photoBackground) {
                fullscreenPhoto = nil
            }
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
    private func pairLayout(for pair: NextPairResponse, in available: CGSize) -> some View {
        let layout = ComparisonLayout.layout(
            aspectA: aspect(of: pair.photoA),
            aspectB: aspect(of: pair.photoB),
            in: available,
            spacing: cardSpacing
        )
        let cardA = photoCard(
            photo: pair.photoA, size: layout.sizeA, dragOffset: $dragOffsetA, hasDragged: $hasDraggedA
        )
        let cardB = photoCard(
            photo: pair.photoB, size: layout.sizeB, dragOffset: $dragOffsetB, hasDragged: $hasDraggedB
        )
        Group {
            switch layout.arrangement {
            case .stacked:
                VStack(spacing: cardSpacing) { cardA; cardB }
            case .sideBySide:
                HStack(spacing: cardSpacing) { cardA; cardB }
            }
        }
        .animation(.pairTransition, value: layout)
    }

    private func aspect(of photo: PairPhoto) -> CGFloat {
        if let known = photoAspects[photo.id] { return known }
        if let cached = PhotoMemoryCache.shared.image(for: photo.id, thumbnail: false) {
            return ComparisonLayout.aspect(of: cached.size)
        }
        return ComparisonLayout.placeholderAspect
    }

    @ViewBuilder
    private func photoCard(
        photo: PairPhoto, size: CGSize, dragOffset: Binding<CGFloat>, hasDragged: Binding<Bool>
    ) -> some View {
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
                        .frame(width: size.width, height: size.height)
                        .overlay {
                            CachedPhotoImage(
                                url: photo.signedUrl,
                                cacheKey: photo.id,
                                onLoaded: { photoAspects[photo.id] = ComparisonLayout.aspect(of: $0) }
                            ) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView().tint(Color.secondaryText)
                                case .success(let image):
                                    // The card is sized to the photo, so fit shows all of it.
                                    image.resizable().scaledToFit()
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
        .frame(width: size.width, height: size.height)
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
            // Warm the image cache so the next pair appears already sized to its
            // photos instead of reflowing when the downloads land.
            await withTaskGroup(of: Void.self) { group in
                for photo in [response.photoA, response.photoB] {
                    group.addTask {
                        _ = try? await CachedPhotoImage<EmptyView>.fetch(url: photo.signedUrl, cacheKey: photo.id)
                    }
                }
            }
        }
    }

    private func choose(winner: PairPhoto) async {
        guard let pair else { return }
        isSubmitting = true
        do {
            try await api.submitComparison(
                comparisonId: pair.comparisonId,
                winnerId: winner.id
            )
            comparisonCount += 1
        } catch {
            ErrorReporter.capture(error)
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
            ErrorReporter.capture(error)
            isRemoving = false
            return
        }
        isRemoving = false
        self.pair = nil
        // fetchNextPair() already detects and handles session completion via
        // its own 422-triggered sessionStatus check - no need to check here too.
        await fetchNextPair()
    }

    private func fetchNextPair() async {
        isLoading = true
        errorMessage = nil

        // A pair only needs 2 registered photos; registeredCount increments
        // as batch-register-photos confirms each one - wait on local state
        // instead of burning network round trips on guaranteed 422s.
        while pipeline.registeredCount < 2 {
            if pipeline.isSettled {
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
                ErrorReporter.capture(error)
                errorMessage = ErrorPresentation.message(for: error)
                isLoading = false
                return
            }
        }
        errorMessage = "Couldn't load the next pair."
        isLoading = false
    }
}

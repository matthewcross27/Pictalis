import SwiftUI

struct ComparisonView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    @ObservedObject var uploadService: UploadService
    var onSkipToResults: () -> Void
    var onComplete: (Int) -> Void

    @State private var pair: NextPairResponse?
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var comparisonCount = 0
    @State private var fullscreenPhoto: PairPhoto?
    @State private var currentStage: String?
    @State private var prefetchedPair: NextPairResponse?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var isRemoving = false

    var body: some View {
        ZStack {
            Color.filmWhite.ignoresSafeArea()

            VStack(spacing: 0) {
                uploadBanner

                if isLoading {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView().tint(Color.amber)
                        Text("Loading photos…")
                            .font(.captionSerif)
                            .foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    Text(errorMessage)
                        .font(.bodySerif)
                        .foregroundStyle(Color.amber)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                } else if let pair {
                    Spacer()
                    VStack(spacing: 8) {
                        photoButton(photo: pair.photoA)
                        photoButton(photo: pair.photoB)
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
            if newId != nil { startPrefetch() }
        }
        .onDisappear {
            prefetchTask?.cancel()
            prefetchedPair = nil
        }
        .fullScreenCover(item: $fullscreenPhoto) { photo in
            ZStack {
                Color(red: 0.059, green: 0.055, blue: 0.043).ignoresSafeArea()
                AsyncImage(url: URL(string: photo.signedUrl)) { phase in
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

    @ViewBuilder
    private var uploadBanner: some View {
        if !uploadService.isComplete {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Amber progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.divider)
                                .frame(height: 2)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.amber)
                                .frame(
                                    width: geo.size.width * CGFloat(uploadService.completed) / CGFloat(max(uploadService.total, 1)),
                                    height: 2
                                )
                                .animation(.easeOut, value: uploadService.completed)
                        }
                    }
                    .frame(height: 2)

                    Text("\(uploadService.completed)/\(uploadService.total)")
                        .font(.captionSerif)
                        .foregroundStyle(Color.secondaryText)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.grainPaper)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            if let stage = currentStage {
                StageBadge(stage: stage)
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
    private func photoButton(photo: PairPhoto) -> some View {
        Button {
            Task { @MainActor in await choose(winner: photo) }
        } label: {
            Color.grainPaper
                .frame(maxWidth: .infinity)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    AsyncImage(url: URL(string: photo.signedUrl)) { phase in
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
                .overlay(alignment: .topTrailing) {
                    Button {
                        fullscreenPhoto = photo
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.photoOverlay)
                            .clipShape(Capsule())
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    Button {
                        Task { @MainActor in await remove(photo: photo) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.red.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    .padding(8)
                }
        }
        .buttonStyle(PhotoTapStyle())
        .clipShape(RoundedRectangle(cornerRadius: .photoRadius))
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
                currentStage = next.stage
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

    private func fetchNextPair(retryCount: Int = 0) async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await api.nextPair(sessionId: sessionId)
            currentStage = response.stage
            pair = response
            isLoading = false
        } catch APIError.httpError(statusCode: 422, _) {
            if let status = try? await api.sessionStatus(sessionId: sessionId),
               status.isComplete {
                prefetchTask?.cancel()
                prefetchedPair = nil
                isLoading = false
                onComplete(status.totalComparisons)
                return
            }
            guard retryCount < 30 else {
                errorMessage = "Not enough photos available. Please go back and try again."
                isLoading = false
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await fetchNextPair(retryCount: retryCount + 1)
        } catch {
            errorMessage = "Failed to load next pair: \(error.localizedDescription)"
            isLoading = false
        }
    }
}

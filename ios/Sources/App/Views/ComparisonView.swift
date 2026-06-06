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
    @State private var dragOffsetA: CGFloat = 0
    @State private var dragOffsetB: CGFloat = 0
    @State private var hasDraggedA = false
    @State private var hasDraggedB = false

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
                }
                .buttonStyle(PhotoTapStyle())

                VStack {
                    HStack {
                        Spacer()
                        Button { fullscreenPhoto = photo } label: {
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

    private func fetchNextPair() async {
        isLoading = true
        errorMessage = nil

        var delay: Duration = .milliseconds(500)
        for attempt in 0..<10 {
            do {
                let response = try await api.nextPair(sessionId: sessionId)
                currentStage = response.stage
                pair = response
                isLoading = false
                return
            } catch APIError.httpError(statusCode: 422, _) {
                if let status = try? await api.sessionStatus(sessionId: sessionId),
                   status.isComplete {
                    prefetchTask?.cancel()
                    prefetchedPair = nil
                    isLoading = false
                    onComplete(status.totalComparisons)
                    return
                }
                if attempt == 0 {
                    errorMessage = "Waiting for photos to finish uploading…"
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(8))
            } catch {
                errorMessage = "Failed to load next pair: \(error.localizedDescription)"
                isLoading = false
                return
            }
        }
        errorMessage = "Not enough photos available. Please go back and try again."
        isLoading = false
    }
}

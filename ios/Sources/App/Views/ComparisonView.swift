import SwiftUI

struct ComparisonView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    @ObservedObject var uploadService: UploadService
    var onFinish: () -> Void

    @State private var pair: NextPairResponse?
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var comparisonCount = 0

    var body: some View {
        VStack(spacing: 0) {
            // Upload progress banner while photos are still uploading
            if !uploadService.isComplete {
                HStack {
                    ProgressView(
                        value: Double(uploadService.completed),
                        total: Double(max(uploadService.total, 1))
                    )
                    Text("\(uploadService.completed)/\(uploadService.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
            }

            if isLoading {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading photos…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if let errorMessage {
                Spacer()
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
                Spacer()
            } else if let pair {
                HStack(spacing: 4) {
                    photoButton(photo: pair.photoA)
                    photoButton(photo: pair.photoB)
                }
                .disabled(isSubmitting)
            }

            HStack {
                Text("\(comparisonCount) comparisons")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("See Results") { onFinish() }
                    .font(.subheadline)
                    .disabled(comparisonCount < 1)
            }
            .padding()
        }
        .task { await fetchNextPair() }
    }

    // MARK: - Private

    @ViewBuilder
    private func photoButton(photo: PairPhoto) -> some View {
        Button {
            Task { @MainActor in await choose(winner: photo) }
        } label: {
            AsyncImage(url: URL(string: photo.signedUrl)) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemBackground))
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemBackground))
                @unknown default:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        }
        isSubmitting = false
        self.pair = nil
        await fetchNextPair()
    }

    private func fetchNextPair(retryCount: Int = 0) async {
        isLoading = true
        errorMessage = nil
        do {
            pair = try await api.nextPair(sessionId: sessionId)
            isLoading = false
        } catch APIError.httpError(statusCode: 422, _) {
            // Not enough photos registered yet — wait and retry (max 30 attempts = 30 s)
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

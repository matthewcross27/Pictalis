import SwiftUI
import PhotosUI

struct SessionSetupView: View {
    @Environment(AuthService.self) private var auth
    @Environment(APIClient.self) private var api

    var onStart: (UUID, PhotoPipeline) -> Void

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isStarting = false
    @State private var errorMessage: String?
    // Survives a failed start so a retry with the same selection resumes
    // instead of creating another session; dropped when the selection changes.
    @State private var attempt: SessionStartAttempt?

    private var selectionCount: Int { selectedItems.count }
    private var canStart: Bool { selectionCount >= 2 && auth.isAuthenticated && !isStarting }

    var body: some View {
        ZStack {
            Color.filmWhite.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                // App identity
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pictalis")
                        .font(.displaySerif)
                        .foregroundStyle(Color.ink)
                        .tracking(-0.72)

                    Text("Find the photos you'll actually come back to.")
                        .font(.bodySerif)
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)

                Spacer()

                // Bottom action stack
                VStack(spacing: 10) {
                    // Photo picker
                    // `count` is captured as a plain Int before the label closure since
                    // PhotosPicker's label closure is @Sendable/nonisolated and cannot
                    // read the main-actor-isolated `selectionCount` computed property directly.
                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: 300,
                        matching: .images
                    ) { [count = selectionCount] in
                        HStack(spacing: 12) {
                            Image(systemName: count > 0 ? "photo.stack" : "plus")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(count > 0 ? Color.ink : Color.secondaryText)

                            Text(count > 0 ? "\(count) photos" : "Choose photos")
                                .font(.titleSerif)
                                .foregroundStyle(count > 0 ? Color.ink : Color.secondaryText)

                            Spacer()

                            if count > 0 {
                                Text("Change")
                                    .font(.captionSerif)
                                    .foregroundStyle(Color.secondaryText)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: .interactiveRadius)
                                .fill(Color.grainPaper)
                        )
                    }
                    .accessibilityLabel(selectionCount > 0 ? "\(selectionCount) photos selected" : "Choose photos")
                    .accessibilityHint("Open your photo library and select photos to curate")

                    // Error state
                    if let message = auth.authError.map({ ErrorPresentation.message(for: $0) }) ?? errorMessage {
                        Text(message)
                            .font(.captionSerif)
                            .foregroundStyle(Color.amber)
                            .padding(.horizontal, 4)
                    }

                    // Primary CTA
                    Button(action: startSession) {
                        if isStarting {
                            ProgressView().tint(Color.filmWhite)
                        } else {
                            Text("Start Curating")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canStart)
                    .accessibilityLabel("Start Curating")
                    .accessibilityHint("Begin curating your selected photos")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onChange(of: selectedItems) { attempt = nil }
    }

    // MARK: - Private

    private func startSession() {
        guard let userId = auth.userId else { return }
        let items = selectedItems
        isStarting = true
        errorMessage = nil

        // Generate stable photo IDs up front so the same IDs are used for both
        // the server rows and the pipeline items, across retries.
        let attempt = self.attempt ?? SessionStartAttempt(
            photos: items.map { PendingPhoto(loader: PickerItemLoader(item: $0)) }
        )
        self.attempt = attempt

        Task { @MainActor in
            do {
                try await attempt.run(api: api)
                let pipeline = PhotoPipeline(
                    transport: SupabaseUploadTransport(supabase: auth.storageClient, api: api),
                    sessionId: attempt.sessionId,
                    userId: userId
                )
                pipeline.start(photos: attempt.photos)
                self.attempt = nil
                onStart(attempt.sessionId, pipeline)
            } catch {
                ErrorReporter.capture(error)
                errorMessage = ErrorPresentation.message(for: error)
                isStarting = false
            }
        }
    }
}

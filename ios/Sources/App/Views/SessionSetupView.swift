import Sentry
import SwiftUI
import PhotosUI

struct SessionSetupView: View {
    @Environment(AuthService.self) private var auth
    @Environment(APIClient.self) private var api

    var onStart: (UUID, PhotoPipeline) -> Void

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isStarting = false
    @State private var errorMessage: String?

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
                    .accessibilityHint("Double-tap to open your photo library and select photos to curate")

                    // Error state
                    if let message = auth.authError.map({ "Sign-in error: \($0)" }) ?? errorMessage {
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
                    .accessibilityHint("Double-tap to begin curating your selected photos")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Private

    private func startSession() {
        guard let userId = auth.userId else { return }
        let items = selectedItems
        isStarting = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let session = try await api.createSession(photoCount: items.count)
                // Generate stable photo IDs before pre-registering so the same
                // IDs are used for both the server rows and the pipeline items.
                let pendingPhotos = items.map { PendingPhoto(loader: PickerItemLoader(item: $0)) }
                try await api.batchPreRegister(
                    sessionId: session.id,
                    photoIds: pendingPhotos.map(\.id)
                )
                let pipeline = PhotoPipeline(
                    transport: SupabaseUploadTransport(supabase: auth.storageClient, api: api),
                    sessionId: session.id,
                    userId: userId
                )
                pipeline.start(photos: pendingPhotos)
                onStart(session.id, pipeline)
            } catch {
                SentrySDK.capture(error: error)
                errorMessage = "Could not start: \(error.localizedDescription)"
                isStarting = false
            }
        }
    }
}

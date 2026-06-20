import SwiftUI
import PhotosUI

struct SessionSetupView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var api: APIClient

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
                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: 300,
                        matching: .images
                    ) {
                        HStack(spacing: 12) {
                            Image(systemName: selectionCount > 0 ? "photo.stack" : "plus")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(selectionCount > 0 ? Color.ink : Color.secondaryText)

                            Text(selectionCount > 0 ? "\(selectionCount) photos" : "Choose photos")
                                .font(.titleSerif)
                                .foregroundStyle(selectionCount > 0 ? Color.ink : Color.secondaryText)

                            Spacer()

                            if selectionCount > 0 {
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

                    // Error state
                    if let err = auth.authError {
                        Text("Sign-in error: \(err)")
                            .font(.captionSerif)
                            .foregroundStyle(Color.amber)
                            .padding(.horizontal, 4)
                    } else if let err = errorMessage {
                        Text(err)
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
                errorMessage = "Could not start: \(error.localizedDescription)"
                isStarting = false
            }
        }
    }
}

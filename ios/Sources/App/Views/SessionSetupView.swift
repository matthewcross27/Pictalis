import SwiftUI
import PhotosUI

struct SessionSetupView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var api: APIClient

    // Called when session is created and upload has started.
    // Receives the sessionId and a ready UploadService.
    var onStart: (UUID, UploadService) -> Void

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isStarting = false
    @State private var errorMessage: String?

    private var selectionCount: Int { selectedItems.count }
    private var canStart: Bool { selectionCount >= 2 && auth.isAuthenticated && !isStarting }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("picHelper")
                .font(.largeTitle.bold())

            Text("Pick 2–300 photos to start curating your favorites.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 300,
                matching: .images
            ) {
                Label(
                    selectionCount > 0 ? "\(selectionCount) photos selected" : "Select Photos",
                    systemImage: "photo.on.rectangle.angled"
                )
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)

            if let authError = auth.authError {
                Text("Sign-in failed: \(authError)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(action: startSession) {
                Group {
                    if isStarting {
                        ProgressView()
                    } else {
                        Text("Start Curating")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(canStart ? Color.accentColor : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canStart)
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Private

    private func startSession() {
        guard let userId = auth.userId else { return }
        // Capture main-actor-isolated state before entering the Task to avoid
        // Sendable closure warnings from the strict concurrency checker.
        let count = selectionCount
        let items = selectedItems
        isStarting = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let session = try await api.createSession(photoCount: count)
                let sessionId = session.id

                let uploadService = UploadService(supabase: auth.supabase, api: api)
                uploadService.start(items: items, sessionId: sessionId, userId: userId)

                onStart(sessionId, uploadService)
            } catch {
                errorMessage = "Could not start session: \(error.localizedDescription)"
                isStarting = false
            }
        }
    }
}

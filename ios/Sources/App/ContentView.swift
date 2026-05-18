import SwiftUI

// Root state machine. Drives navigation between the three screens.
enum AppState {
    case setup
    case comparing(sessionId: UUID, upload: UploadService)
    case results(sessionId: UUID)
}

struct ContentView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var api: APIClient

    @State private var appState: AppState = .setup

    var body: some View {
        Group {
            switch appState {
            case .setup:
                SessionSetupView { sessionId, uploadService in
                    appState = .comparing(sessionId: sessionId, upload: uploadService)
                }

            case .comparing(let sessionId, let upload):
                ComparisonView(
                    sessionId: sessionId,
                    uploadService: upload
                ) {
                    appState = .results(sessionId: sessionId)
                }

            case .results(let sessionId):
                ResultsView(sessionId: sessionId)
            }
        }
        .animation(.easeInOut, value: {
            switch appState {
            case .setup: return 0
            case .comparing: return 1
            case .results: return 2
            }
        }())
    }
}

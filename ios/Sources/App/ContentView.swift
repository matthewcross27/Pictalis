import SwiftUI

// Root state machine. Drives navigation between the four screens.
enum AppState {
    case setup
    case comparing(sessionId: UUID, upload: UploadService)
    case complete(sessionId: UUID, totalComparisons: Int)
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
                    uploadService: upload,
                    onSkipToResults: {
                        appState = .results(sessionId: sessionId)
                    },
                    onComplete: { totalComparisons in
                        appState = .complete(sessionId: sessionId, totalComparisons: totalComparisons)
                    }
                )

            case .complete(let sessionId, let totalComparisons):
                CompletionView(
                    sessionId: sessionId,
                    totalComparisons: totalComparisons,
                    onSeeFullRankings: {
                        appState = .results(sessionId: sessionId)
                    },
                    onStartOver: {
                        appState = .setup
                    }
                )

            case .results(let sessionId):
                ResultsView(sessionId: sessionId)
            }
        }
        .animation(.easeInOut, value: {
            switch appState {
            case .setup: return 0
            case .comparing: return 1
            case .complete: return 2
            case .results: return 3
            }
        }())
    }
}

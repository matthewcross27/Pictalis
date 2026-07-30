import SwiftUI

enum AppState {
    case setup
    case choosingCullMode(sessionId: UUID, pipeline: PhotoPipeline)
    case culling(sessionId: UUID, pipeline: PhotoPipeline)
    case comparing(sessionId: UUID, pipeline: PhotoPipeline)
    case complete(sessionId: UUID, totalComparisons: Int)
    case results(sessionId: UUID, previousComparisons: Int? = nil, initialPhotos: [RankedPhoto] = [])
}

extension AppState: Equatable {
    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.setup, .setup):                             return true
        case (.choosingCullMode, .choosingCullMode):       return true
        case (.culling, .culling):                         return true
        case (.comparing, .comparing):                     return true
        case (.complete(let a, _), .complete(let b, _)):   return a == b
        case (.results(let a, _, _), .results(let b, _, _)): return a == b
        default:                                           return false
        }
    }
}

struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(APIClient.self) private var api

    @State private var appState: AppState = .setup

    var body: some View {
        Group {
            switch appState {
            case .setup:
                SessionSetupView { sessionId, pipeline in
                    appState = .choosingCullMode(sessionId: sessionId, pipeline: pipeline)
                }

            case .choosingCullMode(let sessionId, let pipeline):
                CullChoiceView(
                    sessionId: sessionId,
                    onFilterThenRank: {
                        appState = .culling(sessionId: sessionId, pipeline: pipeline)
                    },
                    onRankOnly: {
                        appState = .comparing(sessionId: sessionId, pipeline: pipeline)
                    }
                )

            case .culling(let sessionId, let pipeline):
                CullView(
                    sessionId: sessionId,
                    pipeline: pipeline,
                    onComplete: {
                        appState = .comparing(sessionId: sessionId, pipeline: pipeline)
                    }
                )

            case .comparing(let sessionId, let pipeline):
                ComparisonView(
                    sessionId: sessionId,
                    pipeline: pipeline,
                    onSkipToResults: {
                        appState = .complete(sessionId: sessionId, totalComparisons: 0)
                    },
                    onComplete: { totalComparisons in
                        appState = .complete(sessionId: sessionId, totalComparisons: totalComparisons)
                    }
                )

            case .complete(let sessionId, let totalComparisons):
                CompletionView(
                    sessionId: sessionId,
                    totalComparisons: totalComparisons,
                    onSeeFullRankings: { photos in
                        appState = .results(sessionId: sessionId, previousComparisons: totalComparisons, initialPhotos: photos)
                    },
                    onStartOver: {
                        appState = .setup
                    }
                )

            case .results(let sessionId, let previousComparisons, let initialPhotos):
                ResultsView(
                    sessionId: sessionId,
                    onBack: previousComparisons.map { comps in
                        { appState = .complete(sessionId: sessionId, totalComparisons: comps) }
                    },
                    initialPhotos: initialPhotos
                )
            }
        }
        .background(Color.filmWhite.ignoresSafeArea())
        .tint(Color.amber)
        .animation(.screenTransition, value: appState)
    }
}

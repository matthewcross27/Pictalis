import SwiftUI

enum AppState {
    case setup
    case choosingCullMode(sessionId: UUID, pipeline: PhotoPipeline)
    case culling(sessionId: UUID, pipeline: PhotoPipeline)
    case comparing(sessionId: UUID, pipeline: PhotoPipeline)
    case complete(sessionId: UUID, totalComparisons: Int)
    case results(sessionId: UUID, previousComparisons: Int? = nil, initialPhotos: [RankedPhoto] = [])
}

struct ContentView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var api: APIClient

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
        .animation(.screenTransition, value: {
            switch appState {
            case .setup:              return 0
            case .choosingCullMode:   return 1
            case .culling:            return 2
            case .comparing:          return 3
            case .complete:           return 4
            case .results:            return 5
            }
        }())
    }
}

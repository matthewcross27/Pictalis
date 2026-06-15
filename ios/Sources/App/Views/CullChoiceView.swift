import SwiftUI

struct CullChoiceView: View {
    @EnvironmentObject private var api: APIClient

    let sessionId: UUID
    var onFilterThenRank: () -> Void
    var onRankOnly: () -> Void

    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.filmWhite.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 8) {
                    Text("How would you like to start?")
                        .font(.headlineSerif)
                        .foregroundStyle(Color.ink)
                        .padding(.bottom, 8)

                    choiceCard(
                        title: "Filter then rank",
                        subtitle: "Quickly drop photos that won't make the cut",
                        isLoading: isStarting
                    ) {
                        guard !isStarting else { return }
                        Task { await beginCull() }
                    }

                    choiceCard(
                        title: "Rank only",
                        subtitle: "Jump straight into comparisons",
                        isLoading: false
                    ) {
                        onRankOnly()
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.captionSerif)
                            .foregroundStyle(Color.amber)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func choiceCard(
        title: String,
        subtitle: String,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.titleSerif)
                        .foregroundStyle(Color.ink)
                    Text(subtitle)
                        .font(.captionSerif)
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                if isLoading {
                    ProgressView().tint(Color.amber)
                }
            }
            .padding(20)
            .background(Color.grainPaper)
            .cornerRadius(.interactiveRadius)
            .overlay(
                RoundedRectangle(cornerRadius: .interactiveRadius)
                    .stroke(Color.divider, lineWidth: 1)
            )
        }
        .disabled(isStarting)
    }

    private func beginCull() async {
        isStarting = true
        errorMessage = nil
        do {
            _ = try await api.startCull(sessionId: sessionId)
            onFilterThenRank()
        } catch {
            errorMessage = "Couldn't start — tap to try again."
            isStarting = false
        }
    }
}

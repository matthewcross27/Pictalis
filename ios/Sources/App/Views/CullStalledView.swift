import SwiftUI

// Shown when the filter deck has photos on disk but no card to show (see CullView's watchdog).
struct CullStalledView: View {
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Your photos are taking longer than expected to load.")
                .font(.captionSerif)
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Text("Try again")
                    .font(.labelSerif)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Color.amber)
                    .foregroundStyle(Color.filmWhite)
                    .clipShape(RoundedRectangle(cornerRadius: .interactiveRadius))
            }
        }
        .padding(.horizontal, 20)
    }
}

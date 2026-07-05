import SwiftUI

struct ComingSoonView: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        ZStack {
            Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.accentCyan.opacity(0.08))
                        .frame(width: 100, height: 100)
                    Image(systemName: icon)
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.accentCyan.opacity(0.6))
                }
                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.textPrimary)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Text("Coming soon")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentCyan)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.accentCyan.opacity(0.1))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.accentCyan.opacity(0.3), lineWidth: 0.5))
                Spacer()
                Spacer()
            }
        }
    }
}

import SwiftUI

struct PointsProgressView: View {
    @EnvironmentObject private var pointsStore: PointsStore

    var body: some View {
        ZStack {
            AgoraBackgroundView()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    progressCard
                    levelLadder
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 36)
            }
        }
        .navigationTitle("Your Training Arc")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgoraTag(text: "Agora Points")

            Text(pointsStore.currentLevel.title)
                .font(.custom("IowanOldStyle-Bold", size: 42))
                .foregroundColor(AgoraTheme.ink)

            Text(pointsStore.currentLevel.description)
                .font(AgoraTheme.subtitleFont)
                .foregroundColor(AgoraTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pointsStore.totalPoints)")
                            .font(.custom("AvenirNext-DemiBold", size: 46))
                            .foregroundColor(AgoraTheme.ink)
                        Text("TOTAL POINTS")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }

                    Spacer()

                    ZStack {
                        Circle()
                            .fill(AgoraTheme.accentGradient)
                            .frame(width: 68, height: 68)
                        Image(systemName: pointsStore.currentLevel.icon)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(AgoraTheme.ink.opacity(0.10))
                            Capsule()
                                .fill(AgoraTheme.accentGradient)
                                .frame(width: max(8, width * pointsStore.progressToNextLevel))
                        }
                    }
                    .frame(height: 14)

                    if let nextLevel = pointsStore.nextLevel {
                        let remaining = max(nextLevel.minimumPoints - pointsStore.totalPoints, 0)
                        Text("\(remaining) points to \(nextLevel.title)")
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                    } else {
                        Text("You have reached the highest level.")
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                    }
                }
            }
        }
    }

    private var levelLadder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The Levels")
                .font(AgoraTheme.cardTitleFont)
                .foregroundColor(AgoraTheme.ink)

            ForEach(PointsStore.levels) { level in
                levelRow(level)
            }
        }
    }

    private func levelRow(_ level: AgoraPointsLevel) -> some View {
        let achieved = pointsStore.totalPoints >= level.minimumPoints
        let current = pointsStore.currentLevel.id == level.id

        return AgoraCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(achieved ? AgoraTheme.accentGradient : LinearGradient(
                            colors: [AgoraTheme.ink.opacity(0.10), AgoraTheme.ink.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .frame(width: 46, height: 46)
                    Image(systemName: level.icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(achieved ? .white : AgoraTheme.inkMuted)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(level.title)
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                        if current {
                            AgoraTag(text: "Current")
                        }
                    }
                    Text(level.description)
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text("\(level.minimumPoints)")
                    .font(AgoraTheme.cardTitleFont)
                    .foregroundColor(achieved ? AgoraTheme.accent : AgoraTheme.inkMuted)
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationView {
        PointsProgressView()
            .environmentObject(PointsStore())
    }
}
#endif

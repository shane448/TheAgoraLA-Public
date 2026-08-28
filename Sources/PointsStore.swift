import Foundation

struct AgoraPointsLevel: Identifiable {
    let title: String
    let minimumPoints: Int
    let icon: String
    let description: String

    var id: Int { minimumPoints }
}

@MainActor
final class PointsStore: ObservableObject {
    @Published private(set) var totalPoints: Int
    let isEnabled = true

    private let storageKey = "TheAgoraLA.Points.OnDevice"

    static let levels = [
        AgoraPointsLevel(
            title: "Rookie",
            minimumPoints: 0,
            icon: "figure.walk",
            description: "Every great listener starts with one focused session."
        ),
        AgoraPointsLevel(
            title: "Contender",
            minimumPoints: 50,
            icon: "figure.run",
            description: "You are building the habit of showing up and staying curious."
        ),
        AgoraPointsLevel(
            title: "Athlete",
            minimumPoints: 150,
            icon: "figure.strengthtraining.traditional",
            description: "Your listening muscles are getting stronger with every answer."
        ),
        AgoraPointsLevel(
            title: "Champion",
            minimumPoints: 350,
            icon: "medal.fill",
            description: "You consistently engage with the ideas, not just the audio."
        ),
        AgoraPointsLevel(
            title: "Olympian",
            minimumPoints: 700,
            icon: "laurel.leading",
            description: "You are training a rare level of attention and recall."
        ),
        AgoraPointsLevel(
            title: "Legend",
            minimumPoints: 1_200,
            icon: "trophy.fill",
            description: "You have made thoughtful listening a serious practice."
        )
    ]

    init() {
        totalPoints = max(UserDefaults.standard.integer(forKey: storageKey), 0)
    }

    func add(points: Int) {
        guard points > 0 else { return }
        totalPoints += points
        UserDefaults.standard.set(totalPoints, forKey: storageKey)
    }

    func reset() {
        totalPoints = 0
        UserDefaults.standard.set(0, forKey: storageKey)
    }

    var currentLevel: AgoraPointsLevel {
        Self.levels.last(where: { totalPoints >= $0.minimumPoints }) ?? Self.levels[0]
    }

    var nextLevel: AgoraPointsLevel? {
        Self.levels.first(where: { $0.minimumPoints > totalPoints })
    }

    var progressToNextLevel: Double {
        guard let nextLevel else { return 1 }
        let span = max(nextLevel.minimumPoints - currentLevel.minimumPoints, 1)
        return min(max(Double(totalPoints - currentLevel.minimumPoints) / Double(span), 0), 1)
    }
}

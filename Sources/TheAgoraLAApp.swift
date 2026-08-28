import SwiftUI

@main
struct TheAgoraLAApp: App {
    @StateObject private var pointsStore = PointsStore()
    @StateObject private var episodeStore = EpisodeStore()
    @StateObject private var aiAccount = AIAccountStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pointsStore)
                .environmentObject(episodeStore)
                .environmentObject(aiAccount)
        }
    }
}

import SwiftUI

/// A visual accent tied to a podcast (not a single episode), so switching shows
/// re-tints the player while replaying the same show keeps a consistent look.
struct EpisodeAccent: Equatable {
    let primary: Color
    let secondary: Color

    var gradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [primary, secondary]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var glow: RadialGradient {
        RadialGradient(
            gradient: Gradient(colors: [primary.opacity(0.4), .clear]),
            center: .center,
            startRadius: 10,
            endRadius: 160
        )
    }

    static let standard = EpisodeAccent(
        primary: Color(red: 0.77, green: 0.55, blue: 0.24),
        secondary: Color(red: 0.74, green: 0.33, blue: 0.23)
    )

    private static let palette: [EpisodeAccent] = [
        standard,
        EpisodeAccent(
            primary: Color(red: 0.16, green: 0.30, blue: 0.55),
            secondary: Color(red: 0.24, green: 0.24, blue: 0.46)
        ),
        EpisodeAccent(
            primary: Color(red: 0.40, green: 0.46, blue: 0.30),
            secondary: Color(red: 0.55, green: 0.58, blue: 0.38)
        ),
        EpisodeAccent(
            primary: Color(red: 0.47, green: 0.23, blue: 0.36),
            secondary: Color(red: 0.60, green: 0.32, blue: 0.42)
        ),
        EpisodeAccent(
            primary: Color(red: 0.17, green: 0.42, blue: 0.44),
            secondary: Color(red: 0.32, green: 0.54, blue: 0.53)
        ),
        EpisodeAccent(
            primary: Color(red: 0.55, green: 0.42, blue: 0.18),
            secondary: Color(red: 0.42, green: 0.28, blue: 0.16)
        ),
    ]

    static func forEpisode(_ episode: Episode) -> EpisodeAccent {
        let key = episode.feedURL?.absoluteString
            ?? episode.sourceURL?.absoluteString
            ?? episode.title
        let index = Int(stableHash(key) % UInt64(palette.count))
        return palette[index]
    }

    // FNV-1a: Swift's String.hashValue is randomized per process, which would
    // give the same podcast a different look on every launch.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

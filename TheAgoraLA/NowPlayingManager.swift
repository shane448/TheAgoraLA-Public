import Foundation
import MediaPlayer

final class NowPlayingManager {
    static let shared = NowPlayingManager()
    private init() { configureRemoteCommands() }

    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var nowPlayingInfo: [String: Any] = [:]

    // Control hooks set by the app
    var playHandler: (() -> Void)?
    var pauseHandler: (() -> Void)?
    var skipForwardHandler: (() -> Void)?
    var skipBackwardHandler: (() -> Void)?
    var seekHandler: ((Double) -> Void)?

    func configure(title: String, duration: Double) {
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        infoCenter.nowPlayingInfo = nowPlayingInfo
    }

    func update(elapsed: Double, isPlaying: Bool, duration: Double?) {
        if let duration = duration, duration.isFinite {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        infoCenter.nowPlayingInfo = nowPlayingInfo
    }

    private func configureRemoteCommands() {
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.preferredIntervals = [15]

        commandCenter.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.playHandler?() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pauseHandler?() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                if let rate = self?.infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
                   rate > 0 {
                    self?.pauseHandler?()
                } else {
                    self?.playHandler?()
                }
            }
            return .success
        }
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skipForwardHandler?() }
            return .success
        }
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skipBackwardHandler?() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            DispatchQueue.main.async { self?.seekHandler?(event.positionTime) }
            return .success
        }
    }
}

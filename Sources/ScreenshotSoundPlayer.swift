import Foundation
import AVFoundation

/// Plays the bundled screenshot sound effect (single default sound).
///
/// The file lives at `Sources/Resources/screenshot-sound.mp3`.
final class ScreenshotSoundPlayer {
    private var player: AVAudioPlayer?
    private var playerURL: URL?
    private let fileManager: FileManager
    private let playerQueue = DispatchQueue(label: "Zoomies.ScreenshotSoundPlayer", qos: .userInitiated)

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prewarmCaptureSound() {
        playerQueue.async { [weak self] in
            _ = self?.preparePlayerIfNeeded()
        }
    }

    func playCaptureSound() {
        playerQueue.async { [weak self] in
            self?.playCaptureSoundOnQueue()
        }
    }

    private func playCaptureSoundOnQueue() {
        guard let player = preparePlayerIfNeeded() else {
            return
        }

        // Restart from the beginning for each capture.
        player.stop()
        player.currentTime = 0
        _ = player.play()
    }

    private func preparePlayerIfNeeded() -> AVAudioPlayer? {
        guard let url = BundledResourceLocator.resourceURL(
            named: "screenshot-sound",
            withExtension: "mp3",
            fileManager: fileManager
        ) else {
            return nil
        }

        do {
            if player == nil || playerURL != url {
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                playerURL = url
            }
            return player
        } catch {
            player = nil
            playerURL = nil
            return nil
        }
    }
}

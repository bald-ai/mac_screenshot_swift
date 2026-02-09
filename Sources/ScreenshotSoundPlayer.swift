import Foundation
import AVFoundation

/// Plays the bundled screenshot sound effect (single default sound).
///
/// The file lives at `Sources/Resources/screenshot-sound.mp3`.
final class ScreenshotSoundPlayer {
    private var player: AVAudioPlayer?
    private var playerURL: URL?

    func playCaptureSound() {
        // AVAudioPlayer is happier when managed from the main thread in AppKit apps.
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.playCaptureSound()
            }
            return
        }

        guard let url = Bundle.module.url(forResource: "screenshot-sound", withExtension: "mp3") else {
            Logger.shared.warning("ScreenshotSoundPlayer: Missing bundled resource screenshot-sound.mp3; capture sound not played")
            return
        }

        do {
            if player == nil || playerURL != url {
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                playerURL = url
                Logger.shared.info("ScreenshotSoundPlayer: Loaded capture sound: \(url.lastPathComponent)")
            }

            // Restart from the beginning for each capture.
            player?.stop()
            player?.currentTime = 0
            if player?.play() != true {
                Logger.shared.warning("ScreenshotSoundPlayer: Failed to play capture sound: \(url.lastPathComponent)")
            }
        } catch {
            Logger.shared.error("ScreenshotSoundPlayer: Failed to load/play mp3 at \(url): \(error)")
            player = nil
            playerURL = nil
        }
    }
}


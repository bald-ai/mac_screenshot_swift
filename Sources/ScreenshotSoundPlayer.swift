import Foundation
import AVFoundation

/// Plays the bundled screenshot sound effect (single default sound).
///
/// The file lives at `Sources/Resources/screenshot-sound.mp3`.
final class ScreenshotSoundPlayer {
    private var player: AVAudioPlayer?
    private var playerURL: URL?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func playCaptureSound() {
        // AVAudioPlayer is happier when managed from the main thread in AppKit apps.
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.playCaptureSound()
            }
            return
        }

        guard let url = BundledResourceLocator.resourceURL(
            named: "screenshot-sound",
            withExtension: "mp3",
            fileManager: fileManager
        ) else {
            AppLogger.error("Screenshot sound resource not found")
            return
        }

        do {
            if player == nil || playerURL != url {
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                playerURL = url
            }

            // Restart from the beginning for each capture.
            player?.stop()
            player?.currentTime = 0
            if player?.play() != true {
                AppLogger.error("Failed to play screenshot sound")
            }
        } catch {
            player = nil
            playerURL = nil
            AppLogger.error("Failed initializing screenshot sound player", error: error)
        }
    }
}

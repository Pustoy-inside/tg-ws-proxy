import Foundation
import CoreLocation
import AVFoundation
import UIKit

/// Keeps the app running in the background so the proxy keeps serving
/// Telegram. A free Apple ID can't sign a VPN module, so we use one of the
/// background modes iOS allows without special entitlements.
enum KeepAliveMode: String, CaseIterable, Identifiable {
    case location
    case audio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .location: return "Геолокация"
        case .audio: return "Тихий звук"
        }
    }
}

final class KeepAlive: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var mode: KeepAliveMode?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    var onAuthorizationProblem: ((String?) -> Void)?

    override init() {
        super.init()
        location.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func start(_ m: KeepAliveMode) {
        stop()
        mode = m
        switch m {
        case .location: startLocation()
        case .audio: startAudio()
        }
        plog.info("Keep-alive: \(m.rawValue)")
    }

    func stop() {
        mode = nil
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        stopAudio()
        endBackgroundTask()
    }

    // MARK: Location

    private func startLocation() {
        // Coarse accuracy: the fix itself isn't used, it only keeps the app alive.
        location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        location.distanceFilter = 3000
        location.pausesLocationUpdatesAutomatically = false
        location.activityType = .other
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            onAuthorizationProblem?("Нет доступа к геолокации: разреши его в Настройках iOS или выбери «Тихий звук».")
        default:
            beginLocationUpdates()
        }
    }

    private func beginLocationUpdates() {
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        onAuthorizationProblem?(nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard mode == .location else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginLocationUpdates()
        case .denied, .restricted:
            onAuthorizationProblem?("Нет доступа к геолокации: разреши его в Настройках iOS или выбери «Тихий звук».")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        plog.debug("Location: \(error.localizedDescription)")
    }

    // MARK: Silent audio

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Mixes with other audio, so Telegram's voice and video still play.
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100 // zero-filled: silence
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
        } catch {
            plog.error("Silent audio failed: \(error.localizedDescription)")
            onAuthorizationProblem?("Не удалось запустить тихий звук: \(error.localizedDescription)")
        }
    }

    private func stopAudio() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @objc private func audioInterrupted(_ n: Notification) {
        guard mode == .audio,
              let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        plog.info("Audio interruption ended, restarting silent audio")
        stopAudio()
        startAudio()
    }

    // A short grace period while the chosen mode takes over.
    @objc private func didEnterBackground() {
        guard mode != nil else { return }
        endBackgroundTask()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "proxy") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}

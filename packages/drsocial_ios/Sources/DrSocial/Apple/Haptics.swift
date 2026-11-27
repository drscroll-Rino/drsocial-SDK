#if os(iOS)
import CoreHaptics
import UIKit

/// Plays a notification's `drs_vibe` pattern with Core Haptics while the app is open (Apple allows no custom pattern for
/// the notification itself). A phone without Core Haptics gets one plain notification tap instead.
public enum DrSocialHaptics {
    private static var engine: CHHapticEngine?

    public static func play(_ push: DrsPush) {
        guard let ms = push.vibrationMs else { return }
        play(ms: ms)
    }

    public static func play(ms: [Int]) {
        let buzzes = PushVibration.buzzes(ms)
        guard !buzzes.isEmpty else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            DispatchQueue.main.async { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            return
        }
        do {
            if engine == nil {
                engine = try CHHapticEngine()
                engine?.isAutoShutdownEnabled = true
            }
            try engine?.start()
            let events = buzzes.map {
                CHHapticEvent(eventType: .hapticContinuous,
                              parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                           CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                              relativeTime: $0.start, duration: $0.duration)
            }
            let player = try engine?.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            DispatchQueue.main.async { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }
}
#endif

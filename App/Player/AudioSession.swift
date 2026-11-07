import AVFoundation

enum AudioSession {
    @discardableResult
    static func configure(activate shouldActivate: Bool = true) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            return !shouldActivate || activate()
        } catch { return false }
    }

    @discardableResult
    static func activate() -> Bool {
        do { try AVAudioSession.sharedInstance().setActive(true); return true }
        catch { return false }
    }
}

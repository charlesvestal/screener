// One owner of the app's AVAudioSession activation.
//
// Two parts of the app need the shared session active: the Mac's audio
// (AudioPlayer, while it plays) and Picture in Picture (PiPController, while
// a session is up — PiP needs an active `.playback` session, with or without
// sound). Each claims it under its own name; the session is activated
// (`.playback`, `.mixWithOthers`, so the user's own music keeps playing) on
// any claim and deactivated only when the last claim goes, so muting the
// Mac's audio no longer pulls the session out from under PiP.
import AVFoundation
import Foundation

final class AudioSessionArbiter: @unchecked Sendable {   // state behind `lock`
    enum Owner: Hashable, Sendable { case remoteAudio, pictureInPicture }

    static let shared = AudioSessionArbiter()

    /// Injection point for tests (the real AVAudioSession otherwise).
    struct Backend: Sendable {
        var activate: @Sendable () throws -> Void
        var deactivate: @Sendable () throws -> Void

        static let live = Backend(
            activate: {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            },
            deactivate: {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            })
    }

    private let lock = NSLock()
    private var owners: Set<Owner> = []
    private let backend: Backend

    init(backend: Backend = .live) { self.backend = backend }

    var claims: Set<Owner> { lock.withLock { owners } }

    /// Claims the session for `owner` and (re)activates it. Activation is
    /// repeated on every call, so a claim after an interruption reactivates.
    func acquire(_ owner: Owner) {
        do {
            try lock.withLock {
                owners.insert(owner)
                try backend.activate()
            }
        } catch {
            Log.audio.error("audio session activate (\(String(describing: owner))) failed: \(error)")
        }
    }

    /// Like `acquire`, but rethrows (AudioPlayer retries on failure).
    func acquireOrThrow(_ owner: Owner) throws {
        try lock.withLock {
            try backend.activate()
            owners.insert(owner)
        }
    }

    /// Drops `owner`'s claim; the session is deactivated when none is left.
    func release(_ owner: Owner) {
        do {
            try lock.withLock {
                guard owners.remove(owner) != nil, owners.isEmpty else { return }
                try backend.deactivate()
            }
        } catch {
            Log.audio.error("audio session deactivate failed: \(error)")
        }
    }
}

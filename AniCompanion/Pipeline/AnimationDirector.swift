import Foundation

// MARK: - AnimationDirector
//
// Orchestrates *when she moves*: the trigger layer for the full animation set
// (`docs/animations.md`, 26 clips — Mixamo-derived, delivered incrementally).
// Rules:
//   - Emotion-sentence animations fire only for expressive emotions AND when the
//     emotion actually changed (a run of [happy] sentences keeps the talk gesture)
//   - Per-clip cooldown (20s) so consecutive emotional lines don't flap the body
//   - Missing clips degrade silently — animations can be delivered piecemeal;
//     each candidate list falls through to the next available entry
//   - Server-pushed animations (touch/reaction lines) only check availability:
//     the companion layer already rate-limits upstream

@MainActor
final class AnimationDirector: Sendable {

    /// Fire-and-forget player (wired to `ThreeVRMCharacterManager.playAnimation`).
    private let player: (String) -> Void
    /// Names of the clips actually loaded from Resources/Animations/.
    private let availableClips: () -> Set<String>
    private var lastPlayedAt: [String: Date] = [:]
    private var lastEmotionAnimation: String?

    static let cooldown: TimeInterval = 20

    init(player: @escaping (String) -> Void, availableClips: @escaping () -> Set<String>) {
        self.player = player
        self.availableClips = availableClips
    }

    // Emotion → candidate clips, most preferred first (see docs/animations.md §C/§D).
    private static let emotionAnimations: [Emotion: [String]] = [
        .excited: ["happy_jump", "happy_clap"],
        .laugh: ["laugh_body", "happy_clap"],
        .shy: ["shy_cover"],
        .sad: ["sad_down"],
        .angry: ["angry_stomp", "head_shake"],
        .surprised: ["surprised_step_back"],
        .curious: ["curious_look"],
        .sleepy: ["sleepy_yawn"],
        .proud: ["proud_pose", "bow_thanks"],
        .love: ["blow_kiss"],
        .smirk: ["head_shake", "shrug"],
        .bored: ["idle_arms_crossed", "shrug"],
        // neutral / happy / pain / disgusted: no dedicated clip — the talk gesture
        // or facial expression carries them.
    ]

    /// Only these emotions get a body animation mid-speech.
    private static let expressiveEmotions: Set<Emotion> = Set(emotionAnimations.keys)

    // MARK: - Triggers

    /// A spoken sentence carrying `emotion` (from SentenceParser). Conservative:
    /// expressive emotions only, must differ from the previous one, respects cooldown.
    func playEmotion(_ emotion: Emotion) {
        guard Self.expressiveEmotions.contains(emotion),
              let candidates = Self.emotionAnimations[emotion] else { return }
        guard let picked = pick(candidates),
              picked != lastEmotionAnimation,
              !withinCooldown(picked) else { return }
        lastEmotionAnimation = picked
        play(picked)
    }

    /// The speaking gesture at the start of a reply — randomized across the pool
    /// so long answers don't always look identical.
    func playTalkGesture() {
        playFirstAvailable(["talk_expressive", "talk_gesture"])
    }

    /// Idle-variant pool for the inactivity timeout (called by the character manager).
    /// Returns nil when every variant is on cooldown or missing — caller keeps `idle`.
    func nextIdleVariant() -> String? {
        let pool = ["idle_stretch", "idle_arms_crossed", "idle_hands_behind", "curious_look"]
        return pick(pool.filter { !withinCooldown($0) })
    }

    /// Animation pushed by the companion layer alongside a say line (touch/reaction
    /// reactions). Availability check only — upstream already rate-limits.
    func playServer(_ name: String) {
        guard availableClips().contains(name) else { return }
        play(name)
    }

    // MARK: - Helpers

    private func playFirstAvailable(_ candidates: [String]) {
        if let first = pick(candidates) {
            play(first)
        }
    }

    /// First available candidate, or nil (missing clips degrade silently).
    private func pick(_ candidates: [String]) -> String? {
        candidates.first { availableClips().contains($0) }
    }

    private func withinCooldown(_ name: String) -> Bool {
        guard let last = lastPlayedAt[name] else { return false }
        return Date().timeIntervalSince(last) < Self.cooldown
    }

    private func play(_ name: String) {
        lastPlayedAt[name] = Date()
        player(name)
    }
}

import SwiftUI

/// The animation shown between sending and the first token.
///
/// A local model can take long enough to wonder whether anything happened at
/// all, and a spinner only says "the machine is busy". A cat says "the machine
/// is *thinking*", which is both warmer and more honest about what is actually
/// going on inside.
///
/// The set is chosen once per view instance, so a fresh run gets a fresh
/// animation. That is not decoration for its own sake: an animation you have
/// seen forty times stops being a signal and becomes wallpaper, and the whole
/// point is that it is over there and something is happening here.
///
/// Frames are ASCII rather than emoji for a boring reason — the Simulator has no
/// colour emoji font (see docs/SIMULATOR.md) — and monospaced so a frame change
/// does not reflow the line.
struct ThinkingAnimation: View {
    private let frames: [String]
    private let interval: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(runID: String? = nil) {
        let set = Self.pick(seed: runID)
        frames = set.frames
        interval = set.interval
    }

    var body: some View {
        if reduceMotion {
            // Motion that conveys "still working" has to survive being turned
            // off, so the words stay.
            Label("Thinking…", systemImage: "ellipsis")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            // TimelineView rather than a Timer: no state to invalidate, no
            // subscription to leak when the view disappears mid-stream, and it
            // stops ticking on its own when the answer starts arriving.
            TimelineView(.periodic(from: .now, by: interval)) { context in
                let frame = Int(context.date.timeIntervalSinceReferenceDate / interval) % frames.count
                Text(frames[frame])
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Thinking")
        }
    }

    struct Frames {
        let name: String
        let interval: TimeInterval
        let frames: [String]

        /// Pads every line to the widest line in the set.
        ///
        /// A frame one character wider than the last moves whatever text sits
        /// beside it, which reads as a stutter rather than an animation. Padding
        /// the data beats fixing it up in the view, because then the frames the
        /// test checks are the frames that render.
        init(name: String, interval: TimeInterval, frames: [String]) {
            let width = frames.flatMap { $0.components(separatedBy: "\n") }.map(\.count).max() ?? 0
            self.name = name
            self.interval = interval
            self.frames = frames.map { frame in
                frame.components(separatedBy: "\n").map { line in
                    line + String(repeating: " ", count: max(0, width - line.count))
                }.joined(separator: "\n")
            }
        }
    }

    /// Picked per run. A seed makes the choice reproducible in tests without
    /// making every run identical in the app.
    static func pick(seed: String?) -> Frames {
        guard let seed else { return sets.randomElement()! }
        var hash = 5381
        for byte in seed.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        return sets[abs(hash) % sets.count]
    }

    // Every frame in a set is padded to the same width, because a Text that
    // changes width mid-animation moves the text that follows it.
    static let sets: [Frames] = [
        Frames(
            name: "blink", interval: 0.42,
            frames: [
                """
                 /\\_/\\
                ( o.o )
                 > ^ <
                """,
                """
                 /\\_/\\
                ( o.o )
                 > ^ <~
                """,
                """
                 /\\_/\\
                ( -.- )
                 > ^ <~
                """,
                """
                 /\\_/\\
                ( o.o )
                 > ^ <
                """,
            ]),
        Frames(
            name: "pounce", interval: 0.2,
            frames: [
                """
                 /\\_/\\
                ( o.o )
                 > ^ <
                """,
                """
                 /\\_/\\
                ( o.o )  ~
                 > ^ <
                """,
                """
                (\\_/)
                (o.o)
                 > ^
                """,
                """
                 /\\_/\\
                ( o.o )  ~
                 > ^ <
                """,
            ]),
        Frames(
            name: "bat", interval: 0.16,
            frames: [
                """
                 /\\_/\\   o
                ( o.o )
                 > ^ <
                """,
                """
                 /\\_/\\  o
                ( o.o )
                 > ^ <
                """,
                """
                 /\\_/\\ o
                ( o.o )
                 > ^ <
                """,
                """
                 /\\_/\\  o
                ( o.o )
                 > ^ <
                """,
            ]),
        Frames(
            name: "spinner", interval: 0.12,
            frames: [
                "[ - ] thinking",
                "[ \\ ] thinking",
                "[ | ] thinking",
                "[ / ] thinking",
            ]),
    ]
}

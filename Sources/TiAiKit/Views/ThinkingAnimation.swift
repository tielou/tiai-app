import SwiftUI

/// The animation shown between sending and the first token.
///
/// A local model can take long enough that you wonder whether anything happened
/// at all, and a spinner only says "the machine is busy". A cat says "the machine
/// is *thinking*", which is warmer and closer to the truth.
///
/// Drawn rather than an animated GIF on purpose: a vector cat follows the colour
/// scheme and the accent, stays crisp at every size and density, and costs the
/// bundle nothing. A GIF would have shipped a fixed-size bitmap with a fixed
/// background colour, which is exactly the thing that looks wrong in dark mode.
///
/// The pose is picked once per run. An animation you have seen forty times stops
/// being a signal and becomes wallpaper, so the variation is functional: it is
/// the thing that tells you *this* run is working, over there.
struct ThinkingAnimation: View {
    private enum Pose: Int, CaseIterable {
        case typing, blink, chase, pounce
    }

    /// Which pose a run gets, in order of how much of it you should see.
    ///
    /// Typing is the signature - a cat at a keyboard is the joke, and the one
    /// people recognise as "it is working on my thing" - so it appears twice in
    /// the wheel and the idle poses fill the rest.
    private static let wheel: [Pose] = [.typing, .typing, .typing, .blink, .chase, .pounce]

    private let pose: Pose
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(runID: String? = nil) {
        pose = Self.wheel[Self.poseIndex(for: runID ?? UUID().uuidString)]
    }

    /// Which pose a run gets.
    ///
    /// Deterministic per run id so re-rendering the same turn does not shuffle
    /// the animation mid-flight, and spread across ids so consecutive runs do
    /// not all look the same. `UInt(bitPattern:)` rather than `abs()` because
    /// `abs(Int.min)` traps and a hash is exactly where that value turns up.
    /// Slots in the selection wheel, and how many distinct poses it holds —
    /// they differ, because typing is weighted to appear more often.
    static var poseSlotCount: Int { wheel.count }
    static var distinctPoseCount: Int { Pose.allCases.count }

    /// Which pose a run id gets, as a name a test can compare.
    static func poseName(for runID: String) -> String {
        String(describing: wheel[poseIndex(for: runID)])
    }

    static func poseIndex(for runID: String) -> Int {
        var hasher = Hasher()
        hasher.combine(runID)
        return Int(UInt(bitPattern: hasher.finalize()) % UInt(wheel.count))
    }

    var body: some View {
        // Reduce Motion is about large movement across the screen, not about a
        // small figure in a line of text — and hiding the cat entirely meant
        // most people never saw it, because plenty of people leave Reduce Motion
        // on for unrelated reasons. So it stays, slowed down.
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.4 : 1.0 / 24.0)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate * (reduceMotion ? 0.3 : 1)
                if pose == .typing { drawTyping(&ctx, size: size, t: t) }
                else { draw(&ctx, size: size, t: t) }
            }
            .frame(width: pose == .typing ? 118 : 96, height: pose == .typing ? 36 : 26)
        }
        .accessibilityLabel("Thinking")
    }

    // MARK: - drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let ink = Color.secondary
        let r = size.height * 0.30
        let bob: CGFloat = pose == .pounce ? CGFloat(sin(t * 3.4)) * 2.2 : 0
        let centre = CGPoint(x: size.height * 0.55, y: size.height * 0.58 + bob)

        drawEars(&ctx, centre: centre, r: r, ink: ink, t: t)
        ctx.fill(
            Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
            with: .color(ink.opacity(0.85)))
        drawEyes(&ctx, centre: centre, r: r, t: t)

        // A tail that sweeps, so there is movement even when the eyes are open.
        var tail = Path()
        let sway = CGFloat(sin(t * 2.1)) * r * 0.9
        tail.move(to: CGPoint(x: centre.x + r * 0.85, y: centre.y + r * 0.55))
        tail.addQuadCurve(
            to: CGPoint(x: centre.x + r * 1.9, y: centre.y - r * 0.35 + sway),
            control: CGPoint(x: centre.x + r * 1.9, y: centre.y + r * 0.9))
        ctx.stroke(tail, with: .color(ink.opacity(0.85)),
                   style: StrokeStyle(lineWidth: r * 0.30, lineCap: .round))

        drawDots(&ctx, size: size, ink: ink, t: t)
    }

    private func drawEars(_ ctx: inout GraphicsContext, centre: CGPoint, r: CGFloat,
                          ink: Color, t: Double) {
        // One ear twitches now and then; two static ears read as a logo.
        let twitch: CGFloat = pose == .chase ? CGFloat(max(0, sin(t * 1.7))) * -r * 0.18 : 0
        for side in [-1.0, 1.0] {
            let base = CGPoint(x: centre.x + CGFloat(side) * r * 0.55, y: centre.y - r * 0.62)
            let tip = CGPoint(x: centre.x + CGFloat(side) * r * 0.92,
                              y: centre.y - r * 1.55 + (side < 0 ? twitch : 0))
            let inner = CGPoint(x: centre.x + CGFloat(side) * r * 0.05, y: centre.y - r * 0.95)
            var ear = Path()
            ear.move(to: base)
            ear.addLine(to: tip)
            ear.addLine(to: inner)
            ear.closeSubpath()
            ctx.fill(ear, with: .color(ink.opacity(0.85)))
        }
    }

    private func drawEyes(_ ctx: inout GraphicsContext, centre: CGPoint, r: CGFloat, t: Double,
                          downward: Bool = false) {
        // Blink roughly every three seconds, and close over two frames rather
        // than snapping, so it reads as a blink and not a glitch.
        let cycle = t.truncatingRemainder(dividingBy: 3.0)
        let open: CGFloat
        switch cycle {
        case 2.5..<2.6: open = 0.35
        case 2.6..<2.7: open = 0.1
        default: open = 1.0
        }
        let eyeR = r * 0.17
        for side in [-1.0, 1.0] {
            let x = centre.x + CGFloat(side) * r * 0.38
            let rect = CGRect(
                x: x - eyeR, y: centre.y - eyeR * open + (downward ? r * 0.22 : -r * 0.05),
                width: eyeR * 2, height: eyeR * 2 * open)
            if open < 0.2 {
                // A closed eye is a line; a squashed ellipse disappears at this size.
                var lid = Path()
                let lidY = centre.y + (downward ? r * 0.22 : -r * 0.05)
                lid.move(to: CGPoint(x: x - eyeR, y: lidY))
                lid.addLine(to: CGPoint(x: x + eyeR, y: lidY))
                ctx.stroke(lid, with: .color(.primary),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            } else {
                ctx.fill(Path(ellipseIn: rect), with: .color(.primary))
            }
        }
    }

    /// Three dots that light up in sequence — the part that actually reads as
    /// "still working" when the cat is small enough to ignore.
    private func drawDots(_ ctx: inout GraphicsContext, size: CGSize, ink: Color, t: Double) {
        let dot = size.height * 0.11
        let left = size.height * 1.35
        for index in 0..<3 {
            let phase = (t * 2.2 - Double(index) * 0.35)
            let lift = CGFloat(sin(phase)) * size.height * 0.10
            let alpha = 0.35 + 0.45 * (0.5 + 0.5 * sin(phase))
            let x = left + CGFloat(index) * dot * 3.1
            ctx.fill(
                Path(ellipseIn: CGRect(x: x, y: size.height * 0.52 + lift,
                                       width: dot * 2, height: dot * 2)),
                with: .color(ink.opacity(alpha)))
        }
    }

    // MARK: - the one at the keyboard

    /// A cat typing on a laptop, after the gif everyone means: shoulders and
    /// head above the lid, both paws over the keys alternately, and fast enough
    /// that it reads as typing rather than idling.
    ///
    /// Drawn rather than the gif itself, for the same reason as the others: it
    /// takes the colour scheme, stays crisp at 3x, and does not arrive with a
    /// photograph of someone's kitchen glued behind it.
    private func drawTyping(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let ink = Color.secondary
        let dark = ink.opacity(0.85)
        let head = CGPoint(x: 30, y: 10)
        let r: CGFloat = 8

        // Shoulders behind the lid, so the cat is sitting at the machine and not
        // floating above it.
        // Shoulders only: the lid hides the rest, and a body that spills below it
        // turns the cat into a blob sitting on the desk.
        var body = Path()
        body.move(to: CGPoint(x: head.x - r * 1.05, y: 20))
        body.addQuadCurve(
            to: CGPoint(x: head.x + r * 1.05, y: 20),
            control: CGPoint(x: head.x, y: 7))
        ctx.fill(body, with: .color(dark))

        // The lid, seen from behind: a slab leaning back over the keyboard.
        var lid = Path()
        lid.move(to: CGPoint(x: 13, y: 27))
        lid.addLine(to: CGPoint(x: 49, y: 27))
        lid.addLine(to: CGPoint(x: 46, y: 17))
        lid.addLine(to: CGPoint(x: 16, y: 17))
        lid.closeSubpath()
        ctx.fill(lid, with: .color(ink.opacity(0.35)))
        ctx.stroke(lid, with: .color(ink.opacity(0.6)), lineWidth: 0.8)

        // Keyboard deck, drawn as a parallelogram so it has some depth.
        var deck = Path()
        deck.move(to: CGPoint(x: 9, y: 27))
        deck.addLine(to: CGPoint(x: 53, y: 27))
        deck.addLine(to: CGPoint(x: 58, y: 32))
        deck.addLine(to: CGPoint(x: 4, y: 32))
        deck.closeSubpath()
        ctx.fill(deck, with: .color(ink.opacity(0.55)))

        // Paws over the front of the lid, alternating at roughly three taps a
        // second. Never both down at once: that reads as a still image.
        let tap = sin(t * 16.0)
        for (side, phase) in [(-1.0, tap), (1.0, -tap)] {
            let x = head.x + CGFloat(side) * r * 0.62
            let down = max(0, CGFloat(phase))
            let y = 25.5 - (1 - down) * 3.0
            ctx.fill(
                Path(roundedRect: CGRect(x: x - 3, y: y, width: 6, height: 4.6),
                     cornerRadius: 2.3),
                with: .color(dark))
            // The key being struck lights for one frame.
            if down > 0.85 {
                ctx.fill(
                    Path(roundedRect: CGRect(x: x - 2.4, y: 29.6, width: 4.8, height: 1.4),
                         cornerRadius: 0.7),
                    with: .color(.primary.opacity(0.5)))
            }
        }

        drawEars(&ctx, centre: head, r: r, ink: ink, t: t)
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)),
                 with: .color(dark))
        drawEyes(&ctx, centre: head, r: r, t: t, downward: true)

        // Output marching up the side — the part that says something is being
        // produced rather than time merely passing.
        for index in 0..<3 {
            let phase = (t * 2.4 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1.5)
            let y = 8 + CGFloat(index) * 6 - CGFloat(phase) * 2
            let width: CGFloat = [22, 16, 26][index]
            ctx.fill(
                Path(roundedRect: CGRect(x: 70, y: y, width: width, height: 2), cornerRadius: 1),
                with: .color(.primary.opacity(0.22)))
        }
    }
}

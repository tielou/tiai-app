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
        case blink, chase, pounce
    }

    private let pose: Pose
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(runID: String? = nil) {
        pose = Pose.allCases[Self.poseIndex(for: runID ?? UUID().uuidString)]
    }

    /// Which pose a run gets.
    ///
    /// Deterministic per run id so re-rendering the same turn does not shuffle
    /// the animation mid-flight, and spread across ids so consecutive runs do
    /// not all look the same. `UInt(bitPattern:)` rather than `abs()` because
    /// `abs(Int.min)` traps and a hash is exactly where that value turns up.
    static func poseIndex(for runID: String) -> Int {
        var hasher = Hasher()
        hasher.combine(runID)
        return Int(UInt(bitPattern: hasher.finalize()) % UInt(Pose.allCases.count))
    }

    var body: some View {
        // Reduce Motion is about large movement across the screen, not about a
        // small figure in a line of text — and hiding the cat entirely meant
        // most people never saw it, because plenty of people leave Reduce Motion
        // on for unrelated reasons. So it stays, slowed down.
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.4 : 1.0 / 15.0)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate * (reduceMotion ? 0.3 : 1)
                draw(&ctx, size: size, t: t)
            }
            .frame(width: 96, height: 26)
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

    private func drawEyes(_ ctx: inout GraphicsContext, centre: CGPoint, r: CGFloat, t: Double) {
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
                x: x - eyeR, y: centre.y - eyeR * open - r * 0.05,
                width: eyeR * 2, height: eyeR * 2 * open)
            if open < 0.2 {
                // A closed eye is a line; a squashed ellipse disappears at this size.
                var lid = Path()
                lid.move(to: CGPoint(x: x - eyeR, y: centre.y - r * 0.05))
                lid.addLine(to: CGPoint(x: x + eyeR, y: centre.y - r * 0.05))
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
}

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
    /// Typing is the signature — a cat at a keyboard is the joke, and the one
    /// people recognise as "it is working on my thing" — so it appears twice in
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
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.4 : 1.0 / 30.0)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate * (reduceMotion ? 0.3 : 1)
                if pose == .typing { drawTyping(&ctx, size: size, t: t) }
                else { drawSit(&ctx, size: size, t: t) }
            }
            .frame(width: pose == .typing ? 124 : 104, height: pose == .typing ? 40 : 30)
        }
        .accessibilityLabel("Thinking")
    }

    // MARK: - palette

    /// Fur, features, and the pink bits, all derived from the scheme so the cat
    /// is a grey cat in light mode and a grey cat in dark mode, never a black
    /// silhouette glued onto a white background.
    private struct Ink {
        let fur: Color
        let dark: Color
        let feature: Color
        let pink: Color
        static func make() -> Ink {
            Ink(fur: Color.secondary.opacity(0.85),
                dark: Color.secondary,
                feature: Color.primary.opacity(0.9),
                pink: Color.pink.opacity(0.55))
        }
    }

    // MARK: - sitting cat

    /// A cat sitting and waiting: full face, tail curling, occasional blink and
    /// ear twitch. The face is the point — a head with two dots for eyes reads
    /// as a circle with punctures, not as an animal.
    private func drawSit(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let ink = Ink.make()
        let r = size.height * 0.30
        let bob: CGFloat = pose == .pounce ? CGFloat(sin(t * 3.1)) * 1.8 : CGFloat(sin(t * 1.3)) * 0.5
        let head = CGPoint(x: size.height * 0.62, y: size.height * 0.52 + bob)

        drawTail(&ctx, from: CGPoint(x: head.x + r * 0.9, y: head.y + r * 1.5),
                 r: r, ink: ink, t: t)
        // Body: a rounded loaf under the head, so it is a cat and not a floating
        // disc. Squashed wider at the bottom, which is how a sitting cat reads.
        var body = Path()
        let bx = head.x, by = head.y + r * 0.9
        body.move(to: CGPoint(x: bx - r * 0.95, y: by + r * 1.15))
        body.addQuadCurve(to: CGPoint(x: bx + r * 0.95, y: by + r * 1.15),
                          control: CGPoint(x: bx, y: by - r * 0.75))
        body.closeSubpath()
        ctx.fill(body, with: .color(ink.fur))
        // Two front paws at the base of the loaf.
        for side in [-1.0, 1.0] {
            ctx.fill(
                Path(roundedRect: CGRect(x: bx + CGFloat(side) * r * 0.52 - r * 0.26,
                                         y: by + r * 0.82, width: r * 0.52, height: r * 0.36),
                     cornerRadius: r * 0.18),
                with: .color(ink.dark.opacity(0.75)))
        }

        drawHead(&ctx, centre: head, r: r, ink: ink, t: t, gaze: .forward)
        drawDots(&ctx, size: size, ink: ink, t: t, left: size.height * 1.55)
    }

    // MARK: - the one at the keyboard

    /// A cat typing on a laptop, after the gif everyone means: head and
    /// shoulders above the lid, both paws over the keys alternately, tail up
    /// and flicking, eyes fixed downward on the screen it cannot see.
    ///
    /// Drawn rather than the gif itself, for the same reason as the others: it
    /// takes the colour scheme, stays crisp at 3x, and does not arrive with a
    /// photograph of someone's kitchen glued behind it.
    private func drawTyping(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let ink = Ink.make()
        let r: CGFloat = 9.5
        let head = CGPoint(x: 32, y: 13)

        drawTail(&ctx, from: CGPoint(x: head.x + r * 1.0, y: 26), r: r, ink: ink, t: t, upright: true)

        // Shoulders behind the lid.
        var body = Path()
        body.move(to: CGPoint(x: head.x - r * 1.15, y: 26))
        body.addQuadCurve(to: CGPoint(x: head.x + r * 1.15, y: 26),
                          control: CGPoint(x: head.x, y: 9))
        ctx.fill(body, with: .color(ink.fur))

        // Lid, seen from behind: a slab leaning back over the keyboard.
        var lid = Path()
        lid.move(to: CGPoint(x: 14, y: 30))
        lid.addLine(to: CGPoint(x: 52, y: 30))
        lid.addLine(to: CGPoint(x: 49, y: 20))
        lid.addLine(to: CGPoint(x: 17, y: 20))
        lid.closeSubpath()
        ctx.fill(lid, with: .color(ink.dark.opacity(0.28)))
        ctx.stroke(lid, with: .color(ink.dark.opacity(0.55)), lineWidth: 0.8)

        // Keyboard deck, a parallelogram so it has some depth.
        var deck = Path()
        deck.move(to: CGPoint(x: 10, y: 30))
        deck.addLine(to: CGPoint(x: 56, y: 30))
        deck.addLine(to: CGPoint(x: 61, y: 36))
        deck.addLine(to: CGPoint(x: 5, y: 36))
        deck.closeSubpath()
        ctx.fill(deck, with: .color(ink.dark.opacity(0.45)))

        // Paws on the front of the lid, alternating at roughly three taps a
        // second. Never both down at once: that reads as a still image.
        let tap = sin(t * 15.0)
        for (side, phase) in [(-1.0, tap), (1.0, -tap)] {
            let x = head.x + CGFloat(side) * r * 0.60
            let down = max(0, CGFloat(phase))
            let y = 28.2 - (1 - down) * 3.2
            ctx.fill(
                Path(roundedRect: CGRect(x: x - 3.4, y: y, width: 6.8, height: 5),
                     cornerRadius: 2.5),
                with: .color(ink.dark.opacity(0.9)))
            // Toes on the paw, faint, so it is a paw and not a pill.
            for toe in -1...1 {
                ctx.fill(
                    Path(roundedRect: CGRect(x: x + CGFloat(toe) * 1.9 - 0.45, y: y + 3.1,
                                             width: 0.9, height: 1.5), cornerRadius: 0.45),
                    with: .color(ink.fur.opacity(0.9)))
            }
            if down > 0.85 {
                ctx.fill(
                    Path(roundedRect: CGRect(x: x - 2.6, y: 32.8, width: 5.2, height: 1.5),
                         cornerRadius: 0.75),
                    with: .color(.primary.opacity(0.45)))
            }
        }

        drawHead(&ctx, centre: head, r: r, ink: ink, t: t, gaze: .down)

        // Output marching up the side — the part that says something is being
        // produced rather than time merely passing.
        for index in 0..<3 {
            let phase = (t * 2.4 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1.5)
            let y = 9 + CGFloat(index) * 7 - CGFloat(phase) * 2
            let width: CGFloat = [24, 17, 28][index]
            ctx.fill(
                Path(roundedRect: CGRect(x: 76, y: y, width: width, height: 2.2), cornerRadius: 1.1),
                with: .color(.primary.opacity(0.22)))
        }
    }

    // MARK: - parts

    private enum Gaze { case forward, down }

    /// Head, ears and face in one place, because every pose needs the same cat
    /// and two copies of a face is how the two poses stop looking related.
    private func drawHead(_ ctx: inout GraphicsContext, centre: CGPoint, r: CGFloat,
                          ink: Ink, t: Double, gaze: Gaze) {
        // One ear twitches now and then; two static ears read as a logo.
        let twitch: CGFloat = pose == .chase ? CGFloat(max(0, sin(t * 1.6))) * -r * 0.22 : 0
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            var ear = Path()
            ear.move(to: CGPoint(x: centre.x + s * r * 0.92, y: centre.y - r * 0.42))
            ear.addQuadCurve(
                to: CGPoint(x: centre.x + s * r * 0.18, y: centre.y - r * 0.92),
                control: CGPoint(x: centre.x + s * r * 0.30, y: centre.y - r * 1.62
                                 + (side < 0 ? twitch : 0)))
            ear.closeSubpath()
            ctx.fill(ear, with: .color(ink.fur))
            // Inner ear, smaller and pink, which is most of what makes a drawn
            // cat look like a cat rather than a shape with triangles on it.
            var inner = Path()
            inner.move(to: CGPoint(x: centre.x + s * r * 0.74, y: centre.y - r * 0.46))
            inner.addQuadCurve(
                to: CGPoint(x: centre.x + s * r * 0.30, y: centre.y - r * 0.80),
                control: CGPoint(x: centre.x + s * r * 0.34, y: centre.y - r * 1.30
                                 + (side < 0 ? twitch : 0)))
            inner.closeSubpath()
            ctx.fill(inner, with: .color(ink.pink))
        }

        // Head, very slightly wider than tall.
        ctx.fill(
            Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r * 0.9,
                                   width: r * 2, height: r * 1.8)),
            with: .color(ink.fur))

        // Whiskers first so the nose sits on top of them.
        let whisker = StrokeStyle(lineWidth: max(0.6, r * 0.07), lineCap: .round)
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            for row in 0..<2 {
                let y = centre.y + r * (0.16 + CGFloat(row) * 0.22)
                var w = Path()
                w.move(to: CGPoint(x: centre.x + s * r * 0.34, y: y))
                w.addQuadCurve(
                    to: CGPoint(x: centre.x + s * r * 1.30, y: y + r * (row == 0 ? -0.10 : 0.10)),
                    control: CGPoint(x: centre.x + s * r * 0.85, y: y - r * 0.04))
                ctx.stroke(w, with: .color(ink.dark.opacity(0.55)), style: whisker)
            }
        }

        drawEyes(&ctx, centre: centre, r: r, ink: ink, t: t, gaze: gaze)

        // Nose: small rounded triangle.
        var nose = Path()
        nose.move(to: CGPoint(x: centre.x - r * 0.14, y: centre.y + r * 0.16))
        nose.addLine(to: CGPoint(x: centre.x + r * 0.14, y: centre.y + r * 0.16))
        nose.addLine(to: CGPoint(x: centre.x, y: centre.y + r * 0.36))
        nose.closeSubpath()
        ctx.fill(nose, with: .color(ink.pink))

        // Mouth: two small arcs under the nose. A "w" is three strokes at this
        // size and turns to mud; two is enough to read as a mouth.
        let mouth = StrokeStyle(lineWidth: max(0.7, r * 0.08), lineCap: .round)
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            var m = Path()
            m.move(to: CGPoint(x: centre.x, y: centre.y + r * 0.38))
            m.addQuadCurve(
                to: CGPoint(x: centre.x + s * r * 0.26, y: centre.y + r * 0.30),
                control: CGPoint(x: centre.x + s * r * 0.14, y: centre.y + r * 0.52))
            ctx.stroke(m, with: .color(ink.dark.opacity(0.8)), style: mouth)
        }
    }

    private func drawEyes(_ ctx: inout GraphicsContext, centre: CGPoint, r: CGFloat,
                          ink: Ink, t: Double, gaze: Gaze) {
        // Blink roughly every three seconds, closing over two frames rather than
        // snapping, so it reads as a blink and not a glitch. The blink pose
        // blinks far more often, which is the whole difference between it and
        // the sitting pose.
        let every = pose == .blink ? 1.4 : 3.2
        let cycle = t.truncatingRemainder(dividingBy: every)
        let open: CGFloat
        switch cycle {
        case (every * 0.78)..<(every * 0.86): open = 0.4
        case (every * 0.86)..<(every * 0.94): open = 0.08
        default: open = 1.0
        }
        let drop: CGFloat = gaze == .down ? r * 0.16 : 0
        let eyeW = r * 0.26
        let eyeH = r * 0.34
        for side in [-1.0, 1.0] {
            let x = centre.x + CGFloat(side) * r * 0.40
            let y = centre.y - r * 0.06 + drop
            if open < 0.2 {
                // A closed eye is a line; a squashed ellipse disappears here.
                var lid = Path()
                lid.move(to: CGPoint(x: x - eyeW, y: y))
                lid.addQuadCurve(to: CGPoint(x: x + eyeW, y: y),
                                 control: CGPoint(x: x, y: y + eyeH * 0.35))
                ctx.stroke(lid, with: .color(ink.feature),
                           style: StrokeStyle(lineWidth: max(1.0, r * 0.09), lineCap: .round))
                continue
            }
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - eyeW, y: y - eyeH * open,
                                       width: eyeW * 2, height: eyeH * 2 * open)),
                with: .color(ink.feature))
            // One highlight per eye. Without it the eyes are holes; with it they
            // are wet, and the cat stops being a mask.
            if open > 0.5 {
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - eyeW * 0.15, y: y - eyeH * 0.55,
                                           width: eyeW * 0.55, height: eyeH * 0.45)),
                    with: .color(.primary.opacity(0.85)))
            }
        }
    }

    private func drawTail(_ ctx: inout GraphicsContext, from root: CGPoint, r: CGFloat,
                          ink: Ink, t: Double, upright: Bool = false) {
        // A tail that sweeps, so there is movement even when the eyes are open.
        // Upright is the typing pose, where the tail goes up behind the lid and
        // flicks at the tip — the cat is engaged, not lounging.
        let sway = CGFloat(sin(t * (upright ? 3.0 : 1.9)))
        var tail = Path()
        tail.move(to: root)
        if upright {
            tail.addQuadCurve(
                to: CGPoint(x: root.x + r * 0.9 + sway * r * 0.45, y: root.y - r * 1.5),
                control: CGPoint(x: root.x + r * 1.15, y: root.y - r * 0.4))
        } else {
            tail.addQuadCurve(
                to: CGPoint(x: root.x + r * 1.15, y: root.y - r * 0.75 + sway * r * 0.5),
                control: CGPoint(x: root.x + r * 1.55, y: root.y + r * 0.55))
        }
        ctx.stroke(tail, with: .color(ink.fur),
                   style: StrokeStyle(lineWidth: r * 0.30, lineCap: .round))
    }

    /// Three dots that light up in sequence — the part that actually reads as
    /// "still working" when the cat is small enough to ignore.
    private func drawDots(_ ctx: inout GraphicsContext, size: CGSize, ink: Ink,
                          t: Double, left: CGFloat) {
        let dot = size.height * 0.10
        for index in 0..<3 {
            let phase = (t * 2.2 - Double(index) * 0.35)
            let lift = CGFloat(sin(phase)) * size.height * 0.09
            let alpha = 0.30 + 0.45 * (0.5 + 0.5 * sin(phase))
            let x = left + CGFloat(index) * dot * 3.2
            ctx.fill(
                Path(ellipseIn: CGRect(x: x, y: size.height * 0.55 + lift,
                                       width: dot * 2, height: dot * 2)),
                with: .color(ink.dark.opacity(alpha)))
        }
    }
}

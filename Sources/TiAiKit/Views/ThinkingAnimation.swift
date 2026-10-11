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
        case typing, blink, chase, pounce, nyan, peek, stretch, ride
    }

    /// Which pose a run gets, in order of how much of it you should see.
    ///
    /// Typing is the signature — a cat at a keyboard is the joke, and the one
    /// people recognise as "it is working on my thing" — so it gets the most
    /// slots and the rest fill in behind it.
    private static let wheel: [Pose] = [
        .typing, .typing, .typing, .typing,
        .nyan, .nyan, .blink, .chase, .pounce, .peek, .stretch, .ride, .ride,
    ]

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

    private var size: CGSize {
        switch pose {
        case .typing: CGSize(width: 126, height: 42)
        case .nyan: CGSize(width: 156, height: 46)
        case .peek: CGSize(width: 96, height: 34)
        case .stretch: CGSize(width: 116, height: 34)
        case .ride: CGSize(width: 132, height: 52)
        default: CGSize(width: 104, height: 32)
        }
    }

    var body: some View {
        // Reduce Motion is about large movement across the screen, not about a
        // small figure in a line of text — and hiding the cat entirely meant
        // most people never saw it, because plenty of people leave Reduce Motion
        // on for unrelated reasons. So it stays, slowed down.
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.4 : 1.0 / 30.0)) { context in
            Canvas { ctx, canvasSize in
                let t = context.date.timeIntervalSinceReferenceDate * (reduceMotion ? 0.3 : 1)
                draw(&ctx, t: t)
            }
            .frame(width: size.width, height: size.height)
        }
        .accessibilityLabel("Thinking")
    }

    // MARK: - palette

    /// Fur, features and the pink bits, all derived from the scheme so the cat
    /// is a grey cat in light mode and a grey cat in dark mode, never a black
    /// silhouette glued onto a white background.
    private struct Ink {
        let fur: Color
        let shade: Color
        let feature: Color
        let pink: Color
        /// A near-transparent fill for the laptop lid, kept separate from `shade`
        /// so the lid reads as an object and not as part of the cat.
        var darkFill: Color { Color.primary.opacity(0.12) }

        static func make() -> Ink {
            Ink(fur: Color.secondary.opacity(0.85),
                shade: Color.secondary.opacity(0.62),
                feature: Color.primary.opacity(0.9),
                pink: Color.pink.opacity(0.5))
        }
    }

    /// Eased sine. A raw `sin` has a linear pass through zero that reads as
    /// mechanical; easing it makes the same motion look muscular.
    private func wave(_ t: Double, _ rate: Double) -> CGFloat {
        let s = sin(t * rate)
        return CGFloat(s * abs(s)) // quadratic ease, keeps the sign
    }

    // MARK: - dispatch

    private func draw(_ ctx: inout GraphicsContext, t: Double) {
        switch pose {
        case .typing: drawTyping(&ctx, t: t)
        case .nyan: drawNyan(&ctx, t: t)
        case .peek: drawPeek(&ctx, t: t)
        case .stretch: drawStretch(&ctx, t: t)
        case .ride: drawRide(&ctx, t: t)
        case .blink: drawSit(&ctx, t: t)
        case .chase: drawSit(&ctx, t: t)
        case .pounce: drawSit(&ctx, t: t)
        }
    }

    // MARK: - sitting cat

    /// A cat sitting and waiting: full face, tail curling, occasional blink and
    /// ear twitch. The face is the point — a head with two dots for eyes reads
    /// as a circle with punctures, not as an animal.
    private func drawSit(_ ctx: inout GraphicsContext, t: Double) {
        let ink = Ink.make()
        let r = size.height * 0.29
        let bob: CGFloat = pose == .pounce
            ? wave(t, 3.1) * 2.2
            : CGFloat(sin(t * 1.2)) * 0.6          // breathing
        let head = CGPoint(x: size.height * 0.66, y: size.height * 0.50 + bob)

        drawTail(&ctx, root: CGPoint(x: head.x + r * 0.85, y: head.y + r * 1.45),
                 r: r, ink: ink, t: t)

        // The loaf: a body wider at the base than the top, which is how a
        // sitting cat actually reads.
        var body = Path()
        let bx = head.x, by = head.y + r * 0.85
        body.move(to: CGPoint(x: bx - r * 1.05, y: by + r * 1.2))
        body.addQuadCurve(to: CGPoint(x: bx + r * 1.05, y: by + r * 1.2),
                          control: CGPoint(x: bx, y: by - r * 0.85))
        ctx.fill(body, with: .color(ink.fur))

        // Front legs, drawn as two narrow columns with toes, so the bottom of
        // the loaf has structure instead of being a blob.
        for side in [-1.0, 1.0] {
            let x = bx + CGFloat(side) * r * 0.46
            ctx.fill(Path(roundedRect: CGRect(x: x - r * 0.28, y: by + r * 0.72,
                                              width: r * 0.56, height: r * 0.5),
                          cornerRadius: r * 0.26), with: .color(ink.shade))
        }

        drawHead(&ctx, centre: head, r: r, ink: ink, t: t, gaze: .forward)
        drawDots(&ctx, ink: ink, t: t, left: size.height * 1.62)
    }

    // MARK: - the one at the keyboard

    /// A cat typing on a laptop, after the gif everyone means: head and
    /// shoulders above the lid, both paws over the keys alternately, tail up
    /// and flicking, eyes fixed downward on the screen it cannot see.
    private func drawTyping(_ ctx: inout GraphicsContext, t: Double) {
        let ink = Ink.make()
        let r: CGFloat = 9.5
        let head = CGPoint(x: 32, y: 14)

        drawTail(&ctx, root: CGPoint(x: head.x + r * 1.0, y: 27), r: r, ink: ink, t: t, upright: true)

        var body = Path()
        body.move(to: CGPoint(x: head.x - r * 1.15, y: 27))
        body.addQuadCurve(to: CGPoint(x: head.x + r * 1.15, y: 27),
                          control: CGPoint(x: head.x, y: 10))
        ctx.fill(body, with: .color(ink.fur))

        // Lid, seen from behind: a slab leaning back over the keyboard.
        var lid = Path()
        lid.move(to: CGPoint(x: 14, y: 31))
        lid.addLine(to: CGPoint(x: 52, y: 31))
        lid.addLine(to: CGPoint(x: 49, y: 21))
        lid.addLine(to: CGPoint(x: 17, y: 21))
        lid.closeSubpath()
        ctx.fill(lid, with: .color(ink.darkFill))
        ctx.stroke(lid, with: .color(ink.shade), lineWidth: 0.8)

        // Keyboard deck, a parallelogram so it has some depth.
        var deck = Path()
        deck.move(to: CGPoint(x: 10, y: 31))
        deck.addLine(to: CGPoint(x: 56, y: 31))
        deck.addLine(to: CGPoint(x: 61, y: 37))
        deck.addLine(to: CGPoint(x: 5, y: 37))
        deck.closeSubpath()
        ctx.fill(deck, with: .color(ink.shade.opacity(0.7)))

        // Paws on the front of the lid, alternating at roughly three taps a
        // second. Never both down at once: that reads as a still image.
        let tap = sin(t * 15.0)
        for (side, phase) in [(-1.0, tap), (1.0, -tap)] {
            let x = head.x + CGFloat(side) * r * 0.60
            let down = max(0, CGFloat(phase))
            let y = 29.2 - (1 - down) * 3.2
            ctx.fill(
                Path(roundedRect: CGRect(x: x - 3.4, y: y, width: 6.8, height: 5),
                     cornerRadius: 2.5),
                with: .color(ink.fur))
            // Toes, so it is a paw and not a pill.
            for toe in -1...1 {
                ctx.fill(
                    Path(roundedRect: CGRect(x: x + CGFloat(toe) * 1.9 - 0.45, y: y + 3.1,
                                             width: 0.9, height: 1.5), cornerRadius: 0.45),
                    with: .color(ink.shade))
            }
            if down > 0.85 {
                ctx.fill(
                    Path(roundedRect: CGRect(x: x - 2.6, y: 33.8, width: 5.2, height: 1.5),
                         cornerRadius: 0.75),
                    with: .color(.primary.opacity(0.45)))
            }
        }

        drawHead(&ctx, centre: head, r: r, ink: ink, t: t, gaze: .down)

        // Output marching up the side — the part that says something is being
        // produced rather than time merely passing.
        for index in 0..<3 {
            let phase = (t * 2.4 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1.5)
            let y = 10 + CGFloat(index) * 7 - CGFloat(phase) * 2
            let width: CGFloat = [24, 17, 28][index]
            ctx.fill(
                Path(roundedRect: CGRect(x: 78, y: y, width: width, height: 2.2), cornerRadius: 1.1),
                with: .color(.primary.opacity(0.22)))
        }
    }

    // MARK: - nyan

    /// The Pop-Tart cat, flying. The most recognisable cat on the internet and
    /// a decent metaphor for a job that is taking a while: something is
    /// definitely happening, it is just not finished.
    ///
    /// The rainbow trails rather than leads, and its bands scroll, so the eye
    /// reads forward motion even though the cat only bobs in place.
    private func drawNyan(_ ctx: inout GraphicsContext, t: Double) {
        let ink = Ink.make()
        let bob = wave(t, 2.2) * 2.0
        let cat = CGPoint(x: size.width - 62, y: size.height * 0.5 + bob)

        // Rainbow: six bands behind the cat, scrolling toward the tail end.
        let bands: [Color] = [
            Color(red: 0.92, green: 0.30, blue: 0.36),
            Color(red: 0.96, green: 0.60, blue: 0.25),
            Color(red: 0.98, green: 0.86, blue: 0.36),
            Color(red: 0.42, green: 0.78, blue: 0.44),
            Color(red: 0.36, green: 0.62, blue: 0.92),
            Color(red: 0.66, green: 0.46, blue: 0.90),
        ]
        let bandH: CGFloat = 3.0
        let top = cat.y - CGFloat(bands.count) * bandH / 2 + 2
        for (i, colour) in bands.enumerated() {
            // Each band ends a little further back, and the far end shimmers,
            // so the trail does not look like a ruler was used.
            let end = cat.x - 6 - CGFloat(i.isMultiple(of: 2) ? 0 : 3)
            let start: CGFloat = 2 + CGFloat(sin(t * 3 + Double(i))) * 2
            ctx.fill(Path(roundedRect: CGRect(x: start, y: top + CGFloat(i) * bandH,
                                              width: max(4, end - start), height: bandH),
                          cornerRadius: bandH / 2),
                     with: .color(colour.opacity(0.85)))
        }

        // Pop-Tart body: frosting over pastry, with sprinkles.
        let bodyRect = CGRect(x: cat.x - 17, y: cat.y - 8, width: 34, height: 17)
        ctx.fill(Path(roundedRect: bodyRect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4),
                 with: .color(Color(red: 0.99, green: 0.78, blue: 0.86)))
        ctx.fill(Path(roundedRect: bodyRect, cornerRadius: 3),
                 with: .color(Color(red: 0.96, green: 0.55, blue: 0.70)))
        for (dx, dy) in [(-9, -3), (-3, 2), (4, -4), (9, 1), (0, -1)] {
            ctx.fill(Path(roundedRect: CGRect(x: cat.x + CGFloat(dx), y: cat.y + CGFloat(dy),
                                              width: 2.2, height: 1.1), cornerRadius: 0.55),
                     with: .color(.white.opacity(0.85)))
        }

        // Four legs, pumping in pairs — the gait everyone remembers.
        for (i, dx) in [-12.0, -5.0, 6.0, 13.0].enumerated() {
            let swing = wave(t, 9.0) * (i.isMultiple(of: 2) ? 2.2 : -2.2)
            ctx.fill(Path(roundedRect: CGRect(x: cat.x + CGFloat(dx), y: cat.y + 7,
                                              width: 4.4, height: 6), cornerRadius: 2.2),
                     with: .color(ink.fur))
            _ = swing
        }

        // Head, small and to the front, with the flat deadpan face of the original.
        let head = CGPoint(x: cat.x + 20, y: cat.y - 6)
        let hr: CGFloat = 8
        drawEars(&ctx, centre: head, r: hr, ink: ink, t: t)
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - hr, y: head.y - hr * 0.9,
                                        width: hr * 2, height: hr * 1.8)),
                 with: .color(ink.fur))
        for side in [-1.0, 1.0] {
            ctx.fill(Path(ellipseIn: CGRect(x: head.x + CGFloat(side) * hr * 0.42 - 1.1,
                                            y: head.y - 1.4, width: 2.2, height: 2.6)),
                     with: .color(ink.feature))
        }
        // Mouth: the tiny "3" that makes it a cat and not a bear.
        let mouth = StrokeStyle(lineWidth: 0.8, lineCap: .round)
        for side in [-1.0, 1.0] {
            var m = Path()
            m.move(to: CGPoint(x: head.x, y: head.y + hr * 0.34))
            m.addQuadCurve(to: CGPoint(x: head.x + CGFloat(side) * hr * 0.30, y: head.y + hr * 0.24),
                           control: CGPoint(x: head.x + CGFloat(side) * hr * 0.16, y: head.y + hr * 0.5))
            ctx.stroke(m, with: .color(ink.feature), style: mouth)
        }
    }

    // MARK: - peeking

    /// A cat peering over a ledge, eyes side to side, ducking down now and then.
    /// The "is it done yet" pose, and the easiest one to read at a glance.
    private func drawPeek(_ ctx: inout GraphicsContext, t: Double) {
        let ink = Ink.make()
        let ledge = size.height - 7
        // A slow cycle: up, look around, duck, repeat.
        let cycle = (t.truncatingRemainder(dividingBy: 5.0)) / 5.0
        let duck: CGFloat = cycle > 0.82 ? (CGFloat(sin((cycle - 0.82) / 0.18 * .pi)) * 9) : 0
        let head = CGPoint(x: size.width * 0.42, y: ledge - 9 + duck)
        let r: CGFloat = 10

        drawEars(&ctx, centre: head, r: r, ink: ink, t: t)
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r * 0.8,
                                        width: r * 2, height: r * 1.6)),
                 with: .color(ink.fur))

        // Eyes that scan left and right, above the ledge line.
        let look = wave(t, 1.6) * 2.2
        for side in [-1.0, 1.0] {
            let x = head.x + CGFloat(side) * r * 0.42 + look
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.4, y: head.y - 2.6, width: 4.8, height: 5.2)),
                     with: .color(ink.feature))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 0.7, y: head.y - 1.8, width: 1.4, height: 3.6)),
                     with: .color(.primary.opacity(0.9)))
        }

        // Paws hooked over the edge, one sliding.
        for (side, phase) in [(-1.0, 0.0), (1.0, Double.pi)] {
            let slide = CGFloat(sin(t * 1.6 + phase)) * 1.6
            ctx.fill(Path(roundedRect: CGRect(x: head.x + CGFloat(side) * r * 0.95 - 3 + slide,
                                              y: ledge - 3, width: 6.5, height: 5),
                          cornerRadius: 2.4), with: .color(ink.fur))
        }

        // The ledge itself, drawn last so the cat is clearly behind it.
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: ledge + 1, width: size.width, height: 6),
                     cornerRadius: 2), with: .color(ink.shade.opacity(0.55)))
    }

    // MARK: - stretching

    /// The down-dog stretch: chest down, back arched, hindquarters up. A nice
    /// silhouette that is obviously a cat even in shadow, and a good "waking up
    /// to go look at this" beat.
    private func drawStretch(_ ctx: inout GraphicsContext, t: Double) {
        let ink = Ink.make()
        let floor = size.height - 6
        let sag = wave(t, 1.5) * 1.4
        let head = CGPoint(x: 26, y: floor - 12 + sag)
        let rear = CGPoint(x: size.width - 34, y: floor - 19 - sag)

        // Back: one curve from head to tail, which is the whole pose.
        var back = Path()
        back.move(to: CGPoint(x: head.x + 4, y: head.y + 2))
        back.addQuadCurve(to: CGPoint(x: rear.x, y: rear.y),
                          control: CGPoint(x: (head.x + rear.x) / 2, y: floor - 26 + sag))
        back.addLine(to: CGPoint(x: rear.x, y: floor))
        back.addLine(to: CGPoint(x: head.x + 4, y: floor))
        back.closeSubpath()
        ctx.fill(back, with: .color(ink.fur))

        // Front paws stretched forward under the chest.
        ctx.fill(Path(roundedRect: CGRect(x: head.x - 12, y: floor - 4, width: 20, height: 4.5),
                     cornerRadius: 2.2), with: .color(ink.shade))
        // Hind leg planted.
        ctx.fill(Path(roundedRect: CGRect(x: rear.x - 4, y: floor - 12, width: 6, height: 12),
                     cornerRadius: 2.6), with: .color(ink.shade))

        drawTail(&ctx, root: CGPoint(x: rear.x + 3, y: rear.y + 2), r: 7, ink: ink, t: t, upright: true)
        drawHead(&ctx, centre: head, r: 8, ink: ink, t: t, gaze: .down)
    }

    // MARK: - riding the robot vacuum

    /// A cat lying on a robot vacuum, seen from above, slowly turning.
    ///
    /// The gif everyone means is shot from the ceiling: the cat is sprawled on
    /// the disc, completely boneless about it, and the whole thing rotates. A
    /// side view of a cat standing on a moving disc is a different joke and
    /// does not read at all, which is what the first attempt drew.
    ///
    /// Top-down works better at this size anyway: a circle with a cat on it is
    /// legible in a way a low side silhouette is not.
    private func drawRide(_ ctx: inout GraphicsContext, t: Double) {
        let ink = Ink.make()
        let centre = CGPoint(x: size.width * 0.36, y: size.height * 0.52)
        let discR: CGFloat = size.height * 0.44

        // Floor marks, deliberately *not* rotating: without something standing
        // still there is no way to tell the disc is turning, and it looks like a
        // cat on a plate.
        for (dx, dy) in [(-discR - 7, -discR * 0.5), (-discR - 5, discR * 0.7),
                         (discR + 5, -discR * 0.8), (discR + 7, discR * 0.4)] {
            ctx.fill(Path(ellipseIn: CGRect(x: centre.x + dx, y: centre.y + dy,
                                            width: 2.6, height: 2.0)),
                     with: .color(ink.shade.opacity(0.4)))
        }
        // Shadow under the disc, offset a little so it reads as lifted off the
        // floor, and fixed while everything above it turns.
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - discR - 1, y: centre.y - discR + 2,
                                        width: discR * 2 + 2, height: discR * 2 + 2)),
                 with: .color(.black.opacity(0.10)))

        // The disc itself does not rotate — a plain circle rotating is
        // invisible — but its bumper light travels, which is what sells it.
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - discR, y: centre.y - discR,
                                        width: discR * 2, height: discR * 2)),
                 with: .color(ink.shade))
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - discR + 2.5, y: centre.y - discR + 2.5,
                                        width: discR * 2 - 5, height: discR * 2 - 5)),
                 with: .color(ink.fur.opacity(0.45)))
        let spin = t * 1.15
        let ledAngle = CGFloat(cos(spin)) * 0.9 - 1.57
        let led = CGPoint(x: centre.x + cos(ledAngle) * (discR - 3),
                          y: centre.y + sin(ledAngle) * (discR - 3))
        ctx.fill(Path(ellipseIn: CGRect(x: led.x - 1.7, y: led.y - 1.7, width: 3.4, height: 3.4)),
                 with: .color(.green.opacity(0.55 + 0.45 * sin(t * 3.0))))

        // Everything above turns together.
        ctx.translateBy(x: centre.x, y: centre.y)
        ctx.rotate(by: .radians(spin))

        // Paws draped over the rim, past the disc edge — the detail that says
        // the cat is being carried rather than standing somewhere.
        for (angle, radius) in [(2.5, discR + 1), (0.65, discR + 1),
                                (-2.5, discR + 1), (-0.65, discR + 1)] {
            let x = cos(CGFloat(angle)) * radius
            let y = sin(CGFloat(angle)) * radius
            ctx.fill(Path(roundedRect: CGRect(x: x - 2.6, y: y - 2.0, width: 5.2, height: 4.4),
                         cornerRadius: 2.2), with: .color(ink.fur))
        }

        // Tail flicking off the side, the one part of the cat that is not limp.
        var tail = Path()
        tail.move(to: CGPoint(x: 2, y: discR * 0.55))
        tail.addQuadCurve(
            to: CGPoint(x: discR * 0.95 + wave(t, 2.4) * 3, y: discR * 1.05),
            control: CGPoint(x: discR * 0.85, y: discR * 0.8))
        ctx.stroke(tail, with: .color(ink.fur),
                   style: StrokeStyle(lineWidth: 3.0, lineCap: .round))

        // Body: a long loaf, sprawled rather than curled. Loose about the middle
        // so it does not look glued to the disc.
        let sag = wave(t, 1.3) * 1.2
        ctx.fill(Path(ellipseIn: CGRect(x: -11, y: -discR * 0.62 + sag,
                                        width: 22, height: discR * 1.35)),
                 with: .color(ink.fur))
        // Tabby stripes across the back.
        for (i, dy) in [-6.0, 0.0, 6.0].enumerated() {
            var stripe = Path()
            stripe.move(to: CGPoint(x: -9, y: CGFloat(dy) + sag))
            stripe.addQuadCurve(to: CGPoint(x: 9, y: CGFloat(dy) + sag),
                                control: CGPoint(x: 0, y: CGFloat(dy) + sag + (i.isMultiple(of: 2) ? 2 : -2)))
            ctx.stroke(stripe, with: .color(ink.shade),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }

        // Head at the front, cheek fur and ears, eyes half shut: the cat has
        // made peace with this.
        let head = CGPoint(x: 0, y: -discR * 0.72 + sag)
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            var ear = Path()
            ear.move(to: CGPoint(x: head.x + s * 7.4, y: head.y - 2.2))
            ear.addQuadCurve(to: CGPoint(x: head.x + s * 1.4, y: head.y - 7.2),
                             control: CGPoint(x: head.x + s * 2.6, y: head.y - 12.4))
            ear.closeSubpath()
            ctx.fill(ear, with: .color(ink.fur))
            var inner = Path()
            inner.move(to: CGPoint(x: head.x + s * 5.8, y: head.y - 2.6))
            inner.addQuadCurve(to: CGPoint(x: head.x + s * 2.2, y: head.y - 6.2),
                               control: CGPoint(x: head.x + s * 2.6, y: head.y - 9.6))
            inner.closeSubpath()
            ctx.fill(inner, with: .color(ink.pink))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - 8, y: head.y - 7, width: 16, height: 14)),
                 with: .color(ink.fur))
        // Slow-blink eyes, nearly closed. Wide eyes would be a frightened cat,
        // and the whole point of that gif is that this one is not.
        let blink = (t.truncatingRemainder(dividingBy: 4.2))
        let open: CGFloat = blink > 3.5 ? 0.15 : 1.0
        let eye = StrokeStyle(lineWidth: 1.3, lineCap: .round)
        for side in [-1.0, 1.0] {
            let x = head.x + CGFloat(side) * 3.4
            if open < 0.3 {
                var lid = Path()
                lid.move(to: CGPoint(x: x - 1.9, y: head.y - 0.4))
                lid.addLine(to: CGPoint(x: x + 1.9, y: head.y - 0.4))
                ctx.stroke(lid, with: .color(ink.feature), style: eye)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1.9, y: head.y - 2.2, width: 3.8, height: 3.6)),
                         with: .color(ink.feature))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: head.y - 1.4, width: 1.2, height: 1.2)),
                         with: .color(.white.opacity(0.9)))
            }
        }
        var nose = Path()
        nose.move(to: CGPoint(x: head.x - 1.3, y: head.y + 2.0))
        nose.addLine(to: CGPoint(x: head.x + 1.3, y: head.y + 2.0))
        nose.addLine(to: CGPoint(x: head.x, y: head.y + 3.4))
        nose.closeSubpath()
        ctx.fill(nose, with: .color(ink.pink))

        ctx.rotate(by: .radians(-spin))
        ctx.translateBy(x: -centre.x, y: -centre.y)

        drawDots(&ctx, ink: ink, t: t, left: size.width * 0.70)
    }

    // MARK: - parts

    private enum Gaze { case forward, down }

    /// Head, ears and face in one place, because every pose needs the same cat
    /// and two copies of a face is how the poses stop looking related.
    private func drawHead(_ ctx: inout GraphicsContext, centre: CGPoint, r: CGFloat,
                          ink: Ink, t: Double, gaze: Gaze) {
        drawEars(&ctx, centre: centre, r: r, ink: ink, t: t)

        // Cheek fluff, drawn before the head so the tufts stick out past it.
        // This is most of what separates "cat" from "round animal" at 30 points.
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            for row in 0..<2 {
                var tuft = Path()
                let y = centre.y + r * (0.10 + CGFloat(row) * 0.30)
                tuft.move(to: CGPoint(x: centre.x + s * r * 0.72, y: y - r * 0.16))
                tuft.addLine(to: CGPoint(x: centre.x + s * r * 1.22, y: y + r * 0.06))
                tuft.addLine(to: CGPoint(x: centre.x + s * r * 0.70, y: y + r * 0.26))
                tuft.closeSubpath()
                ctx.fill(tuft, with: .color(ink.fur))
            }
        }

        // Head, very slightly wider than tall.
        ctx.fill(
            Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r * 0.9,
                                   width: r * 2, height: r * 1.8)),
            with: .color(ink.fur))

        // Tabby markings: two short strokes on the forehead. Cheap, and it
        // reads as fur rather than as a filled shape.
        let stripe = StrokeStyle(lineWidth: max(0.7, r * 0.09), lineCap: .round)
        for side in [-1.0, 1.0] {
            var s1 = Path()
            s1.move(to: CGPoint(x: centre.x + CGFloat(side) * r * 0.20, y: centre.y - r * 0.78))
            s1.addLine(to: CGPoint(x: centre.x + CGFloat(side) * r * 0.30, y: centre.y - r * 0.46))
            ctx.stroke(s1, with: .color(ink.shade), style: stripe)
        }

        // Whiskers, under the nose so the nose sits on top of them.
        let whisker = StrokeStyle(lineWidth: max(0.6, r * 0.07), lineCap: .round)
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            for row in 0..<2 {
                let y = centre.y + r * (0.16 + CGFloat(row) * 0.22)
                var w = Path()
                w.move(to: CGPoint(x: centre.x + s * r * 0.34, y: y))
                w.addQuadCurve(
                    to: CGPoint(x: centre.x + s * r * 1.34, y: y + r * (row == 0 ? -0.12 : 0.12)),
                    control: CGPoint(x: centre.x + s * r * 0.85, y: y - r * 0.04))
                ctx.stroke(w, with: .color(ink.shade), style: whisker)
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

        // Mouth: two arcs under the nose — the "3" that makes it a cat face.
        let mouth = StrokeStyle(lineWidth: max(0.7, r * 0.08), lineCap: .round)
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            var m = Path()
            m.move(to: CGPoint(x: centre.x, y: centre.y + r * 0.38))
            m.addQuadCurve(to: CGPoint(x: centre.x + s * r * 0.26, y: centre.y + r * 0.30),
                           control: CGPoint(x: centre.x + s * r * 0.14, y: centre.y + r * 0.52))
            ctx.stroke(m, with: .color(ink.feature.opacity(0.85)), style: mouth)
        }
    }

    /// `swept` is the airplane-ear position — ears rotated out sideways, which
    /// is what a cat does when it is not entirely thrilled about being moved.
    private func drawEars(_ ctx: inout GraphicsContext, centre: CGPoint, r: CGFloat,
                          ink: Ink, t: Double, swept: Bool = false) {
        // One ear twitches now and then; two static ears read as a logo.
        let twitch: CGFloat = pose == .chase ? CGFloat(max(0, sin(t * 1.6))) * -r * 0.24 : 0
        for side in [-1.0, 1.0] {
            let s = CGFloat(side)
            let lift = side < 0 ? twitch : 0
            // Swept ears sit lower and further out, and lose the inner pink:
            // at this size two pale wedges pointing sideways just look broken.
            let out: CGFloat = swept ? 1.30 : 0.94
            let up: CGFloat = swept ? -r * 0.62 : -r * 1.66 + lift
            var ear = Path()
            ear.move(to: CGPoint(x: centre.x + s * r * out, y: centre.y - r * 0.34))
            ear.addQuadCurve(
                to: CGPoint(x: centre.x + s * r * 0.16, y: centre.y - r * (swept ? 0.78 : 0.94)),
                control: CGPoint(x: centre.x + s * r * (swept ? 0.95 : 0.30),
                                 y: centre.y + up))
            ear.closeSubpath()
            ctx.fill(ear, with: .color(ink.fur))
            guard !swept else { continue }
            // Inner ear, smaller and pink: most of what makes a drawn cat look
            // like a cat rather than a shape with triangles on it.
            var inner = Path()
            inner.move(to: CGPoint(x: centre.x + s * r * 0.74, y: centre.y - r * 0.46))
            inner.addQuadCurve(
                to: CGPoint(x: centre.x + s * r * 0.30, y: centre.y - r * 0.82),
                control: CGPoint(x: centre.x + s * r * 0.34, y: centre.y - r * 1.32 + lift))
            inner.closeSubpath()
            ctx.fill(inner, with: .color(ink.pink))
        }
    }

    private func drawEyes(_ ctx: inout GraphicsContext, centre: CGPoint, r: CGFloat,
                          ink: Ink, t: Double, gaze: Gaze) {
        // Blink roughly every three seconds, closing over two frames rather than
        // snapping, so it reads as a blink and not a glitch. The blink pose
        // blinks far more often, which is the whole difference between it and
        // the sitting pose.
        let every = pose == .blink ? 1.5 : 3.4
        let cycle = t.truncatingRemainder(dividingBy: every)
        let open: CGFloat
        switch cycle {
        case (every * 0.78)..<(every * 0.86): open = 0.35
        case (every * 0.86)..<(every * 0.94): open = 0.06
        default: open = 1.0
        }
        let drop: CGFloat = gaze == .down ? r * 0.16 : 0
        let eyeW = r * 0.27
        let eyeH = r * 0.36
        for side in [-1.0, 1.0] {
            let x = centre.x + CGFloat(side) * r * 0.40
            let y = centre.y - r * 0.06 + drop
            if open < 0.2 {
                var lid = Path()
                lid.move(to: CGPoint(x: x - eyeW, y: y))
                lid.addQuadCurve(to: CGPoint(x: x + eyeW, y: y),
                                 control: CGPoint(x: x, y: y + eyeH * 0.4))
                ctx.stroke(lid, with: .color(ink.feature),
                           style: StrokeStyle(lineWidth: max(1.0, r * 0.09), lineCap: .round))
                continue
            }
            // Almond eye, not a circle: wider than tall with a slight tilt.
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - eyeW, y: y - eyeH * open,
                                       width: eyeW * 2, height: eyeH * 2 * open)),
                with: .color(ink.feature))
            // Vertical slit pupil. This single detail is what makes a drawn
            // animal read as a *cat* rather than a bear or a seal.
            if open > 0.6 {
                ctx.fill(
                    Path(roundedRect: CGRect(x: x - eyeW * 0.16, y: y - eyeH * 0.78 * open,
                                             width: eyeW * 0.32, height: eyeH * 1.56 * open),
                         cornerRadius: eyeW * 0.16),
                    with: .color(.white.opacity(0.92)))
                // One highlight, so the eye is wet and not a hole.
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - eyeW * 0.42, y: y - eyeH * 0.52,
                                           width: eyeW * 0.42, height: eyeH * 0.36)),
                    with: .color(.white.opacity(0.75)))
            }
        }
    }

    /// A tail drawn as a filled, tapered shape rather than a uniform stroke.
    /// A uniform stroke reads as a pipe cleaner; tapering it reads as an animal.
    private func drawTail(_ ctx: inout GraphicsContext, root: CGPoint, r: CGFloat,
                          ink: Ink, t: Double, upright: Bool = false) {
        let sway = wave(t, upright ? 3.0 : 1.9)
        let tip: CGPoint
        let control: CGPoint
        if upright {
            tip = CGPoint(x: root.x + r * 0.95 + sway * r * 0.5, y: root.y - r * 1.6)
            control = CGPoint(x: root.x + r * 1.2, y: root.y - r * 0.4)
        } else {
            tip = CGPoint(x: root.x + r * 1.2, y: root.y - r * 0.8 + sway * r * 0.55)
            control = CGPoint(x: root.x + r * 1.6, y: root.y + r * 0.6)
        }
        let base = r * 0.30
        var tail = Path()
        tail.move(to: CGPoint(x: root.x, y: root.y - base / 2))
        tail.addQuadCurve(to: tip, control: control)
        tail.addQuadCurve(to: CGPoint(x: root.x, y: root.y + base / 2),
                          control: CGPoint(x: control.x - base, y: control.y))
        tail.closeSubpath()
        ctx.fill(tail, with: .color(ink.fur))
        // A lighter tip, the way tabby tails end.
        ctx.fill(Path(ellipseIn: CGRect(x: tip.x - base * 0.42, y: tip.y - base * 0.42,
                                        width: base * 0.84, height: base * 0.84)),
                 with: .color(ink.shade))
    }

    /// Three dots that light up in sequence — the part that actually reads as
    /// "still working" when the cat is small enough to ignore.
    private func drawDots(_ ctx: inout GraphicsContext, ink: Ink, t: Double, left: CGFloat) {
        let dot = size.height * 0.10
        for index in 0..<3 {
            let phase = (t * 2.2 - Double(index) * 0.35)
            let lift = CGFloat(sin(phase)) * size.height * 0.09
            let alpha = 0.30 + 0.45 * (0.5 + 0.5 * sin(phase))
            let x = left + CGFloat(index) * dot * 3.2
            ctx.fill(
                Path(ellipseIn: CGRect(x: x, y: size.height * 0.55 + lift,
                                       width: dot * 2, height: dot * 2)),
                with: .color(ink.feature.opacity(alpha)))
        }
    }
}

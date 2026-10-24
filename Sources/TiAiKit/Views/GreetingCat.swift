import SwiftUI

/// The cat that sits on an empty chat: Apollo, the user's cat.
///
/// Drawn from a photo of a black-and-white tuxedo cat, so the markings are the
/// point rather than the outline. What makes him recognisable, in the order they
/// matter: a black mask broken by a narrow white blaze running up from the
/// muzzle between the eyes, a pink nose, yellow-green eyes, a white bib and
/// white socks, and a tail held up.
///
/// The silhouette is still one shape — head, ears, body, tail and paws — because
/// the first version was three stacked ellipses that read as a rendering error,
/// and a single silhouette has no seams where parts overlap. The markings are
/// painted on top of it.
///
/// The dark parts use the adaptive ink and the light parts the adaptive paper,
/// rather than literal black and white: a black cat on a near-black background is
/// invisible, and the tuxedo pattern survives the inversion intact. The nose and
/// eyes are the only fixed colours, because pink and yellow-green read in either
/// appearance.
///
/// Three small movements, all slow: he breathes, blinks every few seconds, and
/// sways that up-turned tail. Under Reduce Motion he sits still with his eyes
/// open, which is the same cat minus the motion rather than a different layout.
public struct GreetingCat: View {
    var size: CGFloat = 128

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 128) {
        self.size = size
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : 1.0 / 30.0)) { timeline in
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize.width, at: timeline.date)
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Colour

    /// The black coat. `Color.primary` at full strength is harsh for a decorative
    /// mark, and a flat grey is invisible in light mode, so it is picked per
    /// appearance.
    private var ink: Color {
        scheme == .dark ? Color(white: 0.86) : Color(white: 0.22)
    }

    /// The white coat. Historically the face was cut out of the silhouette, so
    /// this was the colour of whatever the cat sat on; now it is the bib, the
    /// blaze and the socks, and it still tracks the appearance so it stays the
    /// light half of a two-tone cat in either scheme.
    private var paper: Color {
        scheme == .dark ? Color(white: 0.06) : Color(white: 0.98)
    }

    /// Apollo's nose, and the eyes. Fixed on purpose: a muted pink and a
    /// yellow-green both read against black or white fur and in either
    /// appearance, and they are two of the three things that make him him.
    private let nosePink = Color(red: 0.87, green: 0.55, blue: 0.58)
    private let eyeAmber = Color(red: 0.76, green: 0.79, blue: 0.36)

    // MARK: - Timing

    private struct Beat {
        let breath: Double
        /// Not an amplitude: the phase of the wave that travels down the tail.
        let tailPhase: Double
        let blink: Double
        let ear: Double
    }

    /// Blink and ear twitch are windows in a slow cycle rather than a smooth wave:
    /// a cat that pulses continuously looks mechanical, and one that does something
    /// occasionally looks alive.
    private func beat(at date: Date) -> Beat {
        guard !reduceMotion else { return Beat(breath: 0, tailPhase: 0, blink: 0, ear: 0) }
        let t = date.timeIntervalSinceReferenceDate
        let cycle = t.truncatingRemainder(dividingBy: 4.6)
        let blink = (cycle > 4.10 && cycle < 4.26) ? 1.0 : 0.0
        let twitch = t.truncatingRemainder(dividingBy: 9.3)
        let ear = (twitch > 6.0 && twitch < 6.34) ? sin((twitch - 6.0) / 0.34 * .pi) : 0
        return Beat(
            breath: sin(t * 1.25),
            tailPhase: t * 1.9,
            blink: blink,
            ear: ear
        )
    }

    // MARK: - Tail

    /// A point on a cubic Bezier at parameter `t`.
    private func bezier(_ t: CGFloat, _ p0: CGPoint, _ p1: CGPoint,
                        _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, c = t * t * t
        return CGPoint(x: a * p0.x + b1 * p1.x + b2 * p2.x + c * p3.x,
                       y: a * p0.y + b1 * p1.y + b2 * p2.y + c * p3.y)
    }

    /// The tail, sampled along a curve and stroked.
    ///
    /// Sampled rather than drawn as one Bezier because the wave has to be applied
    /// per point: a single curve can only bend once, and a tail that bends once
    /// bends as a unit.
    private func tailPath(s: CGFloat, phase: Double) -> Path {
        let root = CGPoint(x: s * 0.600, y: s * 0.865)
        let tip = CGPoint(x: s * 0.780, y: s * 0.400)
        let steps = 26
        var spine = Path()
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = bezier(t, root,
                           CGPoint(x: s * 0.868, y: s * 0.815),
                           CGPoint(x: s * 0.928, y: s * 0.560), tip)
            // Amplitude grows toward the tip and the phase lags along the length,
            // so the base is still and the tip is doing the work.
            let amp = pow(t, 1.7) * s * 0.062
            let point = CGPoint(x: p.x + CGFloat(sin(phase - Double(t) * 2.1)) * amp, y: p.y)
            if i == 0 { spine.move(to: point) } else { spine.addLine(to: point) }
        }
        return spine.strokedPath(StrokeStyle(lineWidth: s * 0.048,
                                             lineCap: .round, lineJoin: .round))
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size side: CGFloat, at date: Date) {
        let s = side
        let b = beat(at: date)
        let lift = b.breath * s * 0.008
        let widen = 1 + b.breath * 0.012
        let headLift = lift / s

        var body = Path()
        // The body is an egg, not a circle: wider at the base, narrowing to the
        // shoulders. Drawn as curves so the sides bulge rather than taper.
        let baseY = s * 0.90
        let shoulderY = s * 0.42 + lift
        body.move(to: CGPoint(x: s * 0.50, y: baseY))
        body.addCurve(
            to: CGPoint(x: s * 0.285 * widen + s * 0.5 * (1 - widen), y: s * 0.66),
            control1: CGPoint(x: s * 0.34, y: baseY),
            control2: CGPoint(x: s * 0.26 * widen + s * 0.5 * (1 - widen), y: s * 0.80)
        )
        body.addCurve(
            to: CGPoint(x: s * 0.50, y: shoulderY),
            control1: CGPoint(x: s * 0.30 * widen + s * 0.5 * (1 - widen), y: s * 0.54),
            control2: CGPoint(x: s * 0.39, y: shoulderY)
        )
        body.addCurve(
            to: CGPoint(x: s * 0.715 * widen + s * 0.5 * (1 - widen), y: s * 0.66),
            control1: CGPoint(x: s * 0.61, y: shoulderY),
            control2: CGPoint(x: s * 0.70 * widen + s * 0.5 * (1 - widen), y: s * 0.54)
        )
        body.addCurve(
            to: CGPoint(x: s * 0.50, y: baseY),
            control1: CGPoint(x: s * 0.74 * widen + s * 0.5 * (1 - widen), y: s * 0.80),
            control2: CGPoint(x: s * 0.66, y: baseY)
        )
        body.closeSubpath()

        // Ears, set on the head circle rather than floating above it, so the union
        // has no notches. Apollo's are plain pointed triangles, no tufts.
        func ear(mirror: Bool) -> Path {
            func x(_ v: CGFloat) -> CGFloat { mirror ? s - v * s : v * s }
            var p = Path()
            p.move(to: CGPoint(x: x(0.335), y: (0.27 + headLift) * s))
            p.addLine(to: CGPoint(x: x(0.285), y: (0.075 + headLift) * s))
            p.addLine(to: CGPoint(x: x(0.475), y: (0.20 + headLift) * s))
            p.closeSubpath()
            return p
        }
        // A twitch is a few degrees about the ear's base, not a wag of the whole
        // triangle, which would read as a shake.
        func twitched(_ p: Path, pivot: CGPoint, angle: Double) -> Path {
            var t = CGAffineTransform(translationX: pivot.x, y: pivot.y)
                .rotated(by: angle)
                .translatedBy(x: -pivot.x, y: -pivot.y)
            return p.applying(t)
        }

        let head = Path(ellipseIn: CGRect(
            x: s * 0.305, y: s * (0.155 + headLift),
            width: s * 0.39, height: s * 0.39
        ))

        // The tail, as a travelling wave rather than a rigid rotation.
        //
        // Rotating the whole shape about its root is what a windscreen wiper
        // does. A cat's tail is a chain: the base barely moves, each part behind
        // it moves more and a moment later, and the tip swings widest. So the tail
        // is sampled along a base curve and each sample nudged sideways by a sine
        // whose amplitude grows toward the tip and whose phase lags along the
        // length. That lag is the whole difference between flexible and rigid.
        //
        // The root has to be *inside* the body, not on its edge. The egg narrows
        // toward the base, so at this height the silhouette's right side is near
        // x 0.62 — starting the tail at 0.70 left it floating a few points clear
        // of the cat, which reads as a detached tail.
        //
        // Apollo greets people with his tail up and the last third hooked back,
        // and it stops about level with the shoulders. The first version reached
        // past the top of the frame, which made him look like he was waving.
        let tail = tailPath(s: s, phase: b.tailPhase)

        // Front paws, just proud of the base so the silhouette ends in feet
        // rather than a flat bottom.
        var paws = Path()
        paws.addRoundedRect(
            in: CGRect(x: s * 0.375, y: s * 0.845, width: s * 0.10, height: s * 0.065),
            cornerSize: CGSize(width: s * 0.032, height: s * 0.032))
        paws.addRoundedRect(
            in: CGRect(x: s * 0.525, y: s * 0.845, width: s * 0.10, height: s * 0.065),
            cornerSize: CGSize(width: s * 0.032, height: s * 0.032))

        // Painted part by part rather than unioned into one path. A single unioned
        // path looked wrong wherever two parts overlapped (a dark notch where the
        // ear met the head) and the fill rule did not fix it; two opaque fills of
        // the same colour cannot interact, and look identical.
        for part in [
            twitched(ear(mirror: false),
                     pivot: CGPoint(x: s * 0.36, y: s * 0.26),
                     angle: -b.ear * 0.14),
            ear(mirror: true),
            body,
            head,
            paws,
            tail.strokedPath(StrokeStyle(lineWidth: s * 0.048,
                                         lineCap: .round, lineJoin: .round)),
        ] {
            context.fill(part, with: .color(ink))
        }

        drawMarkings(&context, s: s, lift: lift, headLift: headLift, blink: b.blink)
    }
    /// The white coat, painted over the silhouette.
    ///
    /// Everything here is a fill in `paper` on top of `ink`, in the order a
    /// tuxedo pattern reads: bib, then the socks over it, then the face.
    ///
    /// The widths matter more than the shapes. The first version's white covered
    /// about a third of the cat and read as a white cat with black shoulders;
    /// Apollo's white is a narrow stripe on the face and a narrow chest, so
    /// everything here is deliberately thin and it is easy to overcorrect.
    private func drawMarkings(_ context: inout GraphicsContext, s: CGFloat,
                              lift: CGFloat, headLift: CGFloat, blink: Double) {
        // The bib: white from the chin down the front, about a quarter of the
        // width, sitting well inside the black shoulders.
        var bib = Path()
        bib.move(to: CGPoint(x: s * 0.500, y: s * 0.478))
        bib.addCurve(
            to: CGPoint(x: s * 0.418, y: s * 0.700),
            control1: CGPoint(x: s * 0.428, y: s * 0.530),
            control2: CGPoint(x: s * 0.412, y: s * 0.620))
        bib.addCurve(
            to: CGPoint(x: s * 0.500, y: s * 0.842),
            control1: CGPoint(x: s * 0.426, y: s * 0.788),
            control2: CGPoint(x: s * 0.462, y: s * 0.842))
        bib.addCurve(
            to: CGPoint(x: s * 0.582, y: s * 0.700),
            control1: CGPoint(x: s * 0.538, y: s * 0.842),
            control2: CGPoint(x: s * 0.574, y: s * 0.788))
        bib.addCurve(
            to: CGPoint(x: s * 0.500, y: s * 0.478),
            control1: CGPoint(x: s * 0.588, y: s * 0.620),
            control2: CGPoint(x: s * 0.572, y: s * 0.530))
        bib.closeSubpath()
        context.fill(bib, with: .color(paper))

        // The socks: white front legs, not just white feet.
        var socks = Path()
        socks.addRoundedRect(
            in: CGRect(x: s * 0.404, y: s * 0.772, width: s * 0.052, height: s * 0.104),
            cornerSize: CGSize(width: s * 0.024, height: s * 0.024))
        socks.addRoundedRect(
            in: CGRect(x: s * 0.544, y: s * 0.772, width: s * 0.052, height: s * 0.104),
            cornerSize: CGSize(width: s * 0.024, height: s * 0.024))
        socks.addRoundedRect(
            in: CGRect(x: s * 0.375, y: s * 0.845, width: s * 0.10, height: s * 0.065),
            cornerSize: CGSize(width: s * 0.032, height: s * 0.032))
        socks.addRoundedRect(
            in: CGRect(x: s * 0.525, y: s * 0.845, width: s * 0.10, height: s * 0.065),
            cornerSize: CGSize(width: s * 0.032, height: s * 0.032))
        context.fill(socks, with: .color(paper))

        // The face white, as ONE shape: the blaze running down and flaring out
        // into the muzzle. Drawn as two separate shapes it looked like a spike
        // stuck on top of an oval — Apollo's white is continuous from the forehead
        // to the chin, roughly parallel-sided between the eyes and only flaring
        // where it reaches the cheeks.
        var face = Path()
        face.move(to: CGPoint(x: s * 0.478, y: s * (0.250 + headLift)))
        face.addLine(to: CGPoint(x: s * 0.522, y: s * (0.250 + headLift)))
        face.addCurve(
            to: CGPoint(x: s * 0.548, y: s * (0.398 + headLift)),
            control1: CGPoint(x: s * 0.528, y: s * (0.310 + headLift)),
            control2: CGPoint(x: s * 0.548, y: s * (0.356 + headLift)))
        face.addCurve(
            to: CGPoint(x: s * 0.604, y: s * (0.440 + headLift)),
            control1: CGPoint(x: s * 0.566, y: s * (0.408 + headLift)),
            control2: CGPoint(x: s * 0.592, y: s * (0.420 + headLift)))
        face.addCurve(
            to: CGPoint(x: s * 0.500, y: s * (0.486 + headLift)),
            control1: CGPoint(x: s * 0.592, y: s * (0.470 + headLift)),
            control2: CGPoint(x: s * 0.552, y: s * (0.486 + headLift)))
        face.addCurve(
            to: CGPoint(x: s * 0.396, y: s * (0.440 + headLift)),
            control1: CGPoint(x: s * 0.448, y: s * (0.486 + headLift)),
            control2: CGPoint(x: s * 0.408, y: s * (0.470 + headLift)))
        face.addCurve(
            to: CGPoint(x: s * 0.452, y: s * (0.398 + headLift)),
            control1: CGPoint(x: s * 0.408, y: s * (0.420 + headLift)),
            control2: CGPoint(x: s * 0.434, y: s * (0.408 + headLift)))
        face.addCurve(
            to: CGPoint(x: s * 0.478, y: s * (0.250 + headLift)),
            control1: CGPoint(x: s * 0.452, y: s * (0.356 + headLift)),
            control2: CGPoint(x: s * 0.472, y: s * (0.310 + headLift)))
        face.closeSubpath()
        context.fill(face, with: .color(paper))

        // Whiskers. Apollo's are white and long enough to reach past the mask, so
        // the inner half sits on black fur and the outer half on the background —
        // no single colour works for both, and the outer half is what reads as
        // "whiskers" at this size, so they stay in the coat colour. Three per
        // side: five reads as a scribble.
        var whiskers = Path()
        for mirror in [false, true] {
            func x(_ v: CGFloat) -> CGFloat { mirror ? s - v * s : v * s }
            whiskers.move(to: CGPoint(x: x(0.352), y: s * (0.406 + headLift)))
            whiskers.addLine(to: CGPoint(x: x(0.150), y: s * (0.368 + headLift)))
            whiskers.move(to: CGPoint(x: x(0.352), y: s * (0.426 + headLift)))
            whiskers.addLine(to: CGPoint(x: x(0.155), y: s * (0.446 + headLift)))
            whiskers.move(to: CGPoint(x: x(0.356), y: s * (0.442 + headLift)))
            whiskers.addLine(to: CGPoint(x: x(0.192), y: s * (0.528 + headLift)))
        }
        context.stroke(whiskers, with: .color(ink.opacity(0.7)),
                       lineWidth: max(1, s * 0.011))

        drawFace(&context, s: s, headLift: headLift, blink: blink)
    }

    /// Eyes, nose and mouth.
    ///
    /// These used to be cut out of the silhouette in the background colour, which
    /// is why they were monochrome. Apollo has yellow-green eyes and a pink nose,
    /// so they are drawn as their own shapes now.
    private func drawFace(_ context: inout GraphicsContext, s: CGFloat,
                          headLift: CGFloat, blink: Double) {
        let eyeY = s * (0.344 + headLift)
        let eyeRX = s * 0.038
        // A blink closes the eye to a line rather than hiding it, so the eyes stay
        // where they are and the face does not shift.
        let eyeRY = blink > 0.5 ? s * 0.006 : s * 0.029

        for cx in [s * 0.416, s * 0.584] {
            let iris = CGRect(x: cx - eyeRX, y: eyeY - eyeRY, width: eyeRX * 2, height: eyeRY * 2)
            context.fill(Path(ellipseIn: iris), with: .color(eyeAmber))
            // A vertical slit at full width would be correct for a cat in daylight
            // and read as a scratch at this size, so the pupil is a narrow ellipse.
            if blink <= 0.5 {
                context.fill(
                    Path(ellipseIn: CGRect(x: cx - s * 0.009, y: eyeY - eyeRY * 0.76,
                                           width: s * 0.018, height: eyeRY * 1.52)),
                    with: .color(scheme == .dark ? Color(white: 0.10) : Color(white: 0.12)))
            }
        }

        // The nose, drawn as a cat nose rather than as a rounded rectangle — the
        // rectangle came out as a pink bar. A real one is a rounded triangle:
        // broad and slightly convex across the top, tapering to a soft point at
        // the bottom where the mouth starts.
        let nx = s * 0.500
        let ny = s * (0.396 + headLift)
        let nw = s * 0.052
        let nh = s * 0.030
        var nose = Path()
        nose.move(to: CGPoint(x: nx - nw / 2, y: ny))
        nose.addQuadCurve(to: CGPoint(x: nx + nw / 2, y: ny),
                          control: CGPoint(x: nx, y: ny - nh * 0.42))
        nose.addQuadCurve(to: CGPoint(x: nx, y: ny + nh),
                          control: CGPoint(x: nx + nw * 0.50, y: ny + nh * 0.62))
        nose.addQuadCurve(to: CGPoint(x: nx - nw / 2, y: ny),
                          control: CGPoint(x: nx - nw * 0.50, y: ny + nh * 0.62))
        nose.closeSubpath()
        context.fill(nose, with: .color(nosePink))

        // Mouth: two arcs from the nose's point. Thin and only lightly dark — at
        // full weight on the white muzzle they read as a handlebar moustache.
        let mx = nx
        let my = ny + nh
        var mouth = Path()
        mouth.move(to: CGPoint(x: mx, y: my))
        mouth.addQuadCurve(to: CGPoint(x: mx - s * 0.044, y: my + s * 0.018),
                           control: CGPoint(x: mx - s * 0.022, y: my + s * 0.026))
        mouth.move(to: CGPoint(x: mx, y: my))
        mouth.addQuadCurve(to: CGPoint(x: mx + s * 0.044, y: my + s * 0.018),
                           control: CGPoint(x: mx + s * 0.022, y: my + s * 0.026))
        context.stroke(mouth, with: .color(ink.opacity(0.55)),
                       style: StrokeStyle(lineWidth: max(1, s * 0.010), lineCap: .round))
    }
}

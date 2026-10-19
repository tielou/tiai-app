import SwiftUI

/// The cat that sits on an empty chat.
///
/// The first version was three filled ellipses stacked into a snowman, and it read
/// as a rendering error rather than a cat. This is drawn as a single filled
/// silhouette — head, ears, body, tail and paws unioned into one path — with the
/// face cut out of it in the background colour. One silhouette means no seams
/// where shapes overlap, and it stays crisp at any size.
///
/// It is drawn rather than a GIF so it follows the colour scheme, scales without
/// blurring, and has no fixed background to fight the view behind it.
///
/// Three small movements, all slow: it breathes, blinks every few seconds, and
/// sways its tail. Under Reduce Motion it sits still with its eyes open, which is
/// the same cat minus the motion rather than a different layout.
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

    /// The body. `Color.primary` at full strength is harsh for a decorative mark,
    /// and a flat grey is invisible in light mode, so it is picked per appearance.
    private var ink: Color {
        scheme == .dark ? Color(white: 0.86) : Color(white: 0.22)
    }

    /// The face is cut out of the silhouette, so it has to be roughly the colour
    /// the cat is sitting on. The app's backgrounds are near-black and near-white,
    /// which makes an approximation good enough and keeps this independent of
    /// whatever is behind it.
    private var paper: Color {
        scheme == .dark ? Color(white: 0.06) : Color(white: 0.98)
    }

    // MARK: - Timing

    private struct Beat {
        let breath: Double
        let tail: Double
        let blink: Double
        let ear: Double
    }

    /// Blink and ear twitch are windows in a slow cycle rather than a smooth wave:
    /// a cat that pulses continuously looks mechanical, and one that does something
    /// occasionally looks alive.
    private func beat(at date: Date) -> Beat {
        guard !reduceMotion else { return Beat(breath: 0, tail: 0, blink: 0, ear: 0) }
        let t = date.timeIntervalSinceReferenceDate
        let cycle = t.truncatingRemainder(dividingBy: 4.6)
        let blink = (cycle > 4.10 && cycle < 4.26) ? 1.0 : 0.0
        let twitch = t.truncatingRemainder(dividingBy: 9.3)
        let ear = (twitch > 6.0 && twitch < 6.34) ? sin((twitch - 6.0) / 0.34 * .pi) : 0
        return Beat(
            breath: sin(t * 1.25),
            tail: sin(t * 1.05),
            blink: blink,
            ear: ear
        )
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size side: CGFloat, at date: Date) {
        let s = side
        let b = beat(at: date)
        let stroke = max(1.5, s * 0.030)

        // Breathing lifts the head a fraction and widens the body a fraction,
        // anchored at the ground so the cat does not slide up and down.
        let lift = b.breath * s * 0.008
        let widen = 1 + b.breath * 0.012

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
        // has no notches.
        func ear(mirror: Bool) -> Path {
            func x(_ v: CGFloat) -> CGFloat { mirror ? s - v * s : v * s }
            var p = Path()
            p.move(to: CGPoint(x: x(0.335), y: (0.27 + lift / s) * s))
            p.addLine(to: CGPoint(x: x(0.285), y: (0.075 + lift / s) * s))
            p.addLine(to: CGPoint(x: x(0.475), y: (0.20 + lift / s) * s))
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
            x: s * 0.305, y: s * (0.155 + lift / s),
            width: s * 0.39, height: s * 0.39
        ))

        // The tail is a stroked curve turned into a filled shape so it unions with
        // the body instead of being a separate outline on top of it.
        //
        // The root has to be *inside* the body, not on its edge. The egg narrows
        // toward the base, so at this height the silhouette's right side is near
        // x 0.62 — starting the tail at 0.70 left it floating a few points clear of
        // the cat, which reads as a detached tail.
        let tailRoot = CGPoint(x: s * 0.60, y: s * 0.865)
        var tail = Path()
        tail.move(to: tailRoot)
        tail.addCurve(
            to: CGPoint(x: s * 0.90, y: s * 0.60),
            control1: CGPoint(x: s * 0.86, y: s * 0.87),
            control2: CGPoint(x: s * 0.94, y: s * 0.74)
        )
        let sway = b.tail * 0.16
        tail = tail.applying(
            CGAffineTransform(translationX: tailRoot.x, y: tailRoot.y)
                .rotated(by: sway)
                .translatedBy(x: -tailRoot.x, y: -tailRoot.y)
        )

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
            tail.strokedPath(StrokeStyle(lineWidth: s * 0.062,
                                         lineCap: .round, lineJoin: .round)),
        ] {
            context.fill(part, with: .color(ink))
        }

        // Whiskers live outside the silhouette, so they are strokes in the body
        // colour rather than cut-outs.
        var whiskers = Path()
        for mirror in [false, true] {
            func x(_ v: CGFloat) -> CGFloat { mirror ? s - v * s : v * s }
            whiskers.move(to: CGPoint(x: x(0.320), y: s * 0.400))
            whiskers.addLine(to: CGPoint(x: x(0.185), y: s * 0.375))
            whiskers.move(to: CGPoint(x: x(0.320), y: s * 0.430))
            whiskers.addLine(to: CGPoint(x: x(0.190), y: s * 0.450))
        }
        context.stroke(whiskers, with: .color(ink.opacity(0.75)),
                       lineWidth: max(1, s * 0.014))

        // Face, cut out of the silhouette.
        let eyeY = s * (0.355 + lift / s)
        let eyeRY = s * (b.blink > 0.5 ? 0.006 : 0.034)
        var eyes = Path()
        for cx in [s * 0.425, s * 0.575] {
            eyes.addEllipse(in: CGRect(x: cx - s * 0.028, y: eyeY - eyeRY,
                                       width: s * 0.056, height: eyeRY * 2))
        }
        context.fill(eyes, with: .color(paper))

        var face = Path()
        // Nose: a small rounded triangle.
        face.move(to: CGPoint(x: s * 0.478, y: s * 0.415))
        face.addLine(to: CGPoint(x: s * 0.522, y: s * 0.415))
        face.addLine(to: CGPoint(x: s * 0.500, y: s * 0.442))
        face.closeSubpath()
        context.fill(face, with: .color(paper))

        // Mouth: two arcs meeting under the nose.
        var mouth = Path()
        mouth.move(to: CGPoint(x: s * 0.50, y: s * 0.444))
        mouth.addQuadCurve(to: CGPoint(x: s * 0.44, y: s * 0.462),
                           control: CGPoint(x: s * 0.47, y: s * 0.470))
        mouth.move(to: CGPoint(x: s * 0.50, y: s * 0.444))
        mouth.addQuadCurve(to: CGPoint(x: s * 0.60, y: s * 0.462),
                           control: CGPoint(x: s * 0.53, y: s * 0.470))
        context.stroke(mouth, with: .color(paper),
                       style: StrokeStyle(lineWidth: max(1, s * 0.018), lineCap: .round))
    }
}

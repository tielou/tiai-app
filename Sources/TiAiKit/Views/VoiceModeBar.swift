#if os(iOS)
import SwiftUI

/// The hands-free loop's strip (issue #49): what the loop is doing right now,
/// a way to stop the recording without killing the whole mode, and a way out.
///
/// It appears only while the loop runs or has something to complain about —
/// a permanent "voice mode" bar on an ordinary chat is one more control nobody
/// asked for. The circle button never changes size between states, because the
/// composer's mic learned the hard way that a control that resizes under a
/// gesture gets torn down mid-press (`micCircle` in `ComposerView`).
struct VoiceModeBar: View {
    let controller: VoiceModeController

    var body: some View {
        VStack(spacing: 0) {
            if let failure = controller.error {
                HStack(spacing: 10) {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    // A banner the user has read has served its purpose
                    // (issue #9's rule, applied to a loop that keeps running
                    // behind it — dismissing the banner must not stop the mic).
                    Button {
                        controller.dismissError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Dismiss voice mode error")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.red.opacity(0.08))
                .accessibilityIdentifier("voiceModeError")
            }
            if controller.phase != .off {
                HStack(spacing: 10) {
                    circle
                    VStack(alignment: .leading, spacing: 1) {
                        Text(controller.statusText)
                            .font(.footnote.weight(.medium))
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        controller.stop()
                    } label: {
                        Text("Stop")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("voiceModeStop")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityIdentifier("voiceModeBar")
            }
        }
        .animation(.snappy(duration: 0.18), value: controller.phase)
    }

    /// Fixed 34pt in every state; only the fill and the glyph change. Tap
    /// while the mic is open means "stop the recording" (the loop then sends
    /// what was heard); any other phase means "stop the whole mode", which is
    /// what `toggle` encodes.
    private var circle: some View {
        let listening = controller.phase == .listening
        let busy = controller.phase == .transcribing
        return Button {
            controller.toggle()
        } label: {
            ZStack {
                Image(systemName: "mic")
                    .opacity(listening || busy ? 0 : 1)
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(listening ? 1 : 0)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(controller.phase == .thinking || controller.phase == .speaking ? 1 : 0)
                ProgressView().controlSize(.small).opacity(busy ? 1 : 0)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(listening ? Color.white : Color.secondary)
            .frame(width: 34, height: 34)
            .background(
                Circle().fill(listening
                    ? AnyShapeStyle(.red)
                    : AnyShapeStyle(.quaternary.opacity(0.7))))
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? "Stop recording" : "Voice mode")
        .accessibilityIdentifier("voiceModeCircle")
    }

    /// What the tap on the circle will do, so the button is never a guess.
    private var hint: String {
        switch controller.phase {
        case .listening: "Tap to send"
        case .transcribing: "One moment…"
        case .thinking: "Reading your question"
        case .speaking: "Answering"
        case .off: ""
        }
    }
}
#endif

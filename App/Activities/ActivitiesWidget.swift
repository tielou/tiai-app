import SwiftUI
import WidgetKit
import ActivityKit
import TiAiKit

/// The Live Activity shown while an answer is generating.
///
/// Deliberately spare: it has to be legible at Dynamic Island size, where there
/// is room for a couple of words and nothing else. The detail lives in the app;
/// this exists to answer "is it still going" without opening anything.
struct GenerationActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GenerationActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text(context.attributes.chatTitle)
                    .font(.headline).lineLimit(1)
                HStack {
                    Text("\(context.state.phase.rawValue) · \(context.attributes.model)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    // A number that grows is the whole point: it is what separates
                    // "still working" from "stuck" when the app is not open.
                    Text("\(context.state.characters) chars")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                if context.state.phase == .finished || context.state.phase == .stopped {
                    // A bar that keeps filling after the run ended reads as a
                    // bug. The number already stopped moving; say so in words.
                    Label("\(context.state.characters) characters",
                          systemImage: context.state.phase == .finished
                              ? "checkmark.circle.fill" : "stop.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(context.state.phase == .finished ? .green : .secondary)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(.primary)
                }
            }
            .padding(12)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.chatTitle)
                        .font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.characters)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.state.phase.rawValue) · \(context.attributes.model)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "cat.fill")
            } compactTrailing: {
                // "F" for Finished read as a glitch. A tick needs no legend at
                // Island size; a letter does.
                if context.state.phase == .finished {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                } else if context.state.phase == .stopped {
                    Image(systemName: "stop.circle").font(.system(size: 12))
                } else {
                    Text("…").font(.system(size: 13, weight: .semibold))
                }
            } minimal: {
                Image(systemName: "cat.fill")
            }
            .widgetURL(context.attributes.chatID
                .flatMap { URL(string: "tiai://chat?id=\($0)") }
                ?? URL(string: "tiai://chat"))
            .keylineTint(.accentColor)
        }
    }
}

@main
struct TiAiActivitiesBundle: WidgetBundle {
    var body: some Widget {
        GenerationActivityWidget()
    }
}

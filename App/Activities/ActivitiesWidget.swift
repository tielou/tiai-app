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
                ProgressView().progressViewStyle(.linear).tint(.primary)
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
                Text(context.state.phase == .writing ? "…" : String(context.state.phase.rawValue.prefix(1)))
                    .font(.system(size: 11, weight: .semibold))
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

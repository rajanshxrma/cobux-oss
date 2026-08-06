import WidgetKit
import SwiftUI

@main
struct CobuxWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CobuxWatchGlanceWidget()
    }
}

struct CobuxWatchGlanceWidget: Widget {
    let kind: String = "CobuxWatchGlanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CobuxWatchProvider()) { entry in
            CobuxWatchGlanceEntryView(entry: entry)
        }
        .configurationDisplayName("Cobux")
        .description("Your streak, due reviews, and today's quote.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

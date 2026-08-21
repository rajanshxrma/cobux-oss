import WidgetKit
import SwiftUI

@main
struct CobuxWidgetBundle: WidgetBundle {
    var body: some Widget {
        CobuxHighlightWidget()
        CobuxQuickCheckWidget()
        CobuxQuizLiveActivity()
    }
}

import SwiftUI

/// Keeps secondary actions in the system overflow as bars move between their axes.
struct OverflowToolbar<Content: View>: ToolbarContent {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
#if IPHONE_DUO_LAYOUTS
        if #available(iOS 27.1, *) {
            ToolbarOverflowMenu { content }
        } else {
            legacyMenu
        }
#else
        legacyMenu
#endif
    }

    private var legacyMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu { content } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

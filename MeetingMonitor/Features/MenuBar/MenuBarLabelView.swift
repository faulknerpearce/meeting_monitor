import AppKit
import SwiftUI

struct MenuBarLabelView: View {
    let meetings: [Meeting]
    let showSource: Bool
    let now: Date

    var body: some View {
        let text = MenuBarStatusRenderer.labelText(meetings: meetings, showSource: showSource, now: now)
        Image(nsImage: MenuBarStatusRenderer.image(text: text))
            .accessibilityLabel(text)
            // New identity per text so the status item redraws with the new image.
            .id(text)
    }
}

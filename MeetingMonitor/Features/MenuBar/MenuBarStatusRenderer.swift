import AppKit

enum MenuBarStatusRenderer {
    static func image(meetings: [Meeting], showSource: Bool) -> NSImage {
        let height: CGFloat = 22
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textColor = NSColor.labelColor

        guard let next = MeetingFormat.nextMeeting(from: meetings) else {
            return placeholderImage(height: height, font: font, textColor: textColor)
        }

        let text = formatLabel(next: next, showSource: showSource)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]

        let size = text.size(withAttributes: attrs)
        let width = min(ceil(size.width + 6), 220)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.isTemplate = true
        image.lockFocus()
        defer { image.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        text.draw(
            at: NSPoint(x: 3, y: (height - size.height) / 2 - 0.5),
            withAttributes: attrs
        )
        return image
    }

    /// Menu bar: "Next meeting · 4:30 PM" (no meeting title).
    private static func formatLabel(next: Meeting, showSource: Bool) -> String {
        let time = MeetingFormat.menuBarTime(for: next)
        if showSource {
            let sourceIcon = next.source == .googleCalendar ? "G" : "S"
            return "Next meeting · \(time) · \(sourceIcon)"
        }
        return "Next meeting · \(time)"
    }

    private static func placeholderImage(
        height: CGFloat,
        font: NSFont,
        textColor: NSColor
    ) -> NSImage {
        let label = "No meetings"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let size = label.size(withAttributes: attrs)
        let width = ceil(size.width + 6)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.isTemplate = true
        image.lockFocus()
        defer { image.unlockFocus() }
        label.draw(
            at: NSPoint(x: 3, y: (height - size.height) / 2 - 0.5),
            withAttributes: attrs
        )
        return image
    }
}

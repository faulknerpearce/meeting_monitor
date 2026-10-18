import AppKit

@MainActor
enum MenuBarStatusRenderer {
    static let height: CGFloat = 22
    static let maxWidth: CGFloat = 220

    /// "Next meeting · 4:30 PM" (no meeting title), optionally with a source badge.
    static func labelText(meetings: [Meeting], showSource: Bool, now: Date = Date()) -> String {
        guard let next = MeetingFormat.nextMeeting(from: meetings, now: now) else {
            return "No meetings"
        }
        let time = MeetingFormat.menuBarTime(for: next, now: now)
        return showSource ? "Next meeting · \(time) · \(next.source.badge)" : "Next meeting · \(time)"
    }

    /// Template image of `text`; the menu bar tints it for the current appearance.
    static func image(text: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        let textSize = text.size(withAttributes: attributes)
        let size = NSSize(width: min(ceil(textSize.width + 6), maxWidth), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            text.draw(at: NSPoint(x: 3, y: (rect.height - textSize.height) / 2 - 0.5), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

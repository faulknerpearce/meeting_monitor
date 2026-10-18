import os

extension Logger {
    static let appSubsystem = "com.meetingmonitor.app"

    init(category: String) {
        self.init(subsystem: Logger.appSubsystem, category: category)
    }
}

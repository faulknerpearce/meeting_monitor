# Contributing to Meeting Monitor

Thanks for helping improve Meeting Monitor. This project is a native macOS menu bar app; small, focused changes are easiest to review.

## Development setup

1. Install [Xcode 15+](https://developer.apple.com/xcode/) on macOS 14+.
2. Clone the repo and open the committed Xcode project.
3. Select the **MeetingMonitor** scheme → **My Mac** → Run.

```bash
git clone https://github.com/faulknerpearce/meeting_monitor.git
cd meeting_monitor
open MeetingMonitor.xcodeproj
```

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After adding or removing source files, regenerate it and commit the result:

```bash
brew install xcodegen   # once
make project
```

To regenerate the app icon:

```bash
swift Scripts/generate_icon.swift MeetingMonitor/Resources/Assets.xcassets/AppIcon.appiconset
```

## Before you open a PR

- Keep changes focused on one concern.
- Prefer clear commit messages that explain *why*.
- Run the same checks as CI (`brew install swiftlint swiftformat` once):

```bash
make lint
make format   # `make format-fix` applies the formatting
make test
```

## Pull requests

1. Fork the repository.
2. Create a branch: `git checkout -b feature/your-feature-name`
3. Open a PR against `faulknerpearce/meeting_monitor:main`
4. Describe what changed and how you tested it.

## Code guidelines

- Swift 5.10+, macOS 14+
- Match existing structure: `App/`, `Features/{Calendars,MenuBar,Settings}`, `Helpers/`
- Prefer `@MainActor` for UI-adjacent services
- Use `Logger(category:)` (subsystem `com.meetingmonitor.app`) instead of `print`
- Do not commit credentials, OAuth secrets, or local Application Support files

## Reporting bugs

Use [GitHub Issues](https://github.com/faulknerpearce/meeting_monitor/issues). Include macOS version, steps to reproduce, and whether Google Calendar, Spacemail, or both are configured.

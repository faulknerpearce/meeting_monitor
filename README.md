# Meeting Monitor

A native macOS menu bar app that shows upcoming meetings from **Google Calendar** and **Spacemail** (CalDAV).

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.10-orange)](https://swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub](https://img.shields.io/badge/github-faulknerpearce%2Fmeeting__monitor-blue?logo=github)](https://github.com/faulknerpearce/meeting_monitor)

## Overview

Meeting Monitor sits in the macOS menu bar and shows the next meeting (`Next meeting · {time}`, optional source badge). Timed meetings take precedence; all-day events show only when nothing timed is left. Open the dropdown for a day navigator, join links, refresh, source toggles, and preferences. Credentials are stored under **Application Support** (not Keychain).

## Features

| Area | Details |
|------|---------|
| **Menu bar** | `Next meeting · {time}` (+ optional `G`/`S` source badge); no meeting title in the bar |
| **Dropdown** | Day navigator with all-day + timed list, join link, refresh, source toggles |
| **Google Calendar** | OAuth refresh-token based access to primary calendar |
| **Spacemail** | CalDAV discovery + time-range event fetch |
| **Polling** | Faster while the menu is open; exponential backoff on errors; sleep / wake aware; a source that fails keeps its last good meetings |
| **Agent app** | No Dock icon by default (`LSUIElement`) |
| **Privacy** | Credentials in the app container's Application Support (`0600`); OAuth client secret not in UserDefaults; sandboxed; no on-disk HTTP cache |

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ (for building from source)
- Swift 5.10+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you add or remove source files (`brew install xcodegen`)

## Installation

### Build from Source

```bash
git clone https://github.com/faulknerpearce/meeting_monitor.git
cd meeting_monitor
open MeetingMonitor.xcodeproj
```

In Xcode: select **MeetingMonitor** scheme → **My Mac** → Run (⌘R). The app appears in the menu bar (no Dock icon).

`MeetingMonitor.xcodeproj` is generated from `project.yml` by XcodeGen and committed. After adding or removing source files, run `make project` to regenerate it.

### Command Line Build

```bash
make build   # Debug .app (ad-hoc signed) in build/DerivedData
make run     # build and launch
```

### Tests and checks

```bash
make test    # unit tests
make lint    # SwiftLint (strict)
make format  # SwiftFormat lint
```

## Configuration

### Google Calendar (OAuth)

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the **Google Calendar API**.
2. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
3. Application type: **Desktop app** (loopback `http://127.0.0.1` redirects are allowed automatically).
4. Configure the OAuth consent screen (External is fine for personal use; add your Google account as a test user while in Testing).
5. In Meeting Monitor → Preferences, paste the **Client ID** (and **Client Secret** if Google shows one).
6. Click **Sign in with Google…**, complete consent in the browser, then return to the app.

Tokens (refresh + access) are stored under **Application Support** inside the app's sandbox container (`~/Library/Containers/com.meetingmonitor.app/Data/Library/Application Support/MeetingMonitor/`, mode `0600`). Keychain is avoided because unsigned/Debug builds re-prompt on every launch. Spacemail stays email/password over CalDAV.

### Spacemail

1. Use your Spacemail email and password (or app password if required).
2. CalDAV endpoint: `https://caldav.spacemail.com/dav.php/` (the app uses this path; bare `/` only redirects).

## Project layout

```
MeetingMonitor/
  App/                 # Entry point, AppModel, AppDelegate
  Features/
    Calendars/         # Poller, Google + Spacemail clients, iCalendar + RRULE parsing, models
    MenuBar/           # Label, panel, status renderer
    Settings/          # Preferences + AppSettings
  Helpers/             # Application Support CredentialStore, logging
  Shared/              # Panel styling shared with token_monitor
  Resources/           # Info.plist, entitlements, assets
MeetingMonitorTests/   # Unit tests; Fixtures/ holds sample payloads
Scripts/               # generate_icon.swift
project.yml            # XcodeGen spec for MeetingMonitor.xcodeproj
```

Same shape as `coin_monitor` and `grok_monitor`: feature folders, poller, menu bar renderer, credential/settings store, Xcode + SPM package.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security issues: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Austin Faulkner-Pearce.

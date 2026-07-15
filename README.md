# Meeting Monitor

A native macOS menu bar app that shows upcoming meetings from **Google Calendar** and **Spacemail** (CalDAV).

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.10-orange)](https://swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub](https://img.shields.io/badge/github-faulknerpearce%2Fmeeting__monitor-blue?logo=github)](https://github.com/faulknerpearce/meeting_monitor)

## Overview

Meeting Monitor sits in the macOS menu bar and shows the next meeting (`Next meeting · {time}`, optional source badge). Open the dropdown for a day navigator, join links, refresh, source toggles, and preferences. Credentials are stored under **Application Support** (not Keychain).
## Features

| Area | Details |
|------|---------|
| **Menu bar** | `Next meeting · {time}` (+ optional `G`/`S` source badge); no meeting title in the bar |
| **Dropdown** | Day navigator with all-day + timed list, join link, refresh, source toggles |
| **Google Calendar** | OAuth refresh-token based access to primary calendar |
| **Spacemail** | CalDAV discovery + time-range event fetch |
| **Polling** | Faster while the menu is open; exponential backoff on errors; sleep / wake aware |
| **Agent app** | No Dock icon by default (`LSUIElement`) |
| **Privacy** | Credentials in Application Support (`0600`); OAuth client secret not in UserDefaults; sandboxed network client |

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ (for building from source)
- Swift 5.10+

## Installation

### Build from Source

```bash
git clone https://github.com/faulknerpearce/meeting_monitor.git
cd meeting_monitor

# Generate Xcode project (required after adding/removing source files)
python3 Scripts/generate_xcodeproj.py

# Open in Xcode
open MeetingMonitor.xcodeproj
```

In Xcode: select **MeetingMonitor** scheme → **My Mac** → Run (⌘R). The app appears in the menu bar (no Dock icon).

### Command Line Build

```bash
python3 Scripts/generate_xcodeproj.py

xcodebuild \
  -project MeetingMonitor.xcodeproj \
  -scheme MeetingMonitor \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" \
  build

open "build/DerivedData/Build/Products/Debug/Meeting Monitor.app"
```

### Tests

```bash
python3 Scripts/generate_xcodeproj.py

xcodebuild \
  -project MeetingMonitor.xcodeproj \
  -scheme MeetingMonitor \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" \
  test
```

## Configuration

### Google Calendar (OAuth)

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the **Google Calendar API**.
2. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
3. Application type: **Desktop app** (loopback `http://127.0.0.1` redirects are allowed automatically).
4. Configure the OAuth consent screen (External is fine for personal use; add your Google account as a test user while in Testing).
5. In Meeting Monitor → Preferences, paste the **Client ID** (and **Client Secret** if Google shows one).
6. Click **Sign in with Google…**, complete consent in the browser, then return to the app.

Tokens (refresh + access) are stored under **Application Support** (`~/Library/Application Support/MeetingMonitor/`, mode `0600`). Keychain is avoided because unsigned/Debug builds re-prompt on every launch. Spacemail stays email/password over CalDAV.

### Spacemail

1. Use your Spacemail email and password (or app password if required).
2. CalDAV endpoint: `https://caldav.spacemail.com/dav.php/` (the app uses this path; bare `/` only redirects).

## Project layout

```
MeetingMonitor/
  App/                 # Entry point, AppModel, AppDelegate
  Features/
    Calendars/         # Poller, Google + Spacemail clients, models
    MenuBar/           # Label, panel, status renderer
    Settings/          # Preferences + AppSettings
  Helpers/             # Application Support CredentialStore
  Fixtures/            # Sample payloads for tests
  Resources/           # Info.plist, entitlements, assets
MeetingMonitorTests/   # Parsing / format unit tests
Scripts/               # generate_xcodeproj.py, generate_icon.swift
```

Same shape as `coin_monitor` and `grok_monitor`: feature folders, poller, menu bar renderer, credential/settings store, Xcode + SPM package.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security issues: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Austin Faulkner-Pearce.

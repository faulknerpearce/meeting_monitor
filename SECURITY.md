# Security Policy

## Supported versions

Security fixes are applied on the latest `main` branch. Please upgrade to the newest commit when a fix is published.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Instead, report privately via GitHub Security Advisories:

1. Open https://github.com/faulknerpearce/meeting_monitor/security/advisories/new
2. Include steps to reproduce, impact, and affected versions/commits if known.

If advisories are unavailable, email the maintainer listed on the GitHub profile for this repository.

## What to expect

- Acknowledgement when the report is received
- A fix or mitigation plan when the issue is confirmed
- Credit in the advisory or release notes if you want it

## Security considerations

### Network

- **Google Calendar** — OAuth 2.0 (PKCE + loopback) and Calendar API over HTTPS
- **Spacemail** — CalDAV (`https://caldav.spacemail.com`) with Basic auth over HTTPS
- Sandboxed app: `network.client` + `network.server` (loopback only for OAuth callback)

### Credentials

- Stored under `~/Library/Application Support/MeetingMonitor/` with file mode `0600` and directory `0700`
- OAuth client secret is **not** stored in UserDefaults
- Do not commit real OAuth client IDs/secrets, mailbox passwords, or `credentials_*.dat` files

### Non-security bugs

Normal bugs and feature requests belong in [GitHub Issues](https://github.com/faulknerpearce/meeting_monitor/issues).

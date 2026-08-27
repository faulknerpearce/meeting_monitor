import SwiftUI

struct PreferencesView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var poller: MeetingPoller
    @ObservedObject var googleClient: GoogleCalendarClient
    @ObservedObject var spacemailClient: SpacemailCalDAVClient

    @State private var spacemailEmail: String = ""
    @State private var spacemailPassword: String = ""
    /// Force the Spacemail credential form open (e.g. after 401 or "Update password").
    @State private var showSpacemailEditor = false

    private var spacemailNeedsReauth: Bool {
        showSpacemailEditor
            || spacemailClient.lastAuthError != nil
            || (poller.lastError?.localizedCaseInsensitiveContains("spacemail") == true
                && poller.lastError?.localizedCaseInsensitiveContains("401") == true)
            || (poller.lastError?.localizedCaseInsensitiveContains("spacemail") == true
                && poller.lastError?.localizedCaseInsensitiveContains("invalid") == true)
    }

    var body: some View {
        Form {
            Section("Google Calendar") {
                if poller.isGoogleConfigured {
                    HStack {
                        Text("Status:")
                            .foregroundStyle(.secondary)
                        Circle()
                            .fill(googleClient.needsReauth ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                        Text(
                            googleClient.needsReauth
                                ? "Needs re-auth · \(googleClient.email ?? "")"
                                : "Connected · \(googleClient.email ?? "")"
                        )
                        .font(.system(size: 12, weight: .medium))
                    }
                    if let err = googleClient.lastAuthError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Disconnect") {
                        googleClient.clearCredentials()
                        Task { await poller.refreshNow() }
                    }
                    .foregroundStyle(.red)

                    Button("Sign in again…") {
                        Task {
                            await googleClient.signInWithGoogle()
                            if googleClient.isConfigured, !googleClient.needsReauth {
                                await poller.refreshNow()
                            }
                        }
                    }
                    .disabled(googleClient.isAuthenticating || googleClient.oauthClientID.isEmpty)
                } else {
                    Text("Sign in with Google to access your primary calendar. Tokens are stored under Application Support.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("OAuth Client ID (Desktop app)", text: $googleClient.oauthClientID)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client Secret (optional for some clients)", text: $googleClient.oauthClientSecret)
                        .textFieldStyle(.roundedBorder)

                    if googleClient.isAuthenticating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for Google sign-in in your browser…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let err = googleClient.lastAuthError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task {
                            await googleClient.signInWithGoogle()
                            if googleClient.isConfigured {
                                await poller.refreshNow()
                            }
                        }
                    } label: {
                        Label(
                            googleClient.isAuthenticating ? "Signing in…" : "Sign in with Google…",
                            systemImage: "person.crop.circle.badge.checkmark"
                        )
                    }
                    .disabled(googleClient.isAuthenticating || googleClient.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Text(googleSetupHelp)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Spacemail Calendar") {
                if poller.isSpacemailConfigured && !spacemailNeedsReauth {
                    HStack {
                        Text("Status:")
                            .foregroundStyle(.secondary)
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Connected · \(poller.spacemailEmail ?? "")")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Button("Disconnect") {
                        spacemailClient.clearCredentials()
                        spacemailPassword = ""
                        Task { await poller.refreshNow() }
                    }
                    .foregroundStyle(.red)

                    Button("Update password…") {
                        spacemailEmail = poller.spacemailEmail ?? spacemailEmail
                        spacemailPassword = ""
                        showSpacemailEditor = true
                    }
                } else {
                    Text("Connect your Spacemail calendar via CalDAV. Use your full Spacemail email and mailbox password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if spacemailNeedsReauth {
                        Text("Saved credentials were rejected by Spacemail. Enter the current password and save again.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    TextField("Email", text: $spacemailEmail)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                    SecureField("Password", text: $spacemailPassword)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)

                    if spacemailClient.isValidating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking CalDAV login…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let err = spacemailClient.lastAuthError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Text("CalDAV: caldav.spacemail.com/dav.php")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(spacemailClient.isValidating ? "Checking…" : "Save & Verify") {
                            Task {
                                let ok = await spacemailClient.saveCredentials(
                                    email: spacemailEmail,
                                    password: spacemailPassword
                                )
                                if ok {
                                    showSpacemailEditor = false
                                    spacemailPassword = ""
                                    await poller.refreshNow()
                                }
                            }
                        }
                        .disabled(
                            spacemailEmail.isEmpty
                                || spacemailPassword.isEmpty
                                || spacemailClient.isValidating
                        )
                    }
                }
            }
            .onAppear {
                if spacemailEmail.isEmpty {
                    spacemailEmail = poller.spacemailEmail
                        ?? spacemailClient.email
                        ?? ""
                }
                if spacemailNeedsReauth {
                    showSpacemailEditor = true
                }
            }

            Section("Refresh") {
                Stepper(value: $settings.activePollSeconds, in: 15...300, step: 15) {
                    Text("While menu open: \(settings.activePollSeconds)s")
                }
                Stepper(value: $settings.idlePollSeconds, in: 30...3600, step: 30) {
                    Text("While idle: \(settings.idlePollSeconds)s")
                }
                Stepper(value: $settings.lookaheadHours, in: AppSettings.lookaheadHoursRange, step: 1) {
                    Text("Look ahead: \(settings.lookaheadHours)h")
                }
                if let last = poller.lastRefreshedAt {
                    HStack {
                        Text("Last refresh:")
                            .foregroundStyle(.secondary)
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let error = poller.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Button("Refresh Now") {
                    Task { await poller.refreshNow() }
                }
                .disabled(poller.isRefreshing)
            }

            Section("Display") {
                Toggle("Show source icon in menu bar", isOn: $settings.showSourceInMenuBar)
                    .toggleStyle(.switch)
                Toggle("Show Google Calendar", isOn: $settings.showGoogleCalendar)
                    .toggleStyle(.switch)
                    .disabled(!poller.isGoogleConfigured)
                Toggle("Show Spacemail", isOn: $settings.showSpacemailCalendar)
                    .toggleStyle(.switch)
                    .disabled(!poller.isSpacemailConfigured)
            }

            Section("System") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 14))
        .padding()
        .frame(minWidth: 420, minHeight: 520)
        .frame(width: 500)
        // Dock hide is handled by PreferencesWindowLifecycle on the window scene.
    }

    private var googleSetupHelp: String {
        """
        Google Cloud Console → create a project → enable Calendar API → Credentials → Create OAuth client ID → Application type: Desktop app. \
        Paste the Client ID (and Client Secret if shown). Loopback redirects (http://127.0.0.1) are used automatically — no redirect URI setup needed for Desktop clients.
        """
    }
}

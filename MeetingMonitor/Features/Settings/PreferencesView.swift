import SwiftUI

struct PreferencesView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var poller: MeetingPoller
    @ObservedObject var googleClient: GoogleCalendarClient
    @ObservedObject var spacemailClient: SpacemailCalDAVClient

    @State private var spacemailEmail: String = ""
    @State private var spacemailPassword: String = ""
    /// Forces the Spacemail credential form open ("Update password…").
    @State private var showSpacemailEditor = false

    /// The last refresh failed because Spacemail refused the stored credentials.
    private var spacemailCredentialsRejected: Bool {
        (poller.error(for: .spacemail) as? CalendarProviderError) == .invalidCredentials
    }

    private var showSpacemailForm: Bool {
        !spacemailClient.isConfigured || showSpacemailEditor || spacemailCredentialsRejected
    }

    var body: some View {
        Form {
            googleSection
            spacemailSection
            refreshSection
            displaySection

            Section("System") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                if let error = settings.launchAtLoginError {
                    errorText(error)
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 14))
        .padding()
        .frame(width: 500)
        .frame(minHeight: 520)
    }

    // MARK: - Google

    private var googleSection: some View {
        Section("Google Calendar") {
            if googleClient.isConfigured {
                HStack {
                    Text("Status:")
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(googleClient.needsReauth ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text("\(googleClient.needsReauth ? "Needs re-auth" : "Connected") · \(googleClient.email ?? "")")
                        .font(.system(size: 12, weight: .medium))
                }
                if let err = googleClient.lastAuthError {
                    errorText(err)
                }
                Button("Disconnect") {
                    googleClient.clearCredentials()
                    Task { await poller.refreshNow() }
                }
                .foregroundStyle(.red)

                signInControls(title: "Sign in again…")
            } else {
                Text("Sign in with Google to access your primary calendar. Tokens are stored under Application Support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("OAuth Client ID (Desktop app)", text: $googleClient.oauthClientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client Secret (optional for some clients)", text: $googleClient.oauthClientSecret)
                    .textFieldStyle(.roundedBorder)

                signInControls(title: "Sign in with Google…")

                Text(Self.googleSetupHelp)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func signInControls(title: String) -> some View {
        if googleClient.isAuthenticating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for Google sign-in in your browser…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { googleClient.cancelSignIn() }
            }
        } else {
            Button {
                Task {
                    await googleClient.signInWithGoogle()
                    if googleClient.isConfigured, !googleClient.needsReauth {
                        await poller.refreshNow()
                    }
                }
            } label: {
                Label(title, systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(googleClient.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let err = googleClient.signInError {
            errorText(err)
        }
    }

    // MARK: - Spacemail

    private var spacemailSection: some View {
        Section("Spacemail Calendar") {
            if !showSpacemailForm {
                HStack {
                    Text("Status:")
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Connected · \(spacemailClient.email ?? "")")
                        .font(.system(size: 12, weight: .medium))
                }
                Button("Disconnect") {
                    spacemailClient.clearCredentials()
                    spacemailPassword = ""
                    Task { await poller.refreshNow() }
                }
                .foregroundStyle(.red)

                Button("Update password…") {
                    spacemailEmail = spacemailClient.email ?? spacemailEmail
                    spacemailPassword = ""
                    showSpacemailEditor = true
                }
            } else {
                spacemailForm
            }
        }
        .onAppear {
            if spacemailEmail.isEmpty {
                spacemailEmail = spacemailClient.email ?? ""
            }
        }
    }

    @ViewBuilder
    private var spacemailForm: some View {
        Text("Connect your Spacemail calendar via CalDAV. Use your full Spacemail email and mailbox password.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if spacemailCredentialsRejected {
            errorText("Spacemail rejected the saved credentials. Enter the current password and save again.")
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
            errorText(err)
        }

        HStack {
            Text("CalDAV: caldav.spacemail.com/dav.php")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            if showSpacemailEditor, spacemailClient.isConfigured {
                Button("Cancel") {
                    showSpacemailEditor = false
                    spacemailPassword = ""
                }
            }
            Button(spacemailClient.isValidating ? "Checking…" : "Save & Verify") {
                Task {
                    let saved = await spacemailClient.saveCredentials(
                        email: spacemailEmail,
                        password: spacemailPassword
                    )
                    if saved {
                        showSpacemailEditor = false
                        spacemailPassword = ""
                        await poller.refreshNow()
                    }
                }
            }
            .disabled(spacemailEmail.isEmpty || spacemailPassword.isEmpty || spacemailClient.isValidating)
        }
    }

    // MARK: - Refresh & display

    private var refreshSection: some View {
        Section("Refresh") {
            Stepper(value: $settings.activePollSeconds, in: AppSettings.activePollRange, step: 15) {
                Text("While menu open: \(settings.activePollSeconds)s")
            }
            Stepper(value: $settings.idlePollSeconds, in: AppSettings.idlePollRange, step: 30) {
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
                errorText(error)
            }
            Button("Refresh Now") {
                Task { await poller.refreshNow() }
            }
            .disabled(poller.isRefreshing)
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Toggle("Show source badge in menu bar", isOn: $settings.showSourceInMenuBar)
                .toggleStyle(.switch)
            Toggle("Show Google Calendar", isOn: $settings.showGoogleCalendar)
                .toggleStyle(.switch)
                .disabled(!googleClient.isConfigured)
            Toggle("Show Spacemail", isOn: $settings.showSpacemailCalendar)
                .toggleStyle(.switch)
                .disabled(!spacemailClient.isConfigured)
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
    }

    private static let googleSetupHelp = """
    Google Cloud Console → create a project → enable Calendar API → Credentials → \
    Create OAuth client ID → Application type: Desktop app. Paste the Client ID (and Client Secret if shown). \
    Loopback redirects (http://127.0.0.1) are used automatically — no redirect URI setup needed for Desktop clients.
    """
}

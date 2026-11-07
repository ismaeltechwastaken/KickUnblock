import SwiftUI
import KickUnblockCore

struct TweaksTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var web: KickWebSession
    @AppStorage(PrefKey.chatSendPath) private var sendPath = TweakDefault.chatSendPath
    @State private var webPage: WebTarget?
    @State private var importing = false
    @AppStorage(PrefKey.chatRelayURL) private var relayURL = ""
    @AppStorage(PrefKey.pusherKey) private var pusherKey = ""
    @AppStorage(PrefKey.pusherCluster) private var pusherCluster = ""
    @AppStorage(PrefKey.kickEmoteURLTemplate) private var emoteTemplate = KickEmoteCDN.urlTemplate
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var tokenOverride = ""
    @State private var confirmClear = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            Form {
                TweaksSections()

                Section {
                    if web.isSignedIn {
                        LabeledContent("Signed in as", value: web.username ?? "Verifying…")
                        Picker("Send chat with", selection: $sendPath) {
                            ForEach(ChatSendPath.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        Button {
                            importing = true
                            Task { _ = await web.importFollows(into: model); importing = false }
                        } label: {
                            HStack { Label("Import follows", systemImage: "person.2.badge.plus"); if importing { Spacer(); ProgressView() } }
                        }.disabled(importing)
                        if let s = web.importStatus { Text(s).font(.caption).foregroundStyle(.kuSecondary) }
                        Button { webPage = WebTarget(url: KickAccountEndpoint.chatSettingsPage) } label: {
                            Label("Chat name color and profile", systemImage: "person.text.rectangle")
                        }
                        Button("Sign out", role: .destructive) { Task { await web.signOut() } }
                    } else {
                        Button { webPage = WebTarget(url: KickAccountEndpoint.loginPage) } label: {
                            Label("Sign in to Kick", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    NavigationLink { DropsView() } label: { Label("Drops", systemImage: "gift") }
                    if let e = web.lastError { KickAccountErrorView(error: e) }
                } header: { Text("Kick Account") } footer: {
                    Text("Sign-in is optional and uses kick.com's own page. Only session cookies are used for chat, follow imports and Drops progress. Tap Claim to claim Drops.")
                }
                .themedRows()

                Section {
                    if auth.isSignedIn {
                        LabeledContent("Signed in as", value: auth.username ?? "Kick user")
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    } else {
                        Button("Sign in with Kick") { Task { await auth.signIn() } }.disabled(!auth.isConfigured)
                    }
                    if let e = auth.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
                    TextField("Client ID", text: $clientID).textInputAutocapitalization(.never)
                    SecureField("Client secret", text: $clientSecret)
                    TextField("Token exchange URL (optional)", text: $tokenOverride).textInputAutocapitalization(.never).keyboardType(.URL)
                    Button("Save") {
                        auth.save(config: KickOAuthConfig(clientID: clientID.trimmingCharacters(in: .whitespaces),
                                                          clientSecret: clientSecret.isEmpty ? nil : clientSecret,
                                                          tokenEndpointOverride: URL(string: tokenOverride)))
                    }.disabled(clientID.isEmpty)
                } header: { Text("Official API") } footer: {
                    Text("Official API mode uses your Kick developer app. Its secret stays in Keychain. Redirect URI kickunblock://oauth/callback")
                }
                .themedRows()

                Section {
                    ShareLink(item: String(decoding: model.follows.exportJSON(), as: UTF8.self)) {
                        Label("Export follows", systemImage: "square.and.arrow.up")
                    }
                    Button("Delete all app data", role: .destructive) { confirmClear = true }
                } header: { Text("Data") }
                .themedRows()

                Section {
                    VStack(spacing: 10) {
                        KickUnblockWordmark(height: 22)
                        Text("By IsmaelTech 💚")
                            .font(.footnote).foregroundStyle(.kuSecondary)
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                            .font(.footnote).foregroundStyle(.kuSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } header: { Text("About") } footer: {
                    Text(PrivacyCopy.aboutFooter)
                }
                .themedRows()

                Section {
                    DisclosureGroup("Developer Diagnostics", isExpanded: $showDiagnostics) {
                        TextField("Pusher key (blank = built-in)", text: $pusherKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Pusher cluster (blank = \(KickPusher.defaultCluster))", text: $pusherCluster).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Chat relay URL (optional)", text: $relayURL).textInputAutocapitalization(.never).keyboardType(.URL)
                        TextField("Kick emote URL template", text: $emoteTemplate).textInputAutocapitalization(.never)
                            .onSubmit { KickEmoteCDN.urlTemplate = emoteTemplate }
                    }
                } footer: {
                    Text("Leave blank unless debugging chat. A relay URL replaces Pusher.")
                }
                .themedRows()
            }
            .oledPage()
            .themedControlTint()
            .navigationTitle("Tweaks")
            .onAppear {
                clientID = auth.config?.clientID ?? ""
                clientSecret = auth.config?.clientSecret ?? ""
                tokenOverride = auth.config?.tokenEndpointOverride?.absoluteString ?? ""
            }
            .sheet(item: $webPage) { t in
                KickWebSheet(title: t.url.path.contains("login") ? "Sign in to Kick" : "kick.com", url: t.url).environmentObject(web).themedControlTint()
            }
            .confirmationDialog("Delete follows, saved items, tweaks, sign-ins and caches?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { model.clearAllLocalData() }
            }
        }
    }
}

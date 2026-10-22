import AppKit
import SwiftUI

/// ⌘, settings window.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProfilesSettings()
                .tabItem { Label("Profiles", systemImage: "person.2") }
            BoostsSettings()
                .tabItem { Label("Boosts", systemImage: "bolt") }
        }
        .frame(width: 500, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(BrowserStore.self) private var store
    @AppStorage("autoPictureInPicture") private var autoPictureInPicture = true
    @AppStorage("hoverCards") private var hoverCards = true
    @State private var githubToken = GitHubToken.load() ?? ""
    @State private var tokenSaved = GitHubToken.load() != nil
    @State private var isDefaultBrowser = GeneralSettings.checkDefaultBrowser()

    var body: some View {
        Form {
            Section {
                Picker("Archive Today tabs after", selection: Binding(get: { store.autoArchiveInterval }, set: { store.setAutoArchive($0) })) {
                    ForEach(AutoArchiveInterval.allCases) { Text($0.title).tag($0) }
                }
                Text("Today tabs you haven't looked at for this long are archived. Pinned tabs and favorites are never archived.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Picture-in-Picture when leaving a playing video", isOn: $autoPictureInPicture)
                Toggle("Show hover cards for sidebar tabs", isOn: $hoverCards)
            }
            Section {
                LabeledContent("GitHub token") {
                    HStack {
                        SecureField("ghp_…", text: $githubToken)
                            .frame(width: 200)
                        Button(tokenSaved ? "Saved" : "Save") {
                            GitHubToken.save(githubToken)
                            tokenSaved = true
                            LiveFolderService.shared.refreshAll()
                        }
                        .disabled(tokenSaved)
                    }
                }
                Text("For the My Pull Requests and Review Requests live folders. Use a token that can read pull requests. Kept in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Block ads and trackers", isOn: Binding(get: { store.contentBlocking }, set: { store.setContentBlocking($0) }))
                if !store.blockingAllowedSites.isEmpty {
                    LabeledContent("Allowed sites") {
                        Text(store.blockingAllowedSites.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Text("Applies to pages loaded after a change. Allow a site with the shield in the address bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Import Bookmarks and Spaces…") { store.showingImport = true }
            }
            Section {
                LabeledContent("Default browser") {
                    if isDefaultBrowser {
                        Text("Arcky is your default browser").foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") { makeDefault() }
                    }
                }
                Text("Links opened from other apps open in Little Arc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: githubToken) { tokenSaved = false }
    }

    private static func checkDefaultBrowser() -> Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks the user to confirm the change.
    private func makeDefault() {
        let app = Bundle.main.bundleURL
        Task {
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
            isDefaultBrowser = Self.checkDefaultBrowser()
        }
    }
}

/// Profiles: separate cookies, logins and favorites. Spaces pick their profile from their menu.
private struct ProfilesSettings: View {
    @Environment(BrowserStore.self) private var store
    @State private var deleting: Profile?

    private static let emoji = ["🙂", "💼", "🏠", "🎓", "🧪", "🎮", "🛒", "🧑‍💻", "🌙", "⭐️"]

    var body: some View {
        Form {
            Section {
                ForEach(store.profiles) { profile in
                    HStack {
                        Menu(profile.emoji) {
                            ForEach(Self.emoji, id: \.self) { emoji in
                                Button(emoji) { store.updateProfile(profile.id) { $0.emoji = emoji } }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        TextField("Name", text: Binding(
                            get: { profile.name },
                            set: { name in store.updateProfile(profile.id) { $0.name = name } }
                        ))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        Spacer()
                        let count = store.spaces.filter { store.profileID(of: $0) == profile.id }.count
                        Text(count == 1 ? "1 space" : "\(count) spaces")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if profile.id == store.defaultProfileID {
                            Text("Default").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button { deleting = profile } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete Profile")
                        }
                    }
                }
            } footer: {
                Text("Each profile keeps its own cookies, logins and favorites. Choose a space's profile from its right-click menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("New Profile") { store.createProfile() }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete \"\(deleting?.name ?? "")\"?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { profile in
            Button("Delete Profile and Its Data", role: .destructive) { store.deleteProfile(profile.id) }
        } message: { _ in
            Text("Its cookies, logins and site data are erased. Its spaces move to the default profile, and its favorites go to the Archive.")
        }
    }
}

private struct BoostsSettings: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        Form {
            if store.boosts.isEmpty {
                Text("No Boosts yet. Open a site and choose Boost This Site from the Tabs menu or the bolt in the address bar.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.boosts) { boost in
                HStack {
                    Toggle(isOn: Binding(
                        get: { boost.isEnabled },
                        set: { on in store.updateBoost(boost.id) { $0.isEnabled = on } }
                    )) {
                        VStack(alignment: .leading) {
                            Text(boost.name)
                            Text(boost.domain).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Edit") { store.editingBoostID = boost.id }
                        .buttonStyle(.borderless)
                    Button { store.deleteBoost(boost.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete Boost")
                }
            }
        }
        .formStyle(.grouped)
    }
}

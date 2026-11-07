import SwiftUI
import KickUnblockCore

struct BlockListView: View {
    @State private var terms: [String] = []
    @State private var users: [String] = []
    @State private var newTerm = ""
    @State private var newUser = ""
    private let defaults = UserDefaults.standard

    var body: some View {
        Form {
            Section {
                entryRow("Add a word or phrase", text: $newTerm, valid: ChatBlockList.term(newTerm) != nil, add: addTerm)
                ForEach(terms, id: \.self) { Text($0) }
                    .onDelete { terms.remove(atOffsets: $0); save() }
            } header: { Text("Words") } footer: {
                Text("Hide messages with these words. Match whole words, so “ass” won't hide “class”. Swipe to remove.")
            }
            .themedRows()

            Section {
                entryRow("Add a username", text: $newUser, valid: ChatBlockList.user(newUser) != nil, add: addUser)
                ForEach(users, id: \.self) { Text($0) }
                    .onDelete { users.remove(atOffsets: $0); save() }
            } header: { Text("Users") } footer: {
                Text("Hide messages from these users. You can also long-press a chat message to block its sender.")
            }
            .themedRows()
        }
        .oledPage()
        .themedControlTint()
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            terms = defaults.stringArray(forKey: PrefKey.blockedTerms) ?? []
            users = defaults.stringArray(forKey: PrefKey.blockedUsers) ?? []
        }
    }

    private func entryRow(_ prompt: String, text: Binding<String>, valid: Bool, add: @escaping () -> Void) -> some View {
        HStack {
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(add)
            Button("Add", action: add).disabled(!valid)
        }
    }

    private func addTerm() {
        terms = ChatBlockList.adding(ChatBlockList.term(newTerm), to: terms)
        newTerm = ""
        save()
    }

    private func addUser() {
        users = ChatBlockList.adding(ChatBlockList.user(newUser), to: users)
        newUser = ""
        save()
    }

    private func save() {
        defaults.set(terms, forKey: PrefKey.blockedTerms)
        defaults.set(users, forKey: PrefKey.blockedUsers)
    }
}

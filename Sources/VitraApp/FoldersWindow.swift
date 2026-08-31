import AppKit
import SwiftUI
import VitraCore

/// The window where favourites are named, coloured and tagged.
///
/// Everything here is also reachable without it — a folder is favourited from
/// the terminal it is already open in — so this window exists for the edits that
/// come later: renaming, recolouring, throwing out what is stale.
@MainActor
final class FoldersWindow {
    private var window: NSWindow?

    func show(bookmarks: [Bookmark], onChange: @escaping ([Bookmark]) -> Void) {
        if let window {
            update(bookmarks: bookmarks)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = FoldersModel(bookmarks: bookmarks, onChange: onChange)
        let controller = NSHostingController(rootView: FoldersView(model: model))
        let window = NSWindow(contentViewController: controller)
        window.title = "Folders"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keeps an open window in step with a favourite added from a terminal.
    func update(bookmarks: [Bookmark]) {
        guard let controller = window?.contentViewController as? NSHostingController<FoldersView> else { return }
        controller.rootView.model.replace(bookmarks)
    }
}

@MainActor
final class FoldersModel: ObservableObject {
    @Published var bookmarks: [Bookmark]
    @Published var selection: Bookmark.ID?

    /// Set while the list is being replaced from outside, so echoing it straight
    /// back out as a change would fight whoever sent it.
    private var isReplacing = false
    private let onChange: ([Bookmark]) -> Void

    init(bookmarks: [Bookmark], onChange: @escaping ([Bookmark]) -> Void) {
        self.bookmarks = bookmarks
        self.onChange = onChange
        self.selection = bookmarks.first?.id
    }

    func replace(_ bookmarks: [Bookmark]) {
        isReplacing = true
        self.bookmarks = bookmarks
        if selection == nil || !bookmarks.contains(where: { $0.id == selection }) {
            selection = bookmarks.first?.id
        }
        isReplacing = false
    }

    func commit() {
        guard !isReplacing else { return }
        onChange(bookmarks)
    }

    func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = Bookmark(name: url.lastPathComponent, path: url.path)
        bookmarks.append(bookmark)
        selection = bookmark.id
        commit()
    }

    /// A server, added empty. There is no panel to pick a machine with, so the
    /// editor's fields are where it gets filled in.
    func addRemote() {
        let bookmark = Bookmark(name: "New server", path: "", host: "hostname")
        bookmarks.append(bookmark)
        selection = bookmark.id
        commit()
    }

    func remove() {
        guard let selection else { return }
        bookmarks.removeAll { $0.id == selection }
        self.selection = bookmarks.first?.id
        commit()
    }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return bookmarks.firstIndex { $0.id == selection }
    }
}

struct FoldersView: View {
    @ObservedObject var model: FoldersModel

    var body: some View {
        // A fixed sidebar rather than a split: the list needs one column of
        // names, the form needs room for its labels, and a draggable divider
        // between them only offers the user a way to break that.
        HStack(spacing: 0) {
            list.frame(width: 260)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.bookmarks) { bookmark in
                    HStack(spacing: 8) {
                        Image(systemName: bookmark.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bookmark.name).font(.system(size: 12, weight: .medium))
                            Text(bookmark.displayPath)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if let hex = bookmark.colorHex, let color = Color(hex: hex) {
                            Circle().fill(color).frame(width: 8, height: 8)
                        }
                    }
                    .tag(bookmark.id)
                }
                .onMove { source, destination in
                    model.bookmarks.move(fromOffsets: source, toOffset: destination)
                    model.commit()
                }
            }

            HStack(spacing: 0) {
                Button(action: model.add) { Image(systemName: "plus") }
                Button(action: model.addRemote) { Image(systemName: "network") }
                    .help("Add an SSH server")
                Button(action: model.remove) { Image(systemName: "minus") }
                    .disabled(model.selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let index = model.selectedIndex {
            FolderEditor(bookmark: $model.bookmarks[index], onCommit: model.commit)
                .id(model.bookmarks[index].id)
        } else {
            Text("No folder selected")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FolderEditor: View {
    @Binding var bookmark: Bookmark
    let onCommit: () -> Void

    /// Tags are edited as one comma-separated line: a table with add and remove
    /// buttons for three words each is more chrome than content.
    @State private var tagText: String = ""

    private static let swatches = [
        "#e05561", "#d6a75c", "#8cc265", "#4fb8b0",
        "#5aa5e0", "#c07ce8", "#9aa0aa", "#f0f0f5",
    ]



    var body: some View {
        Form {
            Section {
                TextField("Name", text: $bookmark.name)
                TextField("SSH host", text: hostBinding, prompt: Text("user@host, or an ssh alias"))
                if bookmark.isRemote {
                    // Editable, because the directory is on the other machine:
                    // there is nothing here to pick it from.
                    TextField("Directory", text: $bookmark.path, prompt: Text("/srv/app"))
                        .font(.system(size: 11, design: .monospaced))
                } else {
                    LabeledContent("Path") {
                        Text(bookmark.displayPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(bookmark.exists ? .secondary : Color.red)
                            .textSelection(.enabled)
                    }
                }
                TextField("Command", text: commandBinding, prompt: Text("claude"))
                    .font(.system(size: 11, design: .monospaced))
                if let command = bookmark.remoteCommand {
                    LabeledContent("Opens") {
                        Text(command.trimmingCharacters(in: .newlines))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 6), spacing: 6) {
                    ForEach(Bookmark.symbols, id: \.self) { symbol in
                        Button {
                            bookmark.icon = symbol
                            onCommit()
                        } label: {
                            Image(systemName: symbol)
                                .frame(width: 22, height: 22)
                                .foregroundStyle(bookmark.symbolName == symbol ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("Colour") {
                HStack(spacing: 6) {
                    ForEach(Self.swatches, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 18, height: 18)
                            .padding(3)
                            // The ring sits outside the swatch: drawn on top it
                            // would eat the colour it is meant to point at.
                            .overlay(
                                Circle().strokeBorder(
                                    Color.accentColor,
                                    lineWidth: bookmark.colorHex == hex ? 2 : 0
                                )
                            )
                            .onTapGesture { bookmark.colorHex = hex; onCommit() }
                    }
                    Button("None") { bookmark.colorHex = nil; onCommit() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            Section {
                Picker("Theme", selection: themeBinding) {
                    Text("Default").tag("")
                    ForEach(Theme.builtIn, id: \.name) { theme in
                        Text(theme.name.capitalized).tag(theme.name)
                    }
                }
                TextField("Tags", text: $tagText, prompt: Text("work, rust, client"))
                    .onSubmit(commitTags)
            }
        }
        .formStyle(.grouped)
        .onAppear { tagText = bookmark.tags.joined(separator: ", ") }
        .onDisappear(perform: commitTags)
        .onChange(of: bookmark.name) { _, _ in onCommit() }
        .onChange(of: bookmark.path) { _, _ in onCommit() }
        .onChange(of: bookmark.emoji) { _, _ in onCommit() }
    }

    /// The host as a plain string: empty means the favourite is a local folder,
    /// which is what `nil` means on the model.
    private var hostBinding: Binding<String> {
        Binding(
            get: { bookmark.host ?? "" },
            set: { bookmark.host = $0.isEmpty ? nil : $0; onCommit() }
        )
    }

    /// The command as a plain string, empty meaning none — the model keeps a
    /// `nil` for that, like the host.
    private var commandBinding: Binding<String> {
        Binding(
            get: { bookmark.command ?? "" },
            set: { bookmark.command = $0.isEmpty ? nil : $0; onCommit() }
        )
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { bookmark.theme ?? "" },
            set: { bookmark.theme = $0.isEmpty ? nil : $0; onCommit() }
        )
    }

    private func commitTags() {
        bookmark.tags = tagText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onCommit()
    }
}

extension Color {
    init?(hex: String) {
        guard let color = TerminalColor(hex: hex) else { return nil }
        self.init(
            .sRGB,
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255
        )
    }
}

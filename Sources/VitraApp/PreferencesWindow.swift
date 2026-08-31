import AppKit
import SwiftUI
import VitraCore

/// The preferences window, which edits `~/.vitra/config.toml` and nothing else.
///
/// There is no second source of truth: saving writes the file, and the file
/// watcher is what applies it. Editing the file by hand does exactly the same
/// thing, and the window follows along.
@MainActor
final class PreferencesWindow {
    private var window: NSWindow?

    func show(config: Config, onSave: @escaping (Config) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PreferencesView(config: config, onSave: onSave)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "Vitra Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keeps the open window in step with a file edited elsewhere.
    func update(config: Config) {
        guard let controller = window?.contentViewController as? NSHostingController<PreferencesView> else { return }
        controller.rootView.model.load(config)
    }
}

/// Mutable mirror of the configuration, because SwiftUI binds to properties and
/// `Config` is a value the rest of the app passes around whole.
@MainActor
final class PreferencesModel: ObservableObject {
    @Published var fontName: String
    @Published var fontSize: Double
    @Published var themeName: String
    @Published var opacity: Double
    @Published var blur: Bool
    @Published var padding: Double
    @Published var scrollback: Int
    @Published var shell: String

    private var base: Config

    init(config: Config) {
        base = config
        fontName = config.fontName
        fontSize = config.fontSize
        themeName = config.theme.name
        opacity = config.opacity
        blur = config.blur
        padding = config.padding
        scrollback = config.scrollbackLines
        shell = config.shell ?? ""
    }

    func load(_ config: Config) {
        base = config
        fontName = config.fontName
        fontSize = config.fontSize
        themeName = config.theme.name
        opacity = config.opacity
        blur = config.blur
        padding = config.padding
        scrollback = config.scrollbackLines
        shell = config.shell ?? ""
    }

    /// The configuration as edited. Custom colours the user wrote by hand are
    /// preserved: only the theme's name is chosen here.
    var edited: Config {
        var config = base
        config.fontName = fontName
        config.fontSize = fontSize
        config.opacity = opacity
        config.blur = blur
        config.padding = padding
        config.scrollbackLines = scrollback
        config.shell = shell.isEmpty ? nil : shell
        if config.theme.name != themeName, let theme = Theme.named(themeName) {
            config.theme = theme
        }
        return config
    }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    let onSave: (Config) -> Void

    init(config: Config, onSave: @escaping (Config) -> Void) {
        _model = ObservedObject(wrappedValue: PreferencesModel(config: config))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Font") {
                    TextField("Family", text: $model.fontName)
                    HStack {
                        Text("Size")
                        Slider(value: $model.fontSize, in: 8...32, step: 0.5)
                        Text(String(format: "%.1f", model.fontSize))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $model.themeName) {
                        ForEach(Theme.builtIn, id: \.name) { theme in
                            Text(theme.name.capitalized).tag(theme.name)
                        }
                    }
                    HStack {
                        Text("Opacity")
                        Slider(value: $model.opacity, in: 0.5...1, step: 0.01)
                        Text(String(format: "%.0f%%", model.opacity * 100))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    Toggle("Blur what is behind", isOn: $model.blur)
                        .disabled(model.opacity >= 1)
                    HStack {
                        Text("Padding")
                        Slider(value: $model.padding, in: 0...32, step: 1)
                        Text("\(Int(model.padding))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Section("Terminal") {
                    // No grouping separator: this is a number to type, not to
                    // read, and the separator differs by locale.
                    TextField("Scrollback lines", value: $model.scrollback, format: .number.grouping(.never))
                    TextField("Shell", text: $model.shell, prompt: Text("login shell"))
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Open config.toml") {
                    NSWorkspace.shared.open(Config.path)
                }
                Spacer()
                Button("Save") { onSave(model.edited) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 440, minHeight: 480)
    }
}

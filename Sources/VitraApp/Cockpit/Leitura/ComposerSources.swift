import Foundation

/// One line of the composer's completion list: what goes in the text, and a
/// word on what it is.
struct ComposerCompletion: Equatable {
    let insert: String
    let detail: String
}

/// What claude answers to "/": its own commands, and the user's, the
/// project's and the plugins' commands and skills, read from their folders.
enum SlashCatalog {
    /// claude's own commands that are worth offering, with what they do.
    static let builtins: [(String, String)] = [
        ("add-dir", "adiciona uma pasta de trabalho"), ("agents", "gerencia os agentes"),
        ("clear", "começa uma conversa nova"), ("compact", "resume a conversa para liberar contexto"),
        ("config", "abre as configurações"), ("context", "mostra o uso do contexto"),
        ("cost", "mostra o custo da sessão"), ("doctor", "verifica a instalação"),
        ("effort", "muda o esforço do modelo"), ("export", "exporta a conversa"),
        ("help", "ajuda"), ("hooks", "gerencia os hooks"), ("init", "cria o CLAUDE.md do projeto"),
        ("mcp", "gerencia os servidores MCP"), ("memory", "edita a memória"),
        ("model", "troca o modelo"), ("output-style", "muda o estilo de resposta"),
        ("permissions", "gerencia as permissões"), ("plugin", "gerencia os plugins"),
        ("rename", "renomeia a conversa"), ("resume", "volta a outra conversa"),
        ("review", "revisa um pull request"), ("rewind", "volta a um ponto anterior"),
        ("security-review", "revisa a segurança das mudanças"), ("skills", "lista as skills"),
        ("status", "mostra o estado da sessão"), ("tasks", "lista as tarefas em segundo plano"),
        ("todos", "mostra as tarefas"), ("usage", "mostra o uso do plano"),
    ]

    /// Commands that open a screen of their own when given no argument:
    /// Leitura cannot show it, so it hands over to the terminal.
    static let interactive: Set<String> = [
        "add-dir", "agents", "bashes", "config", "doctor", "effort", "export", "help", "hooks",
        "ide", "login", "logout", "mcp", "memory", "model", "output-style", "permissions",
        "plugin", "plugins", "privacy-settings", "resume", "rewind", "settings", "skills",
        "stats", "status", "tasks", "theme", "usage",
    ]

    /// "/model" opens a screen; "/model opus" does not.
    static func opensScreen(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/"), !line.contains(where: \.isWhitespace) else { return false }
        return interactive.contains(String(line.dropFirst()))
    }

    /// Everything "/" can complete to in `project`, by name.
    static func all(project: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ComposerCompletion] {
        var found: [String: String] = [:]
        for (name, detail) in builtins { found[name] = detail }
        let claude = home.appendingPathComponent(".claude")
        let projectClaude = URL(fileURLWithPath: project).appendingPathComponent(".claude")
        for root in [claude, projectClaude] {
            commands(in: root.appendingPathComponent("commands"), prefix: "", into: &found)
            skills(in: root.appendingPathComponent("skills"), prefix: "", into: &found)
        }
        for (plugin, path) in plugins(claude: claude) {
            let root = URL(fileURLWithPath: path)
            commands(in: root.appendingPathComponent("commands"), prefix: plugin + ":", into: &found)
            skills(in: root.appendingPathComponent("skills"), prefix: plugin + ":", into: &found)
        }
        return found.map { ComposerCompletion(insert: "/" + $0.key, detail: $0.value) }
            .sorted { $0.insert < $1.insert }
    }

    /// The ones whose name has `typed` in it, those starting with it first.
    static func matching(_ typed: String, in all: [ComposerCompletion], limit: Int = 8) -> [ComposerCompletion] {
        let query = typed.lowercased()
        let hits = all.filter { query.isEmpty || $0.insert.dropFirst().lowercased().contains(query) }
        let starts = hits.filter { $0.insert.dropFirst().lowercased().hasPrefix(query) || ($0.insert.split(separator: ":").last?.lowercased().hasPrefix(query) ?? false) }
        let rest = hits.filter { !starts.contains($0) }
        return Array((starts + rest).prefix(limit))
    }

    private static func commands(in folder: URL, prefix: String, into found: inout [String: String]) {
        let paths = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
        for relative in paths where relative.hasSuffix(".md") {
            let name = prefix + relative.dropLast(3).replacingOccurrences(of: "/", with: ":")
            if found[name] == nil { found[name] = description(of: folder.appendingPathComponent(relative)) }
        }
    }

    private static func skills(in folder: URL, prefix: String, into found: inout [String: String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            let file = folder.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: file.path), found[prefix + name] == nil else { continue }
            found[prefix + name] = description(of: file)
        }
    }

    /// Installed plugins: name and where they are.
    private static func plugins(claude: URL) -> [(String, String)] {
        guard let data = try? Data(contentsOf: claude.appendingPathComponent("plugins/installed_plugins.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = object["plugins"] as? [String: Any]
        else { return [] }
        return plugins.compactMap { key, value in
            guard let installs = value as? [[String: Any]], let path = installs.last?["installPath"] as? String else { return nil }
            return (String(key.split(separator: "@").first ?? Substring(key)), path)
        }
    }

    /// The frontmatter's description, on one short line.
    static func description(of file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        guard let line = head.split(separator: "\n").first(where: { $0.hasPrefix("description:") }) else { return "" }
        var text = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return text.count > 90 ? String(text.prefix(89)) + "…" : text
    }
}

/// What "@" completes to: the project's files, as git knows them.
enum FileCatalog {
    // NSCache is safe to share between threads.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CachedFiles>()
    private static let freshFor: TimeInterval = 30

    private final class CachedFiles {
        let files: [String]
        let when: Date
        init(files: [String], when: Date) { self.files = files; self.when = when }
    }

    /// Tracked and untracked files not ignored, relative to `project`. Run
    /// off the main thread: git can take a moment in a big tree.
    static func files(in project: String, now: Date = Date()) -> [String] {
        if let cached = cache.object(forKey: project as NSString), now.timeIntervalSince(cached.when) < freshFor {
            return cached.files
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", project, "ls-files", "-co", "--exclude-standard"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let files = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        cache.setObject(CachedFiles(files: files, when: now), forKey: project as NSString)
        return files
    }

    /// Best first: the name starting with `typed`, then the name having it,
    /// then the path having it; shorter paths before longer.
    static func matching(_ typed: String, in files: [String], limit: Int = 8) -> [ComposerCompletion] {
        let query = typed.lowercased()
        func rank(_ path: String) -> Int? {
            let lower = path.lowercased()
            let name = (lower as NSString).lastPathComponent
            if query.isEmpty { return 2 }
            if name.hasPrefix(query) { return 0 }
            if name.contains(query) { return 1 }
            if lower.contains(query) { return 2 }
            return nil
        }
        let ranked: [(rank: Int, path: String)] = files.compactMap { path in rank(path).map { ($0, path) } }
        let sorted = ranked.sorted { first, second in
            if first.rank != second.rank { return first.rank < second.rank }
            if first.path.count != second.path.count { return first.path.count < second.path.count }
            return first.path < second.path
        }
        return sorted.prefix(limit).map { ComposerCompletion(insert: "@" + $0.path, detail: "") }
    }
}

/// What was said before in this folder, as claude keeps it: ↑ in the
/// composer goes back through it, as it does in claude's own prompt.
enum PromptHistory {
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/history.jsonl")
    }

    /// The folder's prompts, oldest first, without repeats in a row. Reads
    /// the end of the file only.
    static func prompts(for project: String, in url: URL = file, limit: Int = 200) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        var prompts: [String] = []
        for line in data.split(separator: 0x0A) {
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  entry["project"] as? String == project,
                  var text = entry["display"] as? String
            else { continue }
            // "[Pasted text #1 +12 lines]" stands for what was pasted.
            if let pasted = entry["pastedContents"] as? [String: Any] {
                for (key, value) in pasted {
                    guard let content = (value as? [String: Any])?["content"] as? String,
                          let range = text.range(of: #"\[Pasted text #\#(key)[^\]]*\]"#, options: .regularExpression)
                    else { continue }
                    text.replaceSubrange(range, with: content)
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, prompts.last != text else { continue }
            prompts.append(text)
        }
        return Array(prompts.suffix(limit))
    }
}

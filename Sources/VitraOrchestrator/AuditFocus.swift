import Foundation

/// What an audit looks at, chosen from what the change touches.
///
/// A general reviewer reads a migration, a lock and a login check with the
/// same eye, and the dangerous part of each is exactly what a general read
/// skims. The classifier says which specialised reads a diff calls for, so the
/// auditor is handed the checklist for each — and security, data and
/// concurrency, where a miss costs most, go to a strong auditor.
public enum AuditFocus: String, Codable, Sendable, CaseIterable {
    case security, data, concurrency, interface, tests, general

    /// One focus the diff calls for, and what in it did.
    public struct Match: Equatable, Sendable {
        public let focus: AuditFocus
        /// The paths, or `path: line`, that triggered it; at most `mostEvidence`.
        public let evidence: [String]

        public init(focus: AuditFocus, evidence: [String]) {
            self.focus = focus
            self.evidence = evidence
        }
    }

    /// Whether a miss here is costly enough for a strong auditor.
    public var isHard: Bool { [.security, .data, .concurrency].contains(self) }

    /// How many pieces of evidence each focus keeps, and how long each is.
    static let mostEvidence = 4
    static let longestEvidence = 100

    /// The focuses a unified diff calls for, in `allCases` order, `general`
    /// always last. Pure and cheap: a few regular expressions per added line.
    public static func classify(_ diff: String) -> [Match] {
        let files = changedFiles(in: diff)
        var evidence: [AuditFocus: [String]] = [:]
        func note(_ focus: AuditFocus, _ item: String) {
            let clipped = String(item.prefix(longestEvidence))
            let list = evidence[focus, default: []]
            guard list.count < mostEvidence, !list.contains(clipped) else { return }
            evidence[focus] = list + [clipped]
        }

        for file in files {
            let words = pathWords(file.path)
            for (focus, names) in pathRules where !words.isDisjoint(with: names) {
                note(focus, file.path)
            }
            if interfaceExtensions.contains(file.fileExtension) { note(.interface, file.path) }
            for line in file.added {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                // A secret in a comment is still a secret; anything else said
                // in a comment is not code.
                let isComment = commentPrefixes.contains { text.hasPrefix($0) }
                for (focus, rule) in lineRules where (!isComment || rule.inComments) && rule.matches(text) {
                    note(focus, "\(file.path): \(text)")
                }
            }
        }

        // Tests: only tests changed, or code changed and no test with it.
        let tests = files.filter { isTest($0.path) }
        let code = files.filter { !isTest($0.path) && codeExtensions.contains($0.fileExtension) }
        if !files.isEmpty, tests.count == files.count {
            note(.tests, "only tests changed: " + tests.map(\.path).joined(separator: ", "))
        } else if !code.isEmpty, tests.isEmpty {
            note(.tests, "no test touched: " + code.prefix(mostEvidence).map(\.path).joined(separator: ", "))
        }

        return allCases.compactMap { focus in
            if focus == .general { return Match(focus: .general, evidence: []) }
            return evidence[focus].map { Match(focus: focus, evidence: $0) }
        }
    }

    /// The matches for focuses named at spawn, in `allCases` order, `general`
    /// always among them.
    public static func forced(_ focuses: [AuditFocus]) -> [Match] {
        allCases.filter { focuses.contains($0) || $0 == .general }.map {
            Match(focus: $0, evidence: $0 == .general ? [] : ["asked for at spawn"])
        }
    }

    /// The focuses as the gate line names them: `security, data`. `general`
    /// is the base of every audit and is named only when it is alone.
    public static func names(_ focuses: [AuditFocus]) -> String {
        let special = focuses.filter { $0 != .general }
        return (special.isEmpty ? [.general] : special).map(\.rawValue).joined(separator: ", ")
    }

    // MARK: Diff

    struct ChangedFile {
        let path: String
        var added: [String] = []
        var fileExtension: String { (path as NSString).pathExtension.lowercased() }
    }

    /// Each file of a unified diff with the lines it adds. The path is the
    /// new one (`b/…`), or the old one for a deleted file.
    static func changedFiles(in diff: String) -> [ChangedFile] {
        var files: [ChangedFile] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                let path = line.range(of: " b/", options: .backwards).map { String(line[$0.upperBound...]) }
                    ?? String(line.dropFirst("diff --git ".count))
                files.append(ChangedFile(path: path))
            } else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                continue
            } else if line.hasPrefix("+"), !files.isEmpty {
                files[files.count - 1].added.append(String(line.dropFirst()))
            }
        }
        return files
    }

    /// The lowercased words of a path: its components split at `_ - .` and at
    /// camel case, so `Sources/Auth/MCPServer.swift` is auth, mcp, server, swift.
    static func pathWords(_ path: String) -> Set<String> {
        let spaced = path
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Z]+)([A-Z][a-z])"#, with: "$1 $2", options: .regularExpression)
        return Set(spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    static func isTest(_ path: String) -> Bool {
        !pathWords(path).isDisjoint(with: ["test", "tests", "spec", "specs", "testing", "xctest"])
    }

    // MARK: Rules

    static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "c", "cc", "cpp", "h", "hpp", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "go", "rs",
        "java", "kt", "rb", "php", "cs", "sh", "bash", "zsh", "sql", "vue", "svelte",
    ]

    static let interfaceExtensions: Set<String> = [
        "css", "scss", "sass", "less", "html", "jsx", "tsx", "vue", "svelte", "xib", "storyboard", "strings",
        "xcstrings", "stringsdict", "po",
    ]

    static let commentPrefixes = ["//", "#", "/*", "*", "--", "<!--"]

    static let pathRules: [(AuditFocus, Set<String>)] = [
        (.security, [
            "auth", "authentication", "authorization", "oauth", "login", "security", "crypto", "secret", "secrets",
            "credential", "credentials", "keychain", "permission", "permissions", "sandbox", "mcp", "password", "token",
            "tokens", "jwt",
        ]),
        (.data, [
            "migration", "migrations", "migrate", "schema", "db", "database", "sql", "models", "entity", "entities",
            "prisma", "alembic", "persistence", "repository",
        ]),
        (.concurrency, [
            "lock", "locks", "queue", "queues", "thread", "threads", "actor", "actors", "scheduler", "semaphore",
            "mutex", "concurrency",
        ]),
        (.interface, [
            "view", "views", "ui", "component", "components", "layout", "style", "styles", "screen", "screens",
            "page", "pages", "theme", "localizable", "locale", "locales", "i18n", "l10n", "accessibility",
        ]),
    ]

    struct LineRule {
        let pattern: NSRegularExpression
        /// Also read in comment lines: only for what is dangerous anywhere.
        var inComments = false
        /// A second pattern that must also be on the line.
        var alongside: NSRegularExpression? = nil

        func matches(_ text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            guard pattern.firstMatch(in: text, range: range) != nil else { return false }
            return alongside.map { $0.firstMatch(in: text, range: range) != nil } ?? true
        }
    }

    // The patterns are fixed and tested: a failure to compile is a bug here.
    private static func regex(_ pattern: String, caseless: Bool = true) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive] : [])
    }

    // ponytail: token heuristics, not a parser — a miss falls back to the general read.
    static let lineRules: [(AuditFocus, LineRule)] = [
        // Auth, sessions, permissions, crypto.
        (.security, LineRule(pattern: regex(
            #"\b(passwords?|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|bearer|jwt|oauth|csrf|session[_-]?(id|token)|authori[sz]|authenticat|permission|privilege|sudo|chmod|setuid|allowedTools|dangerously|hmac|sha1|md5|encrypt|decrypt|cipher|bcrypt|argon2|CryptoKit|CommonCrypto|SecItem|keychain)"#
        ))),
        // Secret-looking literals: keys by their prefix, or a long quoted value
        // assigned to something named like a secret.
        (.security, LineRule(pattern: regex(
            #"(sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY|(key|token|secret|password)\w*\s*[:=]\s*["'][^"'\s]{12,}["'])"#
        ), inComments: true)),
        // Shell and process execution.
        (.security, LineRule(pattern: regex(
            #"(\bProcess\(\)|\bNSTask\b|posix_spawn|\bexecv|\bexecl|\bsystem\(|\bpopen\(|subprocess\.|os\.system|child_process|\bexecSync\b|\bexecFile|Runtime\.getRuntime|exec\.Command|Command::new|/bin/(ba|z)?sh\b|\b(ba|z)?sh -c\b|\beval\()"#,
            caseless: false
        ))),
        // A query built from text: SQL with interpolation or concatenation.
        (.security, LineRule(
            pattern: regex(#"\b(SELECT\b.+\bFROM|INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b"#),
            alongside: regex(#"(\\\(|\$\{|%s|\{\}|f"|\.format\(|Sprintf|format!\(|"\s*\+|\+\s*")"#)
        )),
        // A path built from something that came from outside.
        (.security, LineRule(
            pattern: regex(#"(appendingPathComponent|fileURLWithPath|path\.join|os\.path\.join|filepath\.Join|Path::new|\bopen\(|readFile|writeFile|send_file|sendFile)"#),
            alongside: regex(#"\b(request|req|params|query|argv|input|upload|filename|user)\b"#)
        )),
        (.security, LineRule(pattern: regex(#"\.\./"#))),
        // Network endpoints.
        (.security, LineRule(pattern: regex(
            #"(\bURLSession\b|\bURLRequest\b|\bfetch\(|\baxios\b|requests\.(get|post|put|delete)|http\.(Get|Post|ListenAndServe|HandleFunc)|\breqwest\b|\bapp\.(get|post|put|patch|delete)\(|@app\.route|@(Get|Post|Put|Delete)Mapping|\bNWListener\b|\bcors\b|\.listen\()"#
        ))),
        // Deserialisation that can build arbitrary objects.
        (.security, LineRule(pattern: regex(
            #"(pickle\.loads?|yaml\.load\(|\bunserialize\(|ObjectInputStream|NSKeyedUnarchiver|unarchiveObject|Marshal\.load)"#
        ))),

        // Destructive and schema statements.
        (.data, LineRule(pattern: regex(
            #"\b(drop\s+(table|column|index|database|schema)|truncate(\s+table)?\s+\w|alter\s+table|delete\s+from|create\s+(unique\s+)?(table|index)|add\s+column|rename\s+(column|table))\b"#
        ))),
        // ORM models and stores.
        (.data, LineRule(pattern: regex(
            #"(@Model\b|@Entity\b|NSManagedObject|\bSwiftData\b|\bGRDB\b|sqlite3?_|ActiveRecord|models\.Model|db\.Column|\bSequelize\b|\bTypeORM\b|@Column\b|\bgorm\.|diesel::|sqlx::|\bknex\b|\bprisma\.)"#,
            caseless: false
        ))),
        // Persistence formats and their versions, and cache keys.
        (.data, LineRule(pattern: regex(
            #"((?i:schema_?version|format_?version)|currentVersion|IndexedDB|pickle\.dump|cache[_-]?[kK]ey|\bredis\b|\bNSCache\b|lru_cache)"#,
            caseless: false
        ))),

        (.concurrency, LineRule(pattern: regex(
            #"(\bDispatch(Queue|Group|Semaphore|Source)\b|\bOperationQueue\b|\bThread\b|pthread_|\bNSLock\b|NSRecursiveLock|os_unfair_lock|OSAllocatedUnfairLock|\bMutex\b|\bactor\s+\w|@unchecked|Task\.detached|TaskGroup|Continuation|\bflock\(|\blockf\(|O_EXLOCK|\bsignal\(|SIG(TERM|INT|CHLD|HUP|PIPE)|sigaction|\bgo func\b|sync\.(Mutex|RWMutex|WaitGroup|Once)|\bchan\s+\w|\bthreading\b|\bmultiprocessing\b|\basyncio\b|std::thread|tokio::|Arc<|Mutex<|RwLock<|\bAtomic\w*|\btrap\s)"#,
            caseless: false
        ))),

        (.interface, LineRule(pattern: regex(
            #"(\bNS(View|TextField|Button|Window|StackView|LayoutConstraint|Font|Color)\b|\bUI(View|Label|Button|Font|Color)\b|\bimport SwiftUI\b|:\s*View\s*\{|\.font\(|\.padding\(|\.frame\(|\.foregroundStyle|className=|style=\{|<(div|button|span|input|label)\b|accessibility\w*|aria-|\brole=|NSLocalizedString|String\(localized|\bi18n\b|\bt\(["']|tabIndex|@media|font-size)"#,
            caseless: false
        ))),
    ]
}

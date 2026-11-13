import Foundation
import Testing
@testable import VitraApp

struct LeituraTranscriptTests {
    @Test func aTurnBecomesQuestionActivityAnswerAndFooter() throws {
        let items = JSONL.items(JSONL.conversation)
        #expect(items.count == 4)
        guard case let .user(question) = items[0], case let .activity(activity) = items[1],
              case let .answer(answer) = items[2], case let .worked(worked) = items[3] else {
            Issue.record("unexpected kinds: \(items)")
            return
        }
        #expect(question.text == "Rode os testes, por favor")
        #expect(activity.calls.count == 3)
        #expect(activity.steps.first == .thought)
        #expect(activity.failures == 1)
        #expect(activity.duration == 34)
        #expect(answer.markdown == "Pronto: **tudo passou**.")
        #expect(worked.seconds == 41)
    }

    @Test func oneLinersPerTool() {
        let items = JSONL.items(JSONL.conversation)
        guard case let .activity(activity) = items[1] else { return }
        let calls = activity.calls
        #expect(calls[0].summary == "Rodar os testes")
        #expect(calls[0].status == .ok)
        #expect(calls[0].duration == 30)
        #expect(calls[1].summary == "Main.swift · linhas 10–29")
        #expect(calls[1].filePath == "/p/Sources/App/Main.swift")
        #expect(calls[2].added == 2 && calls[2].removed == 1)
        #expect(calls[2].status == .error("String not found in file"))
    }

    @Test func toolOneLiners() {
        let cases: [(String, [String: Any], String)] = [
        ("Bash", ["command": "cd /x && git status --short"], "git status --short"),
        ("Grep", ["pattern": "TODO"], "buscou “TODO”"),
        ("Glob", ["pattern": "**/*.swift"], "listou **/*.swift"),
        ("Agent", ["description": "Explorar o código", "subagent_type": "Explore"], "agente: Explorar o código (Explore)"),
        ("WebSearch", ["query": "swift testing"], "pesquisou “swift testing”"),
        ("WebFetch", ["url": "https://example.com/a/b"], "leu example.com"),
        ("Write", ["file_path": "/a/b/New.swift", "content": "x\ny\n"], "New.swift"),
        ("mcp__vitra__agent_spawn", ["label": "Migrar a lista", "kind": "implement"], "delegou: Migrar a lista (implement)"),
        ("mcp__vitra__agent_wait", ["ids": ["a", "b", "c"]], "aguardou 3 operários"),
        ("mcp__vitra__agent_merge", ["id": "e2d48a94"], "integrou e2d48a94"),
        ("mcp__vitra__agent_rate", ["id": "b051b7b9", "score": 5], "nota 5/5 a b051b7b9"),
        ("mcp__vitra__preview_file", ["path": "/p/docs/plan.md"], "mostrou plan.md"),
        ("mcp__vitra__browser_open", ["url": "https://x.dev"], "navegador: open https://x.dev"),
        ("mcp__github__create_issue", ["title": "x"], "github · create issue"),
        ]
        for (name, input, expected) in cases {
            #expect(ToolSummary.describe(name: name, input: input).summary == expected)
        }
    }

    @Test func spawnResultGivesTheWorkerID() {
        let lines = [
            JSONL.tool("t1", "mcp__vitra__agent_spawn", ["label": "L", "kind": "review"], "a1", at: 0),
            JSONL.result("t1", "Started agent 09c1ff2b: opencode", "r1", at: 1),
        ]
        guard case let .activity(activity) = JSONL.items(lines).first else { Issue.record("no activity"); return }
        #expect(activity.calls.first?.workerID == "09c1ff2b")
    }

    @Test func sidechainsMetaAndHarnessChatterAreSkipped() {
        let lines = [
            JSONL.user("um operário falando", "s1", at: 0, sidechain: true),
            JSONL.text("resposta de subagente", "s2", at: 1, sidechain: true),
            JSONL.user("<system-reminder>lembrete</system-reminder>", "m1", at: 2, meta: true),
            JSONL.system("stop_hook_summary", "h1", at: 3),
            JSONL.line(["type": "api-request-blob", "uuid": "b1"]),
            JSONL.line(["type": "file-history-snapshot"]),
            "not json at all",
            JSONL.line(["type": "something-new", "uuid": "n1", "message": ["content": [["type": "hologram"]]]]),
            JSONL.user("Oi <system-reminder>\nsegredo\n</system-reminder> tudo bem?", "u1", at: 4),
        ]
        let items = JSONL.items(lines)
        #expect(items.count == 1)
        guard case let .user(message) = items.first else { Issue.record("no user message"); return }
        #expect(message.text == "Oi  tudo bem?")
    }

    @Test func slashCommandsAndShellAreQuietNotes() {
        let lines = [
            JSONL.user("<command-name>/rename</command-name>\n<command-message>rename</command-message>\n<command-args>Leitura</command-args>", "c1", at: 0),
            JSONL.user("<local-command-stdout>Session renamed to: Leitura</local-command-stdout>", "c2", at: 1),
            JSONL.user("<bash-input>git status</bash-input>", "b1", at: 2),
            JSONL.user("<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>", "b2", at: 3),
            JSONL.userBlocks([["type": "text", "text": "[Request interrupted by user]"]], "i1", at: 4),
            JSONL.user("<task-notification>\n<task-id>x</task-id>\n<summary>Background command \"build\" completed</summary>\n</task-notification>", "k1", at: 5),
        ]
        let notes = JSONL.items(lines).compactMap { if case let .note(note) = $0 { note } else { nil } }
        #expect(notes.map(\.line) == [
            "/rename Leitura → Session renamed to: Leitura",
            "! git status",
            "interrompido por você",
            "Background command \"build\" completed",
        ])
    }

    @Test func imagesGetTheirSavedPathAndPlaceholdersGo() {
        let lines = [
            JSONL.userBlocks([
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="]],
                ["type": "text", "text": "[Image #1] olha isso"],
            ], "u1", at: 0),
            JSONL.userBlocks([["type": "text", "text": "[Image: source: /tmp/images/1.png]"]], "m1", at: 0, meta: true),
        ]
        guard case let .user(message) = JSONL.items(lines).first else { Issue.record("no message"); return }
        #expect(message.text == "olha isso")
        #expect(message.images.count == 1)
        #expect(message.images.first?.path == "/tmp/images/1.png")
        #expect(message.images.first?.base64 == "iVBORw0KGgo=")
    }

    @Test func queuedPromptsAreTheUsersWords() {
        let line = JSONL.line(JSONL.entry("attachment", "q1", at: 0, extra: ["attachment": ["type": "queued_command", "prompt": "e o dark mode?", "commandMode": "prompt"]]))
        guard case let .user(message) = JSONL.items([line]).first else { Issue.record("no message"); return }
        #expect(message.text == "e o dark mode?")
    }

    @Test func compactionAndPausesAreDividers() {
        let lines = [
            JSONL.user("primeira", "u1", at: 0),
            JSONL.text("ok", "a1", at: 5),
            JSONL.system("compact_boundary", "c1", at: 10, extra: ["content": "Conversation compacted"]),
            JSONL.line(JSONL.entry("user", "cs", at: 11, extra: ["isCompactSummary": true, "message": ["content": "resumo longo"]])),
            JSONL.user("depois de uma pausa", "u2", at: 10 + 6 * 60),
        ]
        let kinds = JSONL.items(lines).map { item -> String in
            switch item {
            case .user: "user"
            case .answer: "answer"
            case let .divider(divider): divider.kind == .compacted ? "compacted" : "time"
            default: "other"
            }
        }
        #expect(kinds == ["user", "answer", "compacted", "time", "user"])
    }

    @Test func aCallWithoutResultIsRunning() {
        let lines = [JSONL.tool("t1", "Bash", ["command": "sleep 100"], "a1", at: 0)]
        guard case let .activity(activity) = JSONL.items(lines).first else { Issue.record("no activity"); return }
        #expect(activity.running?.id == "t1")
        #expect(activity.duration == nil)
    }

    /// Any split of the transcript into stretches, joined, reads the same as
    /// the whole: the seam may cut a run of calls or separate a result from
    /// its call.
    @Test func joiningChunksAtEverySeamEqualsTheWhole() {
        let lines = JSONL.conversation + [
            JSONL.user("[Image #1] e isso?", "u2", at: 400),
            JSONL.userBlocks([["type": "text", "text": "[Image: source: /tmp/2.png]"]], "m2", at: 400, meta: true),
            // Thoughts closing a run of calls, then text; thoughts after text,
            // then a new run.
            JSONL.tool("t8", "Read", ["file_path": "/p/a.swift"], "b1", at: 401),
            JSONL.result("t8", "x", "b2", at: 402),
            JSONL.thinking("b3", at: 403),
            JSONL.thinking("b4", at: 404),
            JSONL.text("Li.", "b5", at: 405),
            JSONL.thinking("b6", at: 406),
            JSONL.thinking("b7", at: 407),
            JSONL.tool("t9", "Bash", ["command": "ls"], "b8", at: 408),
        ]
        let events = lines.map { TranscriptLine.events(from: Data($0.utf8)) }
        let whole = TranscriptChunk(events: events.flatMap { $0 }).items
        for seam in 1 ..< events.count {
            let older = TranscriptChunk(events: events[..<seam].flatMap { $0 })
            let newer = TranscriptChunk(events: events[seam...].flatMap { $0 })
            #expect(older.joined(newer).items == whole, "seam at \(seam)")
        }
    }
}

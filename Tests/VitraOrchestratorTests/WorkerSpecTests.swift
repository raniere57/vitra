import Foundation
import Testing
@testable import VitraOrchestrator

private func spec(
    _ cli: WorkerCLI,
    model: String,
    effort: String? = nil,
    prompt: String = "do it",
    directory: String = NSTemporaryDirectory(),
    access: WorkerAccess = .read,
    commands: [String] = []
) -> WorkerSpec {
    WorkerSpec(cli: cli, model: model, prompt: prompt, directory: directory, access: access, effort: effort, commands: commands)
}

// MARK: - Commands a worker may run

@Test func aWorkerMayRunOnlyTheCommandsItWasGiven() {
    // Without these a worker can edit a file and not run the test that would
    // tell it the edit is wrong. With them it runs those commands, and no
    // others: this is a list of what is allowed, never a switch that allows
    // everything.
    let claude = spec(.claude, model: "haiku", effort: "low", access: .edit, commands: ["bun test", "git diff"]).arguments
    #expect(claude == [
        "-p", "--model", "haiku", "--output-format", "json", "--effort", "low", "--permission-mode", "acceptEdits",
        "--allowedTools", "Bash(bun test:*)", "Bash(git diff:*)",
        // The git an editing worker always has, and never has twice.
        "Bash(git status:*)", "Bash(git log:*)", "Bash(git add:*)", "Bash(git commit:*)", "Bash(git show:*)",
    ])


    // opencode's editing agent already runs commands; there is nothing to pass.
    let openCode = spec(.opencode, model: "opencode/x-free", access: .edit, commands: ["bun test"]).arguments
    #expect(openCode == ["run", "--format", "json", "-m", "opencode/x-free"])
}

@Test func aCommandIsAPlainCommandAndNothingThatCouldWidenIt() {
    let ok = { (commands: [String]) in try spec(.claude, model: "haiku", effort: "low", commands: commands).validate() }
    #expect(throws: Never.self) { try ok(["bun test", "swift test --filter Foo", "python3 -m pytest", "npm run lint", "./scripts/check.sh"]) }
    // Each of these would turn "this command" into "any command": a wildcard,
    // a second command chained on, a substitution, a closing bracket that
    // ends the rule early.
    for bad in ["*", "bun test; rm -rf ~", "bun test && curl x", "echo $(whoami)", "ls | sh", "x) Bash(*", "a\nb", "`id`", "", "   ", "sudo rm", "rm -rf /"] {
        #expect(throws: OrchestratorError.self) { try ok([bad]) }
    }
    #expect(throws: OrchestratorError.self) { try ok(Array(repeating: "bun test", count: 9)) }
    // A deploy runs on the server: its worker may ssh to the one host named,
    // and no other kind of task may ssh at all.
    let deploy = { (command: String) in
        try WorkerSpec(cli: .claude, model: "haiku", prompt: "p", directory: NSTemporaryDirectory(), kind: .deploy, effort: "low", commands: [command]).validate()
    }
    #expect(throws: Never.self) { try deploy("ssh ubuntu@10.0.0.5") }
    for bad in ["ssh", "ssh -oProxyCommand=x host", "ssh a b", "sudo ls"] {
        #expect(throws: OrchestratorError.self) { try deploy(bad) }
    }
    #expect(throws: OrchestratorError.self) { try ok(["ssh ubuntu@10.0.0.5"]) }
    // cursor has no list: it is everything (--force) or nothing, and it gets nothing.
    #expect(throws: OrchestratorError.self) {
        try spec(.cursor, model: "grok-4.7-low", commands: ["bun test"]).validate()
    }
}

@Test func aWorkerGivenTheBrowserLoadsVitrasToolsAndMayCallThem() {
    // claude takes the server on its command line and must be told its tools
    // need no approval; cursor must be told to approve the servers it finds.
    // gemini (Antigravity's agy) and opencode read theirs from their own settings.
    let edit = spec(.claude, model: "haiku", effort: "low", access: .edit, commands: ["bun test"])
    #expect(edit.arguments(browserConfig: "/x/mcp.json") == [
        "-p", "--model", "haiku", "--output-format", "json", "--effort", "low", "--permission-mode", "acceptEdits",
        "--mcp-config", "/x/mcp.json", "--allowedTools", "mcp__vitra", "Bash(bun test:*)",
        "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git add:*)", "Bash(git commit:*)", "Bash(git show:*)",
    ])
    #expect(spec(.claude, model: "sonnet", effort: "high").arguments(browserConfig: "/x/mcp.json") == [
        "-p", "--model", "sonnet", "--output-format", "json", "--effort", "high",
        "--mcp-config", "/x/mcp.json", "--allowedTools", "mcp__vitra",
    ])
    #expect(spec(.cursor, model: "grok-4.7-low").arguments(browserConfig: "/x/mcp.json") == [
        "-p", "--model", "grok-4.7-low", "--output-format", "json", "--mode", "ask", "--approve-mcps", "--trust", "--",
    ])
    for cli in [WorkerCLI.gemini, .opencode] {
        let worker = spec(cli, model: cli == .gemini ? "gemini-3.8-flash-low" : "opencode/x-free")
        #expect(worker.arguments(browserConfig: "/x/mcp.json") == worker.arguments)
    }
    // With no browser to give, nothing changes.
    #expect(edit.arguments(browserConfig: nil) == edit.arguments)
}

// MARK: - What each CLI is run with

@Test func aReadOnlyClaudeWorkerGetsItsEffortAndNoPermissionToEdit() {
    let arguments = spec(.claude, model: "sonnet", effort: "high").arguments
    #expect(arguments == ["-p", "--model", "sonnet", "--output-format", "json", "--effort", "high"])
}

@Test func anEditingClaudeWorkerAcceptsEditsButNeverBypassesPermissions() {
    let arguments = spec(.claude, model: "haiku", effort: "low", access: .edit).arguments
    #expect(arguments == [
        "-p", "--model", "haiku", "--output-format", "json", "--effort", "low", "--permission-mode", "acceptEdits",
        "--allowedTools", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)",
        "Bash(git add:*)", "Bash(git commit:*)", "Bash(git show:*)",
    ])
    #expect(!arguments.contains { $0.contains("bypass") || $0.contains("dangerously") })
}

@Test func everyEditingClaudeWorkerMayUseGitOnItsOwnWorktree() {
    // Committing in its own worktree is the same step of every editing task:
    // the worker gets these without the orchestrator listing them, and none
    // of them reaches another branch or another machine.
    let edit = spec(.claude, model: "haiku", effort: "low", access: .edit).allowedCommands
    #expect(edit == ["git status", "git diff", "git log", "git add", "git commit", "git show"])
    #expect(!edit.contains { ["push", "reset", "checkout", "rebase", "merge", "branch"].contains($0.split(separator: " ").last.map(String.init) ?? "") })

    // A read worker writes nothing, so it is given none of them.
    #expect(spec(.claude, model: "haiku", effort: "low").allowedCommands.isEmpty)
    // Other CLIs do not take the list, so nothing is added for them either.
    #expect(spec(.opencode, model: "opencode/x-free", access: .edit).allowedCommands.isEmpty)

    // They are free: naming them does not use up the eight project commands.
    #expect(throws: Never.self) {
        try spec(
            .claude, model: "haiku", effort: "low", access: .edit,
            commands: ["git commit", "git add"] + Array(repeating: "bun test", count: 8)
        ).validate()
    }
    #expect(throws: OrchestratorError.self) {
        try spec(
            .claude, model: "haiku", effort: "low", access: .edit,
            commands: Array(repeating: "bun test", count: 9)
        ).validate()
    }
}

@Test func aReadOnlyOpenCodeWorkerRunsThePlanAgent() {
    let arguments = spec(.opencode, model: "opencode/deepseek-v4.1-flash-free").arguments
    #expect(arguments == ["run", "--format", "json", "-m", "opencode/deepseek-v4.1-flash-free", "--agent", "plan"])
}

@Test func openCodeTakesItsEffortAsAVariantOfTheModel() {
    let arguments = spec(.opencode, model: "opencode/deepseek-v4.1-flash-free", effort: "high", access: .edit).arguments
    #expect(arguments == ["run", "--format", "json", "-m", "opencode/deepseek-v4.1-flash-free#high"])
    #expect(!arguments.contains("--auto"))
}

@Test func aReadOnlyGeminiWorkerLeavesApprovalAtItsDefault() {
    // Headless, with nobody to approve, the default mode refuses every tool
    // that writes or runs a command: that is what makes it read-only.
    // gemini workers run on Antigravity's CLI, agy, which is what the Google
    // AI subscription reaches: the gemini CLI no longer accepts it.
    #expect(WorkerCLI.gemini.executableName == "agy")
    #expect(spec(.gemini, model: "gemini-3.8-flash-low").arguments == ["--output-format", "json", "--model", "gemini-3.8-flash-low"])
}

@Test func anEditingGeminiWorkerApprovesEditsButNeverEverything() {
    let arguments = spec(.gemini, model: "gemini-3.8-flash-low", access: .edit).arguments
    #expect(arguments == ["--output-format", "json", "--model", "gemini-3.8-flash-low", "--mode", "accept-edits"])
    #expect(!arguments.contains { $0.contains("dangerously") })
}

@Test func aCursorWorkerTrustsItsFolderButIsNeverForced() {
    // Headless, cursor refuses to start in a folder it has not been told to
    // trust. Trusting the project the maestro is already working in is not
    // the same as letting the worker run anything: that would be --force.
    let read = spec(.cursor, model: "grok-4.7-low").arguments
    #expect(read == ["-p", "--model", "grok-4.7-low", "--output-format", "json", "--mode", "ask", "--trust", "--"])
    let edit = spec(.cursor, model: "grok-4.7-low", access: .edit).arguments
    #expect(edit == ["-p", "--model", "grok-4.7-low", "--output-format", "json", "--trust", "--"])
    #expect(!(read + edit).contains { ["--force", "-f", "--yolo"].contains($0) })
}

@Test func thePromptIsNeverAmongTheArgumentsAndNeverReadAsAFlag() {
    for cli in WorkerCLI.allCases {
        let arguments = spec(cli, model: "m", prompt: "--version").arguments
        #expect(!arguments.contains("--version"))
        // A CLI that only takes its prompt as an argument has it appended by
        // the launcher: after a `--` that ends the options, or fastened to
        // its flag, so a prompt that starts with a dash is never a flag.
        #expect(cli.takesPromptOnStdin || arguments.last == "--" || cli.promptFlag != nil)
    }
    #expect(WorkerCLI.allCases.filter { !$0.takesPromptOnStdin } == [.gemini, .cursor])
    #expect(WorkerCLI.gemini.promptFlag == "-p=")
    #expect(WorkerCLI.cursor.promptFlag == nil)
}

// MARK: - Which workers there are

@Test func claudeWorkersAreExactlyTheModelAndEffortPairsOnOffer() {
    for (model, effort) in [("haiku", "low"), ("haiku", "medium"), ("haiku", "high"), ("sonnet", "high"), ("opus", "low")] {
        #expect(throws: Never.self) { try spec(.claude, model: model, effort: effort).validate() }
    }
    // An effort is part of what a Claude worker is: there is no default one.
    #expect(throws: OrchestratorError.self) { try spec(.claude, model: "haiku").validate() }
    for (model, effort) in [("opus", "high"), ("sonnet", "low"), ("haiku", "max"), ("fable", "low"), ("claude-opus-5-5", "low")] {
        #expect(throws: OrchestratorError.self) { try spec(.claude, model: model, effort: effort).validate() }
    }
}

@Test func openCodeIsHeldToItsFreeModelsAtAnyEffort() {
    // The same CLI reaches paid providers billed per token. For now only the
    // models its own provider gives away may be delegated to.
    for model in ["opencode/deepseek-v4.1-flash-free", "opencode/glm-5.3-flash-free"] {
        #expect(throws: Never.self) { try spec(.opencode, model: model).validate() }
        #expect(throws: Never.self) { try spec(.opencode, model: model, effort: "high").validate() }
    }
    for model in ["openrouter/deepseek/deepseek-v4-pro", "opencode/big-pickle", "google/gemini-3.8-flash", "claude-agent/haiku", "x-free"] {
        #expect(throws: OrchestratorError.self) { try spec(.opencode, model: model).validate() }
    }
}

@Test func cursorIsHeldToItsGrokModelsWhoseEffortIsInTheirName() {
    for model in ["grok-4.7-low", "grok-4.7-xhigh-fast", "cursor-grok-4.6-medium", "cursor-grok-4.5-high"] {
        #expect(throws: Never.self) { try spec(.cursor, model: model).validate() }
    }
    for model in ["gpt-5.2", "claude-opus-5-5-low", "composer-2.5", "auto"] {
        #expect(throws: OrchestratorError.self) { try spec(.cursor, model: model).validate() }
    }
    // Asking for an effort apart from the id would be silently ignored, and
    // the run would then be filed under an effort it never had.
    #expect(throws: OrchestratorError.self) { try spec(.cursor, model: "grok-4.7-low", effort: "high").validate() }
}

@Test func geminiIsHeldToGeminiModelsWhoseEffortIsInTheirName() {
    for model in ["gemini-3.8-flash-low", "gemini-3.8-flash-medium", "gemini-3.8-flash-high"] {
        #expect(throws: Never.self) { try spec(.gemini, model: model).validate() }
    }
    // Antigravity offers Claude and GPT models too, on the same Google quota;
    // as workers it is Gemini only.
    for model in ["claude-sonnet-4-6", "gpt-oss-120b-medium", "gemini-3.8-flash"] {
        #expect(throws: OrchestratorError.self) { try spec(.gemini, model: model).validate() }
    }
    #expect(throws: OrchestratorError.self) { try spec(.gemini, model: "gemini-3.8-flash-low", effort: "high").validate() }
    // agy's allowed commands live only in its settings files, for every run
    // at once: it cannot be given a list for one worker, so it gets none.
    #expect(throws: OrchestratorError.self) {
        try spec(.gemini, model: "gemini-3.8-flash-low", access: .edit, commands: ["bun test"]).validate()
    }
}

@Test func aSpecIsRejectedBeforeAnythingIsSpawned() {
    let ok = "opencode/deepseek-v4.1-flash-free"
    #expect(throws: OrchestratorError.self) { try spec(.opencode, model: "").validate() }
    #expect(throws: OrchestratorError.self) { try spec(.gemini, model: "--yolo").validate() }
    #expect(throws: OrchestratorError.self) { try spec(.gemini, model: "gemini 3").validate() }
    #expect(throws: OrchestratorError.self) { try spec(.opencode, model: ok, effort: "very high").validate() }
    #expect(throws: OrchestratorError.self) { try spec(.opencode, model: ok, effort: "--auto").validate() }
    #expect(throws: OrchestratorError.self) { try spec(.opencode, model: ok, prompt: "  \n").validate() }
    #expect(throws: OrchestratorError.self) { try spec(.opencode, model: ok, directory: "/no/such/dir/anywhere").validate() }
    #expect(throws: OrchestratorError.self) { try spec(.opencode, model: ok, directory: "relative/path").validate() }
    #expect(throws: Never.self) { try spec(.opencode, model: ok).validate() }
}

@Test func aWorkerIsNamedByItsCLIModelAndEffort() {
    #expect(spec(.claude, model: "haiku", effort: "low").worker == "claude haiku (low)")
    #expect(spec(.cursor, model: "grok-4.7-high").worker == "cursor grok-4.7-high")
}

@Test func theMaestrosOwnSessionDoesNotLeakIntoAWorker() {
    // A worker spawned from inside a Claude session inherits variables that
    // point it at that session's auth and API host; with them it either fails
    // to authenticate or bills an API key instead of the subscription.
    let environment = Orchestrator.workerEnvironment(from: [
        "PATH": "/usr/bin",
        "HOME": "/Users/x",
        "CLAUDECODE": "1",
        "CLAUDE_CODE_ENTRYPOINT": "cli",
        "ANTHROPIC_BASE_URL": "http://localhost:1",
        "ANTHROPIC_API_KEY": "sk-nope",
        "OPENCODE_CONFIG": "/tmp/x.json",
    ])
    #expect(environment == ["PATH": "/usr/bin", "HOME": "/Users/x", "OPENCODE_CONFIG": "/tmp/x.json"])
}

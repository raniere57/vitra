import Foundation
import Testing
@testable import VitraOrchestrator

// The fixtures are trimmed copies of what the real CLIs printed
// (claude 2.1.296, opencode 2.2.5), not shapes guessed from documentation.

@Test func aClaudeResultCarriesItsTextCostAndTokens() {
    let stdout = """
    {"type":"result","subtype":"success","is_error":false,"result":"pong","session_id":"7b4dc657","total_cost_usd":0.0123,\
    "usage":{"input_tokens":120,"output_tokens":7,"cache_read_input_tokens":3000,"cache_creation_input_tokens":40}}
    """
    let output = WorkerOutput.parse(stdout, cli: .claude)
    #expect(output == WorkerOutput(
        text: "pong", isError: false, costUSD: 0.0123, inputTokens: 3160, outputTokens: 7, sessionID: "7b4dc657"
    ))
}

@Test func aClaudeFailureIsAnErrorWithTheReasonAsItsText() {
    let stdout = """
    {"type":"result","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed",\
    "session_id":"5a24","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}
    """
    let output = WorkerOutput.parse(stdout, cli: .claude)
    #expect(output.isError)
    #expect(output.text.hasPrefix("Failed to authenticate"))
}

private let openCodeEvents = """
{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}
{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"Let me look."}}
{"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","tool":"shell","state":{"input":{"command":"ls"}}}}
{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"tool-calls","cost":0.002,"tokens":{"input":9000,"output":20,"reasoning":0,"cache":{"read":1000,"write":0}}}}
{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}
{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"a.txt"}}
{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"b.txt"}}
{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop","cost":0.001,"tokens":{"input":9500,"output":4,"reasoning":6,"cache":{"read":500,"write":0}}}}
"""

@Test func anOpenCodeRunAnswersWithItsLastStepAndTheTotalsOfAllOfThem() {
    let output = WorkerOutput.parse(openCodeEvents, cli: .opencode)
    // The narration of earlier steps is not the answer; only the last step is.
    #expect(output.text == "a.txt\nb.txt")
    #expect(!output.isError)
    #expect(abs(output.costUSD - 0.003) < 1e-9)
    #expect(output.inputTokens == 20000)
    #expect(output.outputTokens == 30)
    #expect(output.sessionID == "ses_1")
}

@Test func anOpenCodeRunThatEndedOnAToolCallFallsBackToTheLastThingItSaid() {
    let cut = openCodeEvents.split(separator: "\n").prefix(5).joined(separator: "\n")
    #expect(WorkerOutput.parse(cut, cli: .opencode).text == "Let me look.")
}

@Test func anOpenCodeErrorEventMakesTheRunAnError() {
    let stdout = """
    {"type":"step_start","sessionID":"ses_2","part":{"type":"step-start"}}
    {"type":"error","sessionID":"ses_2","error":{"type":"provider.unknown","message":"Failed to authenticate: OAuth session expired and could not be refreshed"}}
    """
    let output = WorkerOutput.parse(stdout, cli: .opencode)
    #expect(output.isError)
    #expect(output.text == "Failed to authenticate: OAuth session expired and could not be refreshed")

    // An error with no message still says what kind it was.
    let bare = WorkerOutput.parse(#"{"type":"error","error":{"type":"provider.unknown"}}"#, cli: .opencode)
    #expect(bare.text == "provider.unknown")
}

// agy 1.1.15's print mode, captured from real runs.

@Test func aGeminiResultCarriesItsResponseAndItsTokens() {
    let stdout = #"{"conversation_id":"4eb1","status":"SUCCESS","response":"pong\n","duration_seconds":2.2,"num_turns":1,"usage":{"input_tokens":6866,"output_tokens":1,"thinking_tokens":3,"cache_read_tokens":100,"total_tokens":6867}}"#
    #expect(WorkerOutput.parse(stdout, cli: .gemini) == WorkerOutput(
        text: "pong", isError: false, costUSD: 0, inputTokens: 6966, outputTokens: 4, sessionID: "4eb1"
    ))
}

@Test func aGeminiErrorIsAnErrorWithItsMessage() {
    let stdout = #"{"conversation_id":"","status":"ERROR","response":"","error":"invalid model selection (--model \"x\")","usage":{"input_tokens":0,"output_tokens":0}}"#
    let output = WorkerOutput.parse(stdout, cli: .gemini)
    #expect(output.isError)
    #expect(output.text == "invalid model selection (--model \"x\")")
}

@Test func aGeminiRunThatWasRefusedWhatItNeededSaysSo() {
    // Headless, agy refuses what it would have asked about, and answers with
    // nothing: what it was refused is the only account of why.
    let stdout = #"{"conversation_id":"357f","status":"SUCCESS","response":"","num_turns":1,"usage":{"input_tokens":7020,"output_tokens":176},"denied_actions":[{"action":"command","display_name":"RunCommand"},{"action":"write_file","display_name":"WriteFile"}]}"#
    let output = WorkerOutput.parse(stdout, cli: .gemini)
    #expect(output.isError)
    #expect(output.text == "refused without anyone to approve it: RunCommand, WriteFile")
    // With an answer as well, the answer stands and the refusal is noted.
    let partly = stdout.replacingOccurrences(of: #""response":"""#, with: #""response":"half done""#)
    let both = WorkerOutput.parse(partly, cli: .gemini)
    #expect(!both.isError)
    #expect(both.text == "half done\n\n(refused without anyone to approve it: RunCommand, WriteFile)")
}

@Test func aCursorResultIsReadLikeAClaudeOne() {
    let stdout = """
    {"type":"result","subtype":"success","is_error":false,"duration_ms":4200,"duration_api_ms":4200,"result":"pong","session_id":"c-1","request_id":"r-1","usage":{"inputTokens":800,"outputTokens":12,"cacheReadTokens":300}}
    """
    #expect(WorkerOutput.parse(stdout, cli: .cursor) == WorkerOutput(
        text: "pong", isError: false, costUSD: 0, inputTokens: 1100, outputTokens: 12, sessionID: "c-1"
    ))
    // No usage at all is the common case, and not an error.
    let bare = WorkerOutput.parse(#"{"type":"result","is_error":false,"result":"ok","session_id":"c-2"}"#, cli: .cursor)
    #expect(bare == WorkerOutput(text: "ok", isError: false, sessionID: "c-2"))
}

@Test func outputThatIsNotTheExpectedJSONIsKeptAsAnErrorRatherThanDropped() {
    for cli in WorkerCLI.allCases {
        let output = WorkerOutput.parse("zsh: command not found: thing\n", cli: cli)
        #expect(output.isError)
        #expect(output.text == "zsh: command not found: thing")
    }
}

@Test func emptyOutputIsAnError() {
    for cli in WorkerCLI.allCases {
        #expect(WorkerOutput.parse("", cli: cli).isError)
    }
}

// MARK: Provider failures

@Test("A provider's own words say why the run did not run", arguments: [
    ("Free usage limit reached. Upgrade to continue.", "quota"),
    ("Claude AI usage limit reached|1731000000", "quota"),
    ("You have hit your rate limit", "quota"),
    ("rate_limit_error: slow down", "quota"),
    ("Error: 429 Too Many Requests", "quota"),
    ("Your credit balance is too low to access the API", "quota"),
    ("Quota exceeded for this model", "quota"),
    ("Authentication required", "signed out"),
    ("Not logged in · Please run /login", "signed out"),
    ("You are not signed in", "signed out"),
    ("Please log in to continue", "signed out"),
    ("API Error: 529 overloaded_error", "unavailable"),
    ("HTTP 503 Service Unavailable", "unavailable"),
    ("upstream said: 502 Bad Gateway", "unavailable"),
    ("status: 500", "unavailable"),
])
func aProviderFailureIsRecognisedFromItsWords(text: String, name: String) {
    let failure = ProviderFailure.detect(text: text, errorTail: nil)
    #expect(failure?.name == name)
    #expect(failure?.reason == text)
    // On stderr, when stdout said nothing, it is the same.
    #expect(ProviderFailure.detect(text: "the agent printed nothing", errorTail: text)?.name == name)
}

@Test func aFailureThatIsAboutSomethingElseIsNotTheProvidersAndTheReasonIsTheMatchedLine() {
    // A task about logins that failed, a line number, a long report: the
    // worker ran and failed on its own.
    #expect(ProviderFailure.detect(text: "3 tests failed in login.test.ts", errorTail: nil) == nil)
    #expect(ProviderFailure.detect(text: "could not find the function on line 500", errorTail: nil) == nil)
    #expect(ProviderFailure.detect(text: "the build broke", errorTail: "error: expected ';'") == nil)
    let long = String(repeating: "the quota module is wrong. ", count: 60)
    #expect(ProviderFailure.detect(text: long, errorTail: nil) == nil)
    // Several lines: the one that matched is the reason.
    let multi = ProviderFailure.detect(text: "starting\nFree usage limit reached\nbye", errorTail: nil)
    #expect(multi == .quota("Free usage limit reached"))
}

@Test func howLongEachKindKeepsItsCLIOut() {
    #expect(ProviderFailure.quota("x").stall == 3600)
    #expect(ProviderFailure.unavailable("x").stall == 600)
    // A sign-in lasts until a later run of the CLI works.
    #expect(ProviderFailure.signedOut("x").stall == nil)
}

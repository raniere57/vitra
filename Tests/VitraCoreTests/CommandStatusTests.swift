import Foundation
import Testing
@testable import VitraCore

@Test func aFinishedCommandCarriesItsCodeAndDuration() throws {
    let status = try #require(CommandStatus.parse(payload: "vitra-block;code=2;ms=412"))

    #expect(status.exitCode == 2)
    #expect(abs(status.duration - 0.412) < 0.001)
    #expect(status.failed)
}

/// A bare Return still closes a block, which is what keeps the statuses lined
/// up with the prompts on screen.
@Test func aPromptWhereNothingRanHasNoCode() throws {
    let status = try #require(CommandStatus.parse(payload: "vitra-block"))

    #expect(status.exitCode == nil)
    #expect(!status.failed)
    #expect(status.label == nil)
}

@Test func aPreviewRequestIsNotABlockStatus() {
    #expect(CommandStatus.parse(payload: "file=/tmp/report.html") == nil)
}

@Test func aFailureIsLabelledWithItsCode() {
    #expect(CommandStatus(exitCode: 1, duration: 0.4).label == "exit 1")
    #expect(CommandStatus(exitCode: 1, duration: 2.5).label == "exit 1 · 2.5s")
}

/// Every line reading "0.0s" is a column the eye stops reading.
@Test func aFastSuccessIsNotLabelledAtAll() {
    #expect(CommandStatus(exitCode: 0, duration: 0.02).label == nil)
    #expect(CommandStatus(exitCode: 0, duration: 1.4).label == "1.4s")
}

@Test func longRunsAreLabelledInMinutes() {
    #expect(CommandStatus(exitCode: 0, duration: 154).label == "2m 34s")
}

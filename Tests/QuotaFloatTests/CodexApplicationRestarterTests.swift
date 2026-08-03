import AppKit
import XCTest

@testable import QuotaFloat

@MainActor
final class CodexApplicationRestarterTests: XCTestCase {
  func testWaitsForNormalTerminationBeforeOpeningNewInstance() async throws {
    let application = FakeRunningApplication()
    let opener = FakeApplicationOpener()
    var polls = 0
    let restarter = CodexApplicationRestarter(
      opener: opener,
      normalExitPollCount: 3,
      forcedExitPollCount: 1,
      sleep: { _ in
        polls += 1
        if polls == 2 { application.isTerminated = true }
      })

    try await restarter.restart(
      application: application,
      appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"))

    XCTAssertEqual(application.terminateCallCount, 1)
    XCTAssertEqual(application.forceTerminateCallCount, 0)
    XCTAssertEqual(polls, 2)
    XCTAssertEqual(opener.openCallCount, 1)
    XCTAssertEqual(opener.createsNewApplicationInstance, true)
    XCTAssertEqual(opener.allowsRunningApplicationSubstitution, false)
  }

  func testForceTerminatesAfterNormalExitTimeoutThenOpens() async throws {
    let application = FakeRunningApplication()
    let opener = FakeApplicationOpener()
    var polls = 0
    let restarter = CodexApplicationRestarter(
      opener: opener,
      normalExitPollCount: 2,
      forcedExitPollCount: 2,
      sleep: { _ in
        polls += 1
        if application.forceTerminateCallCount == 1 { application.isTerminated = true }
      })

    try await restarter.restart(
      application: application,
      appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"))

    XCTAssertEqual(application.terminateCallCount, 1)
    XCTAssertEqual(application.forceTerminateCallCount, 1)
    XCTAssertEqual(opener.openCallCount, 1)
  }

  func testDoesNotOpenWhenApplicationStillCannotTerminate() async {
    let application = FakeRunningApplication()
    let opener = FakeApplicationOpener()
    let restarter = CodexApplicationRestarter(
      opener: opener,
      normalExitPollCount: 1,
      forcedExitPollCount: 1,
      sleep: { _ in })

    do {
      try await restarter.restart(
        application: application,
        appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
      XCTFail("Expected termination timeout")
    } catch {
      XCTAssertEqual(error as? CodexApplicationRestarter.RestartError, .terminationTimedOut)
    }
    XCTAssertEqual(opener.openCallCount, 0)
  }

  func testSurfacesLaunchFailure() async {
    let application = FakeRunningApplication(isTerminated: true)
    let opener = FakeApplicationOpener(launchSucceeded: false)
    let restarter = CodexApplicationRestarter(opener: opener, sleep: { _ in })

    do {
      try await restarter.restart(
        application: application,
        appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
      XCTFail("Expected launch failure")
    } catch {
      XCTAssertEqual(error as? CodexApplicationRestarter.RestartError, .launchDidNotStart)
    }
  }
}

@MainActor
private final class FakeRunningApplication: CodexRunningApplication {
  var isTerminated: Bool
  var terminateCallCount = 0
  var forceTerminateCallCount = 0

  init(isTerminated: Bool = false) {
    self.isTerminated = isTerminated
  }

  func terminate() -> Bool {
    self.terminateCallCount += 1
    return true
  }

  func forceTerminate() -> Bool {
    self.forceTerminateCallCount += 1
    return true
  }
}

@MainActor
private final class FakeApplicationOpener: CodexApplicationOpening {
  let launchSucceeded: Bool
  var openCallCount = 0
  var createsNewApplicationInstance: Bool?
  var allowsRunningApplicationSubstitution: Bool?

  init(launchSucceeded: Bool = true) {
    self.launchSucceeded = launchSucceeded
  }

  func openApplication(
    at url: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws -> Bool {
    self.openCallCount += 1
    self.createsNewApplicationInstance = configuration.createsNewApplicationInstance
    self.allowsRunningApplicationSubstitution = configuration.allowsRunningApplicationSubstitution
    return self.launchSucceeded
  }
}

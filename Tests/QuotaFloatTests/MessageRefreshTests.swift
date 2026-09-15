import AppKit
import SwiftUI
import XCTest

@testable import QuotaFloat

@MainActor
final class MessageRefreshTests: XCTestCase {
  func testManualRefreshWorksWithAutomaticUpdatesDisabledAndShowsNoNewResult() async throws {
    let fixture = try RefreshFixture()
    defer { fixture.cleanUp() }
    fixture.store.tick()
    var calls = await fixture.fetcher.calls
    XCTAssertEqual(calls, 0)
    fixture.store.refresh(manual: true)
    XCTAssertTrue(fixture.store.isRefreshing)
    try await settle(fixture.store)
    calls = await fixture.fetcher.calls
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(fixture.store.enabled)
    XCTAssertFalse(fixture.defaults.bool(forKey: "resetSignalsEnabled"))
    XCTAssertNotNil(fixture.store.archive.lastSuccess)
    XCTAssertEqual(fixture.store.refreshFeedback, "已检查，没有新消息")
  }

  func testRepeatedClicksAreCoalescedAndNativeButtonInvokesRefresh() async throws {
    let fixture = try RefreshFixture()
    defer { fixture.cleanUp() }
    let host = NSHostingView(
      rootView: NativeMessageRefreshButton(isRefreshing: false) {
        fixture.store.refresh(manual: true)
      })
    host.frame = NSRect(x: 0, y: 0, width: 28, height: 24)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    let button = try XCTUnwrap(findButton(host))
    XCTAssertNotNil(button.target)
    button.performClick(nil)
    XCTAssertTrue(fixture.store.isRefreshing)
    fixture.store.refresh(manual: true)
    fixture.store.refresh(manual: true)
    try await settle(fixture.store)
    let count = await fixture.fetcher.calls
    XCTAssertEqual(count, 1)
  }

  func testRefreshFailureIsVisibleAndCanRetry() async throws {
    let fixture = try RefreshFixture()
    defer { fixture.cleanUp() }
    await fixture.fetcher.setFailure(true)
    fixture.store.refresh(manual: true)
    try await settle(fixture.store)
    XCTAssertEqual(fixture.store.refreshFeedback, "检查失败，稍后重试")
    XCTAssertNil(fixture.store.archive.lastSuccess)
    await fixture.fetcher.setFailure(false)
    fixture.store.refresh(manual: true)
    try await settle(fixture.store)
    XCTAssertNil(fixture.store.message)
    XCTAssertEqual(fixture.store.refreshFeedback, "已检查，没有新消息")
  }

  func testNewMessageShowsUpdatedAndRepeatedFetchShowsNoNew() async throws {
    let fixture = try RefreshFixture()
    defer { fixture.cleanUp() }
    await fixture.fetcher.setMessage()
    fixture.store.refresh(manual: true)
    try await settle(fixture.store)
    XCTAssertEqual(fixture.store.refreshFeedback, "消息已更新")
    XCTAssertEqual(fixture.store.archive.signals.count, 1)
    fixture.store.refresh(manual: true)
    try await settle(fixture.store)
    XCTAssertEqual(fixture.store.refreshFeedback, "已检查，没有新消息")
  }

  private func findButton(_ view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.identifier?.rawValue == "quota-message-refresh" {
      return button
    }
    return view.subviews.lazy.compactMap { self.findButton($0) }.first
  }

  private func settle(_ store: ResetSignalStore) async throws {
    for _ in 0..<200 {
      if !store.isRefreshing { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Refresh did not complete")
  }
}

private actor RefreshFetcherFixture: ResetSignalFetching {
  var calls = 0
  var fails = false
  var signals: [ResetSignal] = []
  func setFailure(_ value: Bool) { fails = value }
  func setMessage() {
    signals = [
      .init(
        id: "2098685367058612394", publishedAt: Date(), discoveredAt: Date(),
        excerpt: "Reset all propagated.", state: .completed, deadline: nil, timeAssumption: "",
        scope: "", verified: true, linkedPostID: nil, resolutionID: nil)
    ]
  }
  func fetch(now: Date, known: [ResetSignal]) async throws -> [ResetSignal] {
    calls += 1
    try await Task.sleep(for: .milliseconds(20))
    if fails { throw URLError(.notConnectedToInternet) }
    return signals
  }
  func importPost(url: URL, now: Date) async throws -> ResetSignal {
    throw URLError(.unsupportedURL)
  }
}

@MainActor
private final class RefreshFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let defaults: UserDefaults
  let fetcher = RefreshFetcherFixture()
  let store: ResetSignalStore
  init() throws {
    defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    store = ResetSignalStore(
      url: root.appendingPathComponent("signals.json"), defaults: defaults, fetcher: fetcher)
  }
  func cleanUp() {
    store.stop()
    defaults.removePersistentDomain(forName: root.lastPathComponent)
    try? FileManager.default.removeItem(at: root)
  }
}

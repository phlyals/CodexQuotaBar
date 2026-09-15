import Foundation
import UserNotifications
import XCTest

@testable import QuotaFloat

final class QuotaNotificationServiceTests: XCTestCase {
  @MainActor
  func testAuthorizedToggleSavesAndRestoresWithoutPrompt() async throws {
    let fixture = try NotificationFixture()
    defer { fixture.cleanUp() }
    var prompts = 0
    fixture.service.setEnabled(true) { prompts += 1 }
    XCTAssertTrue(fixture.service.isRequestingPermission)
    try await eventually { !fixture.service.isRequestingPermission }
    XCTAssertTrue(fixture.service.enabled)
    XCTAssertTrue(fixture.defaults.bool(forKey: "quotaNotificationsEnabled"))
    XCTAssertEqual(prompts, 0)
    XCTAssertEqual(fixture.client.requests, 0)
    let restored = QuotaNotificationService(
      defaults: fixture.defaults, url: fixture.root.appendingPathComponent("restored.json"),
      inspectSystemPermission: false, client: fixture.client)
    XCTAssertTrue(restored.enabled)
    fixture.service.setEnabled(false)
    XCTAssertFalse(fixture.service.enabled)
    XCTAssertFalse(fixture.defaults.bool(forKey: "quotaNotificationsEnabled"))
  }

  @MainActor
  func testFirstAuthorizationHasFeedbackAndCoalescesClicks() async throws {
    let fixture = try NotificationFixture(status: .notDetermined)
    defer { fixture.cleanUp() }
    fixture.client.holdRequest = true
    var prepared = false
    fixture.service.setEnabled(true) { prepared = true }
    fixture.service.setEnabled(true)
    XCTAssertTrue(fixture.service.isRequestingPermission)
    XCTAssertEqual(fixture.service.permission, "正在检查通知权限…")
    try await eventually { fixture.client.requestContinuation != nil }
    XCTAssertTrue(prepared)
    XCTAssertEqual(fixture.client.requests, 1)
    XCTAssertEqual(fixture.service.permission, "请在系统提示中允许通知")
    XCTAssertFalse(fixture.service.enabled)
    fixture.client.resolveRequest(true)
    try await eventually { !fixture.service.isRequestingPermission }
    XCTAssertTrue(fixture.service.enabled)
    XCTAssertFalse(fixture.service.needsSystemSettings)
  }

  @MainActor
  func testDeniedPermissionShowsSettingsWithoutRequestingAgain() async throws {
    let fixture = try NotificationFixture(status: .denied)
    defer { fixture.cleanUp() }
    fixture.service.setEnabled(true) { XCTFail("Denied permission cannot prompt again") }
    try await eventually { !fixture.service.isRequestingPermission }
    XCTAssertFalse(fixture.service.enabled)
    XCTAssertTrue(fixture.service.needsSystemSettings)
    XCTAssertTrue(fixture.service.permission.contains("系统通知设置"))
    XCTAssertEqual(fixture.client.requests, 0)
  }

  @MainActor
  func testDecliningFirstPromptLeavesUncheckedWithReason() async throws {
    let fixture = try NotificationFixture(status: .notDetermined)
    defer { fixture.cleanUp() }
    fixture.client.grantsRequest = false
    fixture.service.setEnabled(true)
    try await eventually { !fixture.service.isRequestingPermission }
    XCTAssertFalse(fixture.service.enabled)
    XCTAssertTrue(fixture.service.needsSystemSettings)
    XCTAssertFalse(fixture.defaults.bool(forKey: "quotaNotificationsEnabled"))
  }

  @MainActor
  func testAuthorizationErrorIsVisibleAndCanRetry() async throws {
    let fixture = try NotificationFixture(status: .notDetermined)
    defer { fixture.cleanUp() }
    fixture.client.requestFails = true
    fixture.service.setEnabled(true)
    try await eventually { !fixture.service.isRequestingPermission }
    XCTAssertFalse(fixture.service.enabled)
    XCTAssertTrue(fixture.service.permission.contains("授权失败"))
    XCTAssertTrue(fixture.service.needsSystemSettings)
    await fixture.service.refreshPermission()
    XCTAssertTrue(fixture.service.permission.contains("授权失败"))
    XCTAssertTrue(fixture.service.needsSystemSettings)
    fixture.client.requestFails = false
    fixture.service.setEnabled(true)
    try await eventually { !fixture.service.isRequestingPermission }
    XCTAssertTrue(fixture.service.enabled)
    XCTAssertFalse(fixture.service.needsSystemSettings)
  }

  @MainActor
  func testTurningOffDuringPromptRejectsLateGrant() async throws {
    let fixture = try NotificationFixture(status: .notDetermined)
    defer { fixture.cleanUp() }
    fixture.client.holdRequest = true
    fixture.service.setEnabled(true)
    try await eventually { fixture.client.requestContinuation != nil }
    fixture.service.setEnabled(false)
    fixture.client.resolveRequest(true)
    try await eventually { fixture.client.requestCompletions == 1 }
    await Task.yield()
    XCTAssertFalse(fixture.service.enabled)
    XCTAssertFalse(fixture.service.isRequestingPermission)
    XCTAssertFalse(fixture.defaults.bool(forKey: "quotaNotificationsEnabled"))
    XCTAssertEqual(fixture.service.permission, "提醒已关闭")
  }

  @MainActor
  func testOldPermissionInspectionCannotOverwriteNewRequestResult() async throws {
    let fixture = try NotificationFixture(status: .denied)
    defer { fixture.cleanUp() }
    fixture.client.holdNextStatus = true
    let oldInspection = Task { await fixture.service.refreshPermission() }
    try await eventually { fixture.client.statusContinuation != nil }
    fixture.service.setEnabled(true)
    try await eventually { !fixture.service.isRequestingPermission }
    fixture.client.resolveStatus(.authorized)
    await oldInspection.value
    XCTAssertFalse(fixture.service.enabled)
    XCTAssertTrue(fixture.service.needsSystemSettings)
  }

  @MainActor
  func testSystemSettingsChangesAreRecheckedWithoutAutoEnabling() async throws {
    let fixture = try NotificationFixture(status: .denied)
    defer { fixture.cleanUp() }
    await fixture.service.refreshPermission()
    XCTAssertTrue(fixture.service.needsSystemSettings)
    fixture.client.status = .authorized
    await fixture.service.refreshPermission()
    XCTAssertFalse(fixture.service.enabled)
    XCTAssertFalse(fixture.service.needsSystemSettings)
    fixture.service.setEnabled(true)
    try await eventually { !fixture.service.isRequestingPermission }
    XCTAssertTrue(fixture.service.enabled)
    fixture.client.status = .denied
    await fixture.service.refreshPermission()
    XCTAssertFalse(fixture.service.enabled)
    XCTAssertFalse(fixture.defaults.bool(forKey: "quotaNotificationsEnabled"))
  }

  @MainActor
  func testTurningOffPreventsDeliveryWaitingOnPermission() async throws {
    let fixture = try NotificationFixture()
    defer { fixture.cleanUp() }
    fixture.service.setEnabled(true)
    try await eventually { !fixture.service.isRequestingPermission }
    fixture.service.quietEnabled = false
    fixture.client.holdNextStatus = true
    let now = Date()
    let snapshot = QuotaSnapshot(
      provider: .codex, session: nil,
      weekly: QuotaWindow(
        usedPercent: 95, resetsAt: now.addingTimeInterval(3600), windowMinutes: 10080),
      resetCredits: nil, accountEmail: nil,
      accountKey: "notification-fixture", source: "fixture", updatedAt: now,
      freshness: .fresh, message: nil)
    fixture.service.process(snapshot, signals: [], now: now)
    try await eventually { fixture.client.statusContinuation != nil }
    fixture.service.setEnabled(false)
    fixture.client.resolveStatus(.authorized)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(fixture.client.delivered.isEmpty)
  }

  @MainActor
  func testQuietHoursDeferSignalUntilQuietEndsAndDeduplicate() async throws {
    let fixture = try NotificationFixture()
    defer { fixture.cleanUp() }
    fixture.service.setEnabled(true)
    try await eventually { !fixture.service.isRequestingPermission }
    let published = Date().addingTimeInterval(1)
    let now = published.addingTimeInterval(60)
    let hour = Calendar.current.component(.hour, from: now)
    fixture.service.quietEnabled = true
    fixture.service.quietStart = hour
    fixture.service.quietEnd = (hour + 1) % 24
    let signal = ResetSignal(
      id: "2098685367058612394", publishedAt: published, discoveredAt: now,
      excerpt: "reset complete", state: .completed, deadline: nil, timeAssumption: "",
      scope: "unknown", verified: true, linkedPostID: nil, resolutionID: nil)
    fixture.service.process(nil, signals: [signal], now: now)
    await Task.yield()
    XCTAssertTrue(fixture.client.delivered.isEmpty)
    let later = now.addingTimeInterval(2 * 3600)
    fixture.service.process(nil, signals: [signal], now: later)
    try await eventually { fixture.client.delivered.count == 1 }
    fixture.service.process(nil, signals: [signal], now: later)
    await Task.yield()
    XCTAssertEqual(fixture.client.delivered.count, 1)
    XCTAssertTrue(fixture.client.delivered[0].title.contains("补提醒"))
  }

  @MainActor
  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for the notification state transition")
  }
}

@MainActor
final class NotificationClientFixture: QuotaNotificationClient {
  var status: UNAuthorizationStatus
  var requests = 0
  var requestCompletions = 0
  var grantsRequest = true
  var requestFails = false
  var holdRequest = false
  var holdNextStatus = false
  var delivered: [QuotaNotice] = []
  var requestContinuation: CheckedContinuation<Bool, Never>?
  var statusContinuation: CheckedContinuation<UNAuthorizationStatus, Never>?

  init(status: UNAuthorizationStatus = .authorized) { self.status = status }

  func authorizationStatus() async -> UNAuthorizationStatus {
    if holdNextStatus {
      holdNextStatus = false
      return await withCheckedContinuation { statusContinuation = $0 }
    }
    return status
  }

  func requestAuthorization() async throws -> Bool {
    requests += 1
    if requestFails { throw CocoaError(.coderInvalidValue) }
    let granted: Bool
    if holdRequest {
      granted = await withCheckedContinuation { requestContinuation = $0 }
    } else {
      granted = grantsRequest
    }
    status = granted ? .authorized : .denied
    requestCompletions += 1
    return granted
  }

  func add(_ notice: QuotaNotice) async throws { delivered.append(notice) }

  func resolveRequest(_ granted: Bool) {
    requestContinuation?.resume(returning: granted)
    requestContinuation = nil
  }

  func resolveStatus(_ status: UNAuthorizationStatus) {
    statusContinuation?.resume(returning: status)
    statusContinuation = nil
  }
}

@MainActor
private final class NotificationFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let defaults: UserDefaults
  let client: NotificationClientFixture
  let service: QuotaNotificationService

  init(status: UNAuthorizationStatus = .authorized) throws {
    defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    client = NotificationClientFixture(status: status)
    service = QuotaNotificationService(
      defaults: defaults, url: root.appendingPathComponent("ledger.json"),
      inspectSystemPermission: false, client: client)
  }

  func cleanUp() {
    service.stop()
    client.resolveStatus(.denied)
    client.resolveRequest(false)
    defaults.removePersistentDomain(forName: root.lastPathComponent)
    try? FileManager.default.removeItem(at: root)
  }
}

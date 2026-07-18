import Testing
@testable import QuotaFloat

@MainActor
final class LaunchAtLoginControllerTests {
  @Test
  func toggleEnablesWhenDisabled() throws {
    let service = MemoryLaunchAtLoginService(isEnabled: false)
    let controller = LaunchAtLoginController(service: service)

    let result = try controller.toggle()

    #expect(result == true)
    #expect(service.isEnabled == true)
  }

  @Test
  func toggleDisablesWhenEnabled() throws {
    let service = MemoryLaunchAtLoginService(isEnabled: true)
    let controller = LaunchAtLoginController(service: service)

    let result = try controller.toggle()

    #expect(result == false)
    #expect(service.isEnabled == false)
  }
}

@MainActor
private final class MemoryLaunchAtLoginService: LaunchAtLoginServicing {
  var isEnabled: Bool

  init(isEnabled: Bool) {
    self.isEnabled = isEnabled
  }

  func setEnabled(_ enabled: Bool) throws {
    self.isEnabled = enabled
  }
}

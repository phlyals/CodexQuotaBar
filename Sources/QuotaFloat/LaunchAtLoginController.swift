import AppKit
import ServiceManagement

@MainActor
protocol LaunchAtLoginServicing {
  var isEnabled: Bool { get }
  func setEnabled(_ enabled: Bool) throws
}

struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
  var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      guard SMAppService.mainApp.status != .enabled else { return }
      try SMAppService.mainApp.register()
      return
    }

    guard SMAppService.mainApp.status == .enabled else { return }
    try SMAppService.mainApp.unregister()
  }
}

@MainActor
final class LaunchAtLoginController {
  private let service: any LaunchAtLoginServicing

  init(service: any LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
    self.service = service
  }

  var isEnabled: Bool {
    self.service.isEnabled
  }

  @discardableResult
  func toggle() throws -> Bool {
    try self.service.setEnabled(!self.service.isEnabled)
    return self.service.isEnabled
  }
}

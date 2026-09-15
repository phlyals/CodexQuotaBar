import AppKit
import SwiftUI

struct NativeMessageRefreshButton: NSViewRepresentable {
  let isRefreshing: Bool
  let action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新消息")!,
      target: context.coordinator, action: #selector(Coordinator.refresh))
    button.bezelStyle = .regularSquare
    button.controlSize = .small
    button.toolTip = "刷新消息"
    button.identifier = NSUserInterfaceItemIdentifier("quota-message-refresh")
    button.setAccessibilityIdentifier("quota-message-refresh")
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    button.isEnabled = !isRefreshing
  }

  @MainActor
  final class Coordinator: NSObject {
    var action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func refresh() { action() }
  }
}

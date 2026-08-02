import Combine
import Foundation

@MainActor
final class CodexDashboardStore: ObservableObject {
  @Published private(set) var quota: QuotaSnapshot?
  @Published private(set) var localUsage: CodexLocalUsageSnapshot?
  @Published private(set) var isLoadingLocalUsage = false
  @Published private(set) var localUsageMessage: String?

  private let quotaStore: QuotaStore
  private let localUsageFetcher: any CodexLocalUsageFetching
  private var localUsageTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []

  init(
    quotaStore: QuotaStore,
    localUsageFetcher: any CodexLocalUsageFetching = CodexCostHelper()
  ) {
    self.quotaStore = quotaStore
    self.localUsageFetcher = localUsageFetcher
    self.quota = quotaStore.snapshot(for: .codex)
    quotaStore.$snapshots
      .map { $0[.codex] }
      .receive(on: RunLoop.main)
      .sink { [weak self] in self?.quota = $0 }
      .store(in: &self.cancellables)
  }

  func refreshLocalUsage(force: Bool = false) {
    guard self.localUsageTask == nil else { return }
    let fetcher = self.localUsageFetcher
    self.isLoadingLocalUsage = true
    self.localUsageMessage = nil
    self.localUsageTask = Task { [weak self] in
      do {
        let snapshot = try await fetcher.fetch(forceRefresh: force)
        guard let self, !Task.isCancelled else { return }
        self.localUsage = snapshot
        self.localUsageMessage = nil
        self.finishLocalUsageRefresh()
      } catch is CancellationError {
        self?.finishLocalUsageRefresh()
      } catch {
        guard let self else { return }
        self.localUsageMessage = error.localizedDescription
        self.finishLocalUsageRefresh()
      }
    }
  }

  func stop() {
    self.localUsageTask?.cancel()
    self.localUsageTask = nil
    self.isLoadingLocalUsage = false
  }

  private func finishLocalUsageRefresh() {
    self.localUsageTask = nil
    self.isLoadingLocalUsage = false
  }
}

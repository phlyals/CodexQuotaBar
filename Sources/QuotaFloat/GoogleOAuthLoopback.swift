import Foundation
import Network

@MainActor
final class GoogleOAuthLoopback {
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var continuation: CheckedContinuation<(URL, String), Error>?
  private var redirect: URL?
  private var deadline: Task<Void, Never>?

  func authorize(
    state: String, timeout: Duration = .seconds(180),
    openBrowser: @escaping @MainActor (URL) throws -> Void
  ) async throws -> (URL, String) {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        deadline = Task {
          do { try await Task.sleep(for: timeout) } catch { return }
          finish(.failure(GoogleOAuthError.timeout))
        }
        listener.stateUpdateHandler = { [weak self] status in
          MainActor.assumeIsolated {
            guard let self, self.continuation != nil else { return }
            switch status {
            case .ready:
              guard self.redirect == nil else { return }
              guard let port = self.listener?.port,
                let url = URL(string: "http://127.0.0.1:\(port.rawValue)/callback")
              else {
                self.finish(.failure(GoogleOAuthError.callback))
                return
              }
              self.redirect = url
              do { try openBrowser(url) } catch { self.finish(.failure(error)) }
            case .failed, .cancelled:
              self.finish(.failure(GoogleOAuthError.callback))
            default: break
            }
          }
        }
        listener.newConnectionHandler = { [weak self] connection in
          MainActor.assumeIsolated {
            guard let self, self.continuation != nil, self.connections.count < 16 else {
              connection.cancel()
              return
            }
            self.connections[ObjectIdentifier(connection)] = connection
            connection.start(queue: .main)
            self.receive(connection, state: state, partial: Data())
          }
        }
        listener.start(queue: .main)
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }

  private func receive(_ connection: NWConnection, state: String, partial: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self] data, _, complete, error in
      MainActor.assumeIsolated {
        guard let self, self.continuation != nil, let redirect = self.redirect else {
          connection.cancel()
          return
        }
        var buffer = partial
        if let data { buffer.append(data) }
        if error == nil, buffer.count <= 16_384,
          let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        {
          let answer = Self.parse(
            header: String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self),
            state: state, port: redirect.port)
          let body =
            answer == nil ? "Invalid callback." : "You can close this tab and return to QuotaFloat."
          let status = answer == nil ? "400 Bad Request" : "200 OK"
          let response =
            "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
          self.connections.removeValue(forKey: ObjectIdentifier(connection))
          connection.send(
            content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() }
          )
          if let answer { self.finish(answer.map { (redirect, $0) }.mapError { $0 as Error }) }
        } else if error == nil, !complete, buffer.count < 16_384 {
          self.receive(connection, state: state, partial: buffer)
        } else {
          self.connections.removeValue(forKey: ObjectIdentifier(connection))
          connection.cancel()
        }
      }
    }
  }

  // Invalid requests (including unrelated tabs or stale states) leave the current login pending.
  static func parse(header: String, state: String, port: Int?) -> Result<String, GoogleOAuthError>?
  {
    let lines = header.components(separatedBy: "\r\n")
    let request = lines[0].split(separator: " ")
    guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1", let port,
      request[1].hasPrefix("/callback?"),
      let components = URLComponents(string: String(request[1])), components.path == "/callback",
      components.fragment == nil, let query = components.queryItems
    else { return nil }
    let hosts = lines.dropFirst().compactMap { line -> String? in
      let field = line.split(separator: ":", maxSplits: 1)
      guard field.count == 2, field[0].lowercased() == "host" else { return nil }
      return field[1].trimmingCharacters(in: .whitespaces)
    }
    let states = query.filter { $0.name == "state" }
    guard hosts == ["127.0.0.1:\(port)"], states.count == 1, states[0].value == state else {
      return nil
    }
    let codes = query.filter { $0.name == "code" }
    let errors = query.filter { $0.name == "error" }
    if errors.count == 1, errors[0].value?.isEmpty == false, codes.isEmpty {
      return .failure(.denied)
    }
    guard errors.isEmpty, codes.count == 1, let code = codes[0].value, !code.isEmpty else {
      return nil
    }
    return .success(code)
  }

  private func finish(_ result: Result<(URL, String), Error>) {
    guard let pending = continuation else { return }
    continuation = nil
    deadline?.cancel()
    deadline = nil
    listener?.cancel()
    listener = nil
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
    pending.resume(with: result)
  }
}

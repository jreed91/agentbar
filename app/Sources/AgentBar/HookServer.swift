import CryptoKit
import Foundation
import Network
import Security

/// Minimal HTTP/1.1 server over Network.framework, bound to loopback on an ephemeral
/// port. Authenticates with a per-launch bearer token and publishes port + token to
/// `~/Library/Application Support/AgentBar/server.json` (mode 0600) for the hook script.
final class HookServer {
    private let queue = DispatchQueue(label: "com.jreed91.AgentBar.hookserver")
    private var listener: NWListener?

    /// 32-byte hex bearer token, regenerated each launch.
    let token: String

    private let maxBodyBytes = 1 << 20 // 1 MiB

    /// The app's marketing version, surfaced in `server.json` and `/v1/health` for
    /// staleness diagnostics. Falls back to `0.0.0` for unbundled (e.g. `swift run`) builds.
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    init() {
        self.token = HookServer.generateToken()
    }

    // MARK: - Lifecycle

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Bind loopback only; port .any picks an ephemeral port.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

            let listener = try NWListener(using: params)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let rawPort = self?.listener?.port?.rawValue {
                        self?.publishServerFile(port: rawPort)
                        // Mirror the live port to the main actor for the Setup panel's
                        // "Local server" health check. Hop exactly like `dispatch` does —
                        // this handler runs on the listener's own queue, and `AppState` is
                        // @MainActor. Kept SwiftUI-free: `AppState` imports only Foundation.
                        Task { @MainActor in AppState.shared.setServerPort(rawPort) }
                    }
                case .failed, .cancelled:
                    // The listener is gone, so the port no longer accepts hooks; clear it so
                    // the Setup panel flips to "not running" rather than a stale port.
                    Task { @MainActor in AppState.shared.setServerPort(nil) }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            listener.start(queue: queue)
        } catch {
            NSLog("AgentBar: failed to start HookServer: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        removeServerFile()
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var buffer = buffer
            if let data { buffer.append(data) }

            if error != nil {
                connection.cancel()
                return
            }

            switch self.parse(buffer) {
            case .tooLarge:
                self.respond(connection, status: 413, body: "payload too large")
            case .complete(let request):
                self.route(request, on: connection)
            case .incomplete:
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    // MARK: - Parsing

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private enum ParseResult {
        case incomplete
        case tooLarge
        case complete(HTTPRequest)
    }

    private func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            // Guard against an unbounded header section.
            return buffer.count > maxBodyBytes ? .tooLarge : .incomplete
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .incomplete
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .incomplete }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .incomplete }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Reject absurd lengths before doing index math: a negative value would
        // produce an inverted Data range below, which traps — and this parse runs
        // before the bearer-token check, so it must never crash on hostile input.
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength < 0 || contentLength > maxBodyBytes { return .tooLarge }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return .incomplete }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        guard authorized(request.headers["authorization"]) else {
            respond(connection, status: 401, body: "unauthorized")
            return
        }

        // Clues about the host terminal/IDE, for a precise "Focus". Resolution to an app
        // happens later in TerminalFocus; here we just carry the raw env signals.
        func header(_ name: String) -> String? {
            request.headers[name].flatMap { $0.isEmpty ? nil : $0 }
        }
        let hint = TerminalHint(
            termProgram: header("x-agentbar-term"),
            termEmulator: header("x-agentbar-termemu"),
            cfBundleID: header("x-agentbar-host")
        )
        // Which agent sent this event. The Claude plugin omits the header (→ .claude); the
        // Copilot hook bridge sends "copilot".
        let source = AgentSource(header: header("x-agentbar-agent"))

        switch (request.method, request.path) {
        case ("GET", "/v1/health"):
            // Report pid + version so a hook (or `agentbar-hook --selftest`) can confirm it
            // is talking to a live, current instance rather than a stale server.json.
            let pid = ProcessInfo.processInfo.processIdentifier
            let body = "{\"ok\":true,\"pid\":\(pid),\"version\":\"\(Self.appVersion)\"}"
            respond(connection, status: 200, body: body, contentType: "application/json")
        case ("POST", "/v1/ask"):
            dispatch(.ask, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/permission"):
            dispatch(.permission, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/elicit"):
            dispatch(.elicit, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/working"):
            dispatch(.working, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/resolved"):
            dispatch(.resolved, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/denied"):
            dispatch(.denied, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/notify"):
            dispatch(.notify, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/stop"):
            dispatch(.stop, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/subagent"):
            dispatch(.subagentStop, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/sessionend"):
            dispatch(.sessionEnd, body: request.body, hint: hint, source: source, connection: connection)
        case ("POST", "/v1/stopfailure"):
            dispatch(.stopFailure, body: request.body, hint: hint, source: source, connection: connection)
        default:
            respond(connection, status: 404, body: "not found")
        }
    }

    /// Timing-safe bearer check: any local process can reach the loopback port, and a
    /// plain `==` leaks how many leading token bytes matched. Comparing SHA-256 digests
    /// makes the comparison's timing independent of the attacker-controlled value.
    private func authorized(_ authorizationHeader: String?) -> Bool {
        guard let provided = authorizationHeader else { return false }
        let expected = SHA256.hash(data: Data("Bearer \(token)".utf8))
        let actual = SHA256.hash(data: Data(provided.utf8))
        return expected == actual
    }

    private func dispatch(_ event: HookEvent, body: Data, hint: TerminalHint, source: AgentSource, connection: NWConnection) {
        // Acknowledge immediately so the session never blocks, then enqueue the
        // notification on the main actor. AgentBar is notify-only: there is no response
        // to carry back, so the hook always sees an empty body (204) = terminal passthrough.
        respond(connection, status: 204, body: "")
        let terminal = hint.isEmpty ? nil : hint
        Task { @MainActor in
            AppState.shared.queue.submit(event: event, payload: body, terminal: terminal, source: source)
        }
    }

    // MARK: - Response

    private func respond(_ connection: NWConnection,
                         status: Int,
                         body: String,
                         contentType: String = "text/plain; charset=utf-8") {
        let bodyData = Data(body.utf8)
        var header = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        if status != 204 {
            header += "Content-Type: \(contentType)\r\n"
        }
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"

        var out = Data(header.utf8)
        out.append(bodyData)

        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        default: return "OK"
        }
    }

    // MARK: - server.json

    private var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentBar", isDirectory: true)
    }

    private var serverFile: URL {
        stateDirectory.appendingPathComponent("server.json")
    }

    private func publishServerFile(port: UInt16) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The bash hook parses `port` (unquoted) and `token` (quoted) with sed; the extra
        // `pid`/`version` keys are ignored by it but let a stale file be told apart from a
        // live instance during `--selftest`.
        let pid = ProcessInfo.processInfo.processIdentifier
        let json = "{\"port\":\(port),\"pid\":\(pid),\"version\":\"\(Self.appVersion)\",\"token\":\"\(token)\"}"
        fm.createFile(
            atPath: serverFile.path,
            contents: Data(json.utf8),
            attributes: [.posixPermissions: 0o600]
        )
    }

    private func removeServerFile() {
        try? FileManager.default.removeItem(at: serverFile)
    }

    // MARK: - Token

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

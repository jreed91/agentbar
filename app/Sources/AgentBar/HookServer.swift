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
        // Which agent sent this event. The Claude Code mod sends "claude" (a pre-1.0 plugin
        // omits the header, also → .claude); the Copilot hook bridge sends "copilot".
        let source = AgentSource(header: header("x-agentbar-agent"))
        // The Claude Code mod's extras; all nil from the bash bridge.
        let extras = BridgeExtras.fromHeaders(
            bridge: header("x-agentbar-bridge"),
            model: header("x-agentbar-model"),
            contextTokens: header("x-agentbar-context-tokens"),
            contextWindow: header("x-agentbar-context-window"),
            answerID: header("x-agentbar-answer-id")
        )

        // The mod waiting on an answer from the menu bar: long-poll for it, or withdraw it.
        if request.path.hasPrefix("/v1/answer/") {
            routeAnswer(request, on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/health"):
            // Report pid + version so a hook (or `agentbar-hook --selftest`) can confirm it
            // is talking to a live, current instance rather than a stale server.json.
            let pid = ProcessInfo.processInfo.processIdentifier
            let body = "{\"ok\":true,\"pid\":\(pid),\"version\":\"\(Self.appVersion)\"}"
            respond(connection, status: 200, body: body, contentType: "application/json")
        case ("GET", "/v1/attention"):
            // Read by the Claude Code mod's in-terminal band: who else is waiting on you.
            Task { @MainActor in
                let body = AppState.shared.attentionJSON()
                self.queue.async {
                    self.respond(connection, status: 200, body: String(decoding: body, as: UTF8.self),
                                 contentType: "application/json")
                }
            }
        case ("POST", "/v1/focus"):
            // The band's "jump": bring that session's terminal forward. No body (or no
            // `session_id`) jumps to the longest-waiting prompt, as the global hotkey does.
            let object = try? JSONSerialization.jsonObject(with: request.body)
            let sessionID = (object as? [String: Any])?["session_id"] as? String
            Task { @MainActor in
                let focused = AppState.shared.focusAttention(sessionID: sessionID)
                self.queue.async {
                    self.respond(connection, status: focused ? 204 : 404, body: focused ? "" : "not found")
                }
            }
        case ("POST", "/v1/ask"):
            dispatch(.ask, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/permission"):
            dispatch(.permission, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/elicit"):
            dispatch(.elicit, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/working"):
            dispatch(.working, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/resolved"):
            dispatch(.resolved, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/denied"):
            dispatch(.denied, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/notify"):
            dispatch(.notify, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/stop"):
            dispatch(.stop, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/subagent"):
            dispatch(.subagentStop, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/sessionend"):
            dispatch(.sessionEnd, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
        case ("POST", "/v1/stopfailure"):
            dispatch(.stopFailure, body: request.body, hint: hint, source: source, extras: extras, connection: connection)
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

    private func dispatch(_ event: HookEvent, body: Data, hint: TerminalHint, source: AgentSource,
                          extras: BridgeExtras, connection: NWConnection) {
        let terminal = hint.isEmpty ? nil : hint
        // A prompt the mod offers to have answered from the menu bar: reply once it is queued,
        // saying whether an answer may come (answering is on), so the mod knows to poll.
        if extras.answerID != nil {
            Task { @MainActor in
                let answerable = AppState.shared.queue.submit(
                    event: event, payload: body, terminal: terminal, source: source, extras: extras)
                self.queue.async {
                    self.respond(connection, status: 200, body: "{\"answerable\":\(answerable)}",
                                 contentType: "application/json")
                }
            }
            return
        }
        // Everything else is acknowledged immediately so the session never blocks, then
        // enqueued on the main actor. The empty body (204) means terminal passthrough.
        respond(connection, status: 204, body: "")
        Task { @MainActor in
            AppState.shared.queue.submit(event: event, payload: body, terminal: terminal, source: source, extras: extras)
        }
    }

    /// The longest a single answer poll is held open.
    private let maxAnswerWait: TimeInterval = 10

    /// `GET /v1/answer/<id>?wait=<ms>`: 200 with the answer, 204 when none came within the
    /// wait, 410 once the prompt can no longer be answered from the menu bar (answered in the
    /// terminal, dismissed, superseded, or answering is off). `DELETE` withdraws the offer.
    private func routeAnswer(_ request: HTTPRequest, on connection: NWConnection) {
        let target = request.path.dropFirst("/v1/answer/".count)
        let parts = target.split(separator: "?", maxSplits: 1)
        let answerID = parts.first.map(String.init)?.lowercased() ?? ""
        guard BridgeExtras.isAnswerID(answerID) else {
            respond(connection, status: 404, body: "not found")
            return
        }

        switch request.method {
        case "DELETE":
            respond(connection, status: 204, body: "")
            Task { @MainActor in AppState.shared.queue.withdrawAnswer(answerID) }
        case "GET":
            var waitMs = 0.0
            if parts.count > 1 {
                for pair in parts[1].split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2, kv[0] == "wait", let value = Double(kv[1]) { waitMs = value }
                }
            }
            let wait = min(max(waitMs / 1000, 0), maxAnswerWait)
            let deadline = Date().addingTimeInterval(wait)
            Task { @MainActor in
                while true {
                    let state = AppState.shared.queue.answerState(for: answerID)
                    let done: (Int, String)?
                    switch state {
                    case .answered(let json): done = (200, String(decoding: json, as: UTF8.self))
                    case .gone: done = (410, "gone")
                    case .pending: done = Date() >= deadline ? (204, "") : nil
                    }
                    if case let (status, body)? = done {
                        self.queue.async {
                            self.respond(connection, status: status, body: body,
                                         contentType: status == 200 ? "application/json" : "text/plain; charset=utf-8")
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        default:
            respond(connection, status: 404, body: "not found")
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
        case 410: return "Gone"
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

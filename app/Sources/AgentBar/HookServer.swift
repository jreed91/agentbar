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
                    }
                case .failed, .cancelled:
                    break
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

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength > maxBodyBytes { return .tooLarge }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return .incomplete }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            respond(connection, status: 401, body: "unauthorized")
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/health"):
            respond(connection, status: 200, body: "ok")
        case ("POST", "/v1/ask"):
            dispatch(.ask, body: request.body, connection: connection)
        case ("POST", "/v1/permission"):
            dispatch(.permission, body: request.body, connection: connection)
        case ("POST", "/v1/elicit"):
            dispatch(.elicit, body: request.body, connection: connection)
        case ("POST", "/v1/notify"):
            dispatch(.notify, body: request.body, connection: connection)
        case ("POST", "/v1/stop"):
            dispatch(.stop, body: request.body, connection: connection)
        case ("POST", "/v1/subagent"):
            dispatch(.subagentStop, body: request.body, connection: connection)
        case ("POST", "/v1/sessionend"):
            dispatch(.sessionEnd, body: request.body, connection: connection)
        case ("POST", "/v1/stopfailure"):
            dispatch(.stopFailure, body: request.body, connection: connection)
        default:
            respond(connection, status: 404, body: "not found")
        }
    }

    private func dispatch(_ event: HookEvent, body: Data, connection: NWConnection) {
        // Acknowledge immediately so the session never blocks, then enqueue the
        // notification on the main actor. AgentBar is notify-only: there is no response
        // to carry back, so the hook always sees an empty body (204) = terminal passthrough.
        respond(connection, status: 204, body: "")
        Task { @MainActor in
            AppState.shared.queue.submit(event: event, payload: body)
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
        // Exact shape the bash hook parses with sed: unquoted port, quoted token.
        let json = "{\"port\":\(port),\"token\":\"\(token)\"}"
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

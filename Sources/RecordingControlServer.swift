import Foundation
import Network

/// Tiny loopback HTTP server (127.0.0.1:8393) that provides a local emergency
/// stop/status control. It cannot start recording.
/// Endpoints:
///   POST /stop   -> stop recording
///   GET  /status -> { "recording": bool }
final class RecordingControlServer: @unchecked Sendable {
    private let listener: NWListener
    private let handler: @Sendable (String) -> Void
    private var recording = false

    init(port: UInt16 = 8393, handler: @escaping @Sendable (String) -> Void) throws {
        self.handler = handler
        // Bind to loopback only — never exposed off this Mac.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!
        )
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)
    }

    func start() {
        listener.stateUpdateHandler = { _ in }
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            self?.receive(conn)
        }
        listener.start(queue: .global())
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data else {
                conn.cancel()
                return
            }
            let req = String(data: data, encoding: .utf8) ?? ""
            self.route(req, on: conn)
        }
    }

    private func route(_ req: String, on conn: NWConnection) {
        guard Self.isLocalTool(req) else {
            send(conn, status: 403, body: "{\"error\":\"forbidden\"}")
            return
        }
        let body: String
        if req.hasPrefix("POST /stop") {
            handler("stop")
            recording = false
            body = "{\"recording\":false}"
        } else if req.hasPrefix("GET /status") {
            body = "{\"recording\":\(recording ? "true" : "false")}"
        } else {
            send(conn, status: 404, body: "{\"error\":\"not found\"}")
            return
        }
        send(conn, status: 200, body: body)
    }

    /// Only command-line tools on this Mac may use the server. Browsers add an
    /// Origin header to cross-site requests, so any web page could otherwise
    /// stop a recording; a Host other than loopback means DNS rebinding.
    static func isLocalTool(_ request: String) -> Bool {
        var host: String?
        for line in request.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "origin" { return false }
            if name == "host" { host = value.lowercased() }
        }
        guard let host else { return true }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name == "127.0.0.1" || name == "localhost"
    }

    private func send(_ conn: NWConnection, status: Int, body: String) {
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

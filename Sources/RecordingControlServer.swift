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

    private func send(_ conn: NWConnection, status: Int, body: String) {
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

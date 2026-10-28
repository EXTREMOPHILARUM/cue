import Foundation
import Network
import CallCore

// All connection state and request handling live on the main queue; inference runs in its own actor.
@MainActor final class BridgeServer {
    private let listener: NWListener
    private var peers: [UUID: NWConnection] = [:]
    private var roles: [UUID: String] = [:]
    var handle: ((String, [String: Any]) async throws -> [String: Any])?
    var disconnected: ((UUID) -> Void)?
    var state: ((String) -> Void)?
    var extensionConnectionChanged: ((Bool) -> Void)?
    init(port: UInt16 = 17373, extensionID: @escaping @MainActor () -> String) throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 4 * 1024 * 1024
        options.setClientRequestHandler(.main) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            return .init(status: Validation.originAllowed(origin, extensionID: MainActor.assumeIsolated { extensionID() }) ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at:0)
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!)
        listener = try NWListener(using:parameters)
        listener.newConnectionHandler = { [weak self] connection in MainActor.assumeIsolated { self?.accept(connection) } }
        listener.stateUpdateHandler = { [weak self] value in
            MainActor.assumeIsolated {
            switch value {
            case .ready: self?.state?("Listening on 127.0.0.1:\(port)")
            case .failed(let error): self?.state?("Bridge failed: \(error.localizedDescription)")
            default: break
            }
            }
        }
    }
    func start() { listener.start(queue:.main) }
    func disconnectExtensions() {
        // Pending handshakes may have passed the previous extension-origin check.
        for id in peers.keys.filter({ roles[$0] != "assistant" }) { remove(id) }
    }
    func broadcast(_ event: String, role: String) { for (id, peerRole) in roles where peerRole == role { send(id,["event":event]) } }
    func stop() { listener.cancel(); for id in Array(peers.keys) { remove(id) } }
    private func accept(_ connection: NWConnection) {
        guard peers.count < 12 else { connection.cancel(); return }
        let id = UUID()
        peers[id] = connection
        connection.stateUpdateHandler = { [weak self] value in
            MainActor.assumeIsolated {
            if case .failed = value { self?.remove(id) }
            if case .cancelled = value { self?.remove(id) }
            }
        }
        connection.start(queue:.main)
        receive(id)
        DispatchQueue.main.asyncAfter(deadline:.now()+5) { [weak self] in
            if self?.roles[id] == nil { self?.remove(id) }
        }
    }
    private func remove(_ id: UUID) {
        let connection = peers.removeValue(forKey:id)
        let role = roles.removeValue(forKey:id)
        if role == "extension" { extensionConnectionChanged?(roles.values.contains("extension")) }
        connection?.cancel()
        if connection != nil { disconnected?(id) }
    }
    private func receive(_ id: UUID) {
        guard let connection = peers[id] else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            MainActor.assumeIsolated {
            guard error == nil else { self.remove(id); return }
            let opcode = context?.protocolMetadata(definition:NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if opcode?.opcode == .close { self.remove(id); return }
            guard let data, opcode?.opcode == .text else { self.remove(id); return }
            Task { @MainActor in
                guard self.peers[id] != nil else { return }
                var requestID = ""
                do {
                    guard let request = try JSONSerialization.jsonObject(with:data) as? [String: Any] else { throw BridgeError("Invalid request") }
                    requestID = try Validation.text(request["id"],limit:100)
                    if self.roles[id] == nil {
                        guard request["method"] as? String == "hello", let role = request["role"] as? String, ["extension","assistant"].contains(role) else { throw BridgeError("Invalid client role") }
                        self.roles[id] = role
                        if role == "extension" { self.extensionConnectionChanged?(true) }
                        self.send(id,["id":requestID,"ok":true,"result":["protocol":1]])
                    } else {
                        guard request["method"] as? String != "hello", let handle = self.handle else { throw BridgeError("Invalid method") }
                        var payload = request
                        payload["peer"] = id.uuidString
                        let result = try await handle(self.roles[id]!,payload)
                        self.send(id,["id":requestID,"ok":true,"result":result])
                    }
                } catch {
                    self.send(id,["id":requestID,"ok":false,"error":error.localizedDescription])
                    if self.roles[id] == nil { DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { self.remove(id) }; return }
                }
                self.receive(id)
            }
            }
        }
    }
    private func send(_ id: UUID, _ object: [String: Any]) {
        guard let connection = peers[id], let data = try? JSONSerialization.data(withJSONObject:object) else { return }
        let context = NWConnection.ContentContext(identifier:"json",metadata:[NWProtocolWebSocket.Metadata(opcode:.text)])
        connection.send(content:data,contentContext:context,isComplete:true,completion:.contentProcessed { [weak self] error in MainActor.assumeIsolated { if error != nil { self?.remove(id) } } })
    }
}

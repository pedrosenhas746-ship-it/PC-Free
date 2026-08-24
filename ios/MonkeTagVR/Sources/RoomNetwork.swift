import Foundation

struct PlayerState: Codable {
    let type: String
    let id: String
    let name: String
    let px: Float; let py: Float; let pz: Float
    let hx: Float; let hy: Float; let hz: Float; let hw: Float
    let lx: Float; let ly: Float; let lz: Float
    let rx: Float; let ry: Float; let rz: Float
    let hue: Float
    let t: TimeInterval
}

final class RoomNetwork {
    let playerID = UUID().uuidString
    var playerName = "MONKE"
    var hue: Float = Float.random(in: 0...1)
    var onState: ((PlayerState) -> Void)?
    var onStatus: ((String) -> Void)?
    var onCount: ((Int) -> Void)?

    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    static func makeRoomCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in chars.randomElement()! })
    }

    func connect(roomCode: String) {
        disconnect()
        let room = roomCode.uppercased().filter { $0.isLetter || $0.isNumber }
        let alias = playerName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "MONKE"
        let channel = "monketag-vrbox-\(room.lowercased())"
        guard let url = URL(string: "wss://itty.ws/c/\(channel)?as=\(alias)&announce=true&list=true&echo=false") else { return }
        let task = URLSession(configuration: .default).webSocketTask(with: url)
        socket = task
        task.resume()
        onStatus?("CONECTANDO…")
        receiveLoop()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.socket?.sendPing { _ in } }
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }

    func send(_ state: PlayerState) {
        guard let socket,
              let data = try? JSONEncoder().encode(state),
              let string = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(string)) { _ in }
    }

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async { self.onStatus?("DESCONECTADO") }
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text { self.parse(text) }
                self.receiveLoop()
            }
        }
    }

    private func parse(_ text: String) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let type = root["type"] as? String, type == "join" {
            let total = root["total"] as? Int ?? 1
            DispatchQueue.main.async { self.onStatus?("ONLINE"); self.onCount?(total) }
            return
        }
        if let type = root["type"] as? String, type == "leave" {
            let total = root["total"] as? Int ?? 1
            DispatchQueue.main.async { self.onCount?(total) }
            return
        }
        let payload: Any = root["message"] ?? root
        var stateData: Data?
        if let dict = payload as? [String: Any] { stateData = try? JSONSerialization.data(withJSONObject: dict) }
        else if let str = payload as? String { stateData = str.data(using: .utf8) }
        guard let stateData,
              let state = try? JSONDecoder().decode(PlayerState.self, from: stateData),
              state.id != playerID else { return }
        DispatchQueue.main.async { self.onState?(state) }
    }
}

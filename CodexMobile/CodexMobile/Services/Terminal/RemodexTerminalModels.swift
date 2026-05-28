// FILE: RemodexTerminalModels.swift
// Purpose: Defines the native SSH terminal profile and runtime snapshot models.
// Layer: Service Model
// Exports: RemodexTerminalProfile, RemodexTerminalSnapshot, RemodexTerminalStatus
// Depends on: Foundation, JSONValue

import Foundation

private let remodexTerminalMaxBufferCharacters = 200_000
private let remodexTerminalMaxBufferBytes = 200_000
private let remodexDefaultTerminalId = "term-1"

enum RemodexTerminalStatus: String, Codable, Equatable, Sendable {
    case idle
    case starting
    case running
    case exited
    case closed
    case error

    var isRunning: Bool {
        self == .starting || self == .running
    }

    var displayTitle: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting:
            return "Connecting"
        case .running:
            return "Running"
        case .exited:
            return "Exited"
        case .closed:
            return "Closed"
        case .error:
            return "Error"
        }
    }
}

struct RemodexTerminalProfile: Codable, Equatable, Sendable {
    var host: String
    var username: String
    var port: Int
    var cwd: String
    var nickname: String

    enum CodingKeys: String, CodingKey {
        case host
        case username
        case port
        case cwd
        case nickname
    }

    init(host: String, username: String, port: Int, cwd: String, nickname: String = "") {
        self.host = host
        self.username = username
        self.port = port
        self.cwd = cwd
        self.nickname = nickname
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
    }

    static var empty: RemodexTerminalProfile {
        RemodexTerminalProfile(
            host: "",
            username: "",
            port: 22,
            cwd: "",
            nickname: ""
        )
    }

    var connectionString: String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let portSuffix = port == 22 ? "" : ":\(port)"
        guard !trimmedUser.isEmpty else {
            return "\(trimmedHost)\(portSuffix)"
        }
        return "\(trimmedUser)@\(trimmedHost)\(portSuffix)"
    }

    var displayTarget: String {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNickname.isEmpty {
            return trimmedNickname
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else {
            return trimmedHost.isEmpty ? "SSH host" : trimmedHost
        }
        return "\(trimmedUser)@\(trimmedHost)"
    }

    var normalizedForSave: RemodexTerminalProfile {
        RemodexTerminalProfile(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            port: max(1, min(65535, port)),
            cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    mutating func applyConnectionString(_ value: String) {
        var rawValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawValue.hasPrefix("ssh ") {
            rawValue.removeFirst(4)
            rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !rawValue.isEmpty else { return }

        let userAndHost = rawValue.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        if userAndHost.count == 2 {
            username = String(userAndHost[0])
            applyHostAndPort(String(userAndHost[1]))
        } else {
            applyHostAndPort(rawValue)
        }
    }

    private mutating func applyHostAndPort(_ value: String) {
        let hostAndPort = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        host = String(hostAndPort.first ?? "")
        if hostAndPort.count == 2, let parsedPort = Int(hostAndPort[1]) {
            port = max(1, min(65535, parsedPort))
        }
    }
}

struct RemodexTerminalSnapshot: Equatable, Sendable {
    var terminalId: String
    var instanceId: String?
    var status: RemodexTerminalStatus
    var buffer: String
    var bufferData: Data
    var cwd: String
    var cols: Int
    var rows: Int
    var errorMessage: String?
    var resizeSupported: Bool
    var bracketedPasteEnabled: Bool

    static let idle = RemodexTerminalSnapshot(
        terminalId: remodexDefaultTerminalId,
        instanceId: nil,
        status: .idle,
        buffer: "",
        bufferData: Data(),
        cwd: "",
        cols: 80,
        rows: 24,
        errorMessage: nil,
        resizeSupported: false,
        bracketedPasteEnabled: false
    )

    static func idleSnapshot(terminalId: String) -> RemodexTerminalSnapshot {
        var snapshot = idle
        snapshot.terminalId = terminalId
        return snapshot
    }

    init(
        terminalId: String,
        instanceId: String?,
        status: RemodexTerminalStatus,
        buffer: String,
        bufferData: Data,
        cwd: String,
        cols: Int,
        rows: Int,
        errorMessage: String?,
        resizeSupported: Bool,
        bracketedPasteEnabled: Bool = false
    ) {
        self.terminalId = terminalId
        self.instanceId = instanceId
        self.status = status
        self.buffer = buffer
        self.bufferData = bufferData
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.errorMessage = errorMessage
        self.resizeSupported = resizeSupported
        self.bracketedPasteEnabled = bracketedPasteEnabled
    }

    init(resultObject: [String: JSONValue]) {
        let rawStatus = resultObject["status"]?.stringValue ?? RemodexTerminalStatus.idle.rawValue
        let historyText = resultObject["history"]?.stringValue ?? resultObject["buffer"]?.stringValue ?? ""
        let historyData = Self.dataFromBase64(resultObject["historyBase64"]?.stringValue ?? resultObject["history_base64"]?.stringValue)
            ?? Self.dataFromBase64(resultObject["dataBase64"]?.stringValue ?? resultObject["data_base64"]?.stringValue)
            ?? Data(historyText.utf8)
        let decodedHistoryText = historyText.isEmpty ? String(decoding: historyData, as: UTF8.self) : historyText
        self.init(
            terminalId: resultObject["terminalId"]?.stringValue ?? resultObject["terminal_id"]?.stringValue ?? remodexDefaultTerminalId,
            instanceId: Self.instanceId(in: resultObject),
            status: RemodexTerminalStatus(rawValue: rawStatus) ?? .idle,
            buffer: Self.trimmedBuffer(decodedHistoryText),
            bufferData: Self.trimmedBufferData(historyData),
            cwd: resultObject["cwd"]?.stringValue ?? "",
            cols: resultObject["cols"]?.intValue ?? 80,
            rows: resultObject["rows"]?.intValue ?? 24,
            errorMessage: resultObject["error"]?.stringValue,
            resizeSupported: resultObject["resizeSupported"]?.boolValue ?? false,
            bracketedPasteEnabled: Self.bracketedPasteMode(afterScanning: decodedHistoryText, current: false)
        )
    }

    mutating func applyTerminalEvent(_ paramsObject: [String: JSONValue]) {
        if let incomingInstanceId = Self.instanceId(in: paramsObject) {
            if let instanceId, instanceId != incomingInstanceId {
                return
            }
            instanceId = incomingInstanceId
        }
        if let terminalId = paramsObject["terminalId"]?.stringValue ?? paramsObject["terminal_id"]?.stringValue {
            self.terminalId = terminalId
        }
        if let rawStatus = paramsObject["status"]?.stringValue,
           let status = RemodexTerminalStatus(rawValue: rawStatus) {
            self.status = status
        }
        if let history = paramsObject["history"]?.stringValue {
            buffer = Self.trimmedBuffer(history)
            bufferData = Self.trimmedBufferData(Self.dataFromBase64(
                paramsObject["historyBase64"]?.stringValue ?? paramsObject["history_base64"]?.stringValue
            ) ?? Data(history.utf8))
            bracketedPasteEnabled = Self.bracketedPasteMode(afterScanning: history, current: false)
        } else if let historyBase64 = paramsObject["historyBase64"]?.stringValue ?? paramsObject["history_base64"]?.stringValue,
                  let historyData = Self.dataFromBase64(historyBase64) {
            let historyText = String(decoding: historyData, as: UTF8.self)
            bufferData = Self.trimmedBufferData(historyData)
            buffer = Self.trimmedBuffer(historyText)
            bracketedPasteEnabled = Self.bracketedPasteMode(afterScanning: historyText, current: false)
        } else if let dataBase64 = paramsObject["dataBase64"]?.stringValue ?? paramsObject["data_base64"]?.stringValue,
                  let data = Self.dataFromBase64(dataBase64) {
            let text = paramsObject["data"]?.stringValue ?? String(decoding: data, as: UTF8.self)
            bracketedPasteEnabled = Self.bracketedPasteMode(afterScanning: String(buffer.suffix(16)) + text, current: bracketedPasteEnabled)
            bufferData = Self.appendingBufferData(bufferData, data)
            buffer = Self.trimmedBuffer(buffer + text)
        } else if let data = paramsObject["data"]?.stringValue {
            bracketedPasteEnabled = Self.bracketedPasteMode(afterScanning: String(buffer.suffix(16)) + data, current: bracketedPasteEnabled)
            buffer = Self.trimmedBuffer(buffer + data)
            bufferData = Self.appendingBufferData(bufferData, Data(data.utf8))
        }
        if let cwd = paramsObject["cwd"]?.stringValue {
            self.cwd = cwd
        }
        if let cols = paramsObject["cols"]?.intValue {
            self.cols = cols
        }
        if let rows = paramsObject["rows"]?.intValue {
            self.rows = rows
        }
        if let errorValue = paramsObject["error"] {
            errorMessage = errorValue.stringValue
        }
        if let resizeSupported = paramsObject["resizeSupported"]?.boolValue {
            self.resizeSupported = resizeSupported
        }
    }

    mutating func appendOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        // Output chunks can split the terminal's bracketed-paste mode toggles.
        // Scan with a short previous suffix so pasted multiline text is wrapped only
        // after the remote shell/editor explicitly enables that protocol.
        bracketedPasteEnabled = Self.bracketedPasteMode(afterScanning: String(buffer.suffix(16)) + text, current: bracketedPasteEnabled)
        bufferData = Self.appendingBufferData(bufferData, data)
        buffer = Self.trimmedBuffer(buffer + text)
    }

    static func bracketedPasteMode(afterScanning text: String, current: Bool) -> Bool {
        let marker = "\u{1B}[?2004"
        var state = current
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let markerRange = text[searchStart...].range(of: marker),
              markerRange.upperBound < text.endIndex {
            let final = text[markerRange.upperBound]
            if final == "h" {
                state = true
            } else if final == "l" {
                state = false
            }
            searchStart = text.index(after: markerRange.upperBound)
        }

        return state
    }

    static func instanceId(in object: [String: JSONValue]) -> String? {
        object["instanceId"]?.stringValue
            ?? object["instance_id"]?.stringValue
            ?? object["sessionId"]?.stringValue
            ?? object["session_id"]?.stringValue
    }

    private static func trimmedBuffer(_ value: String) -> String {
        guard value.count > remodexTerminalMaxBufferCharacters else {
            return value
        }
        return String(value.suffix(remodexTerminalMaxBufferCharacters))
    }

    private static func trimmedBufferData(_ value: Data) -> Data {
        guard value.count > remodexTerminalMaxBufferBytes else {
            return value
        }
        return Data(value.suffix(remodexTerminalMaxBufferBytes))
    }

    private static func dataFromBase64(_ value: String?) -> Data? {
        guard let value else {
            return nil
        }
        guard !value.isEmpty else {
            return Data()
        }
        return Data(base64Encoded: value)
    }

    private static func appendingBufferData(_ lhs: Data, _ rhs: Data) -> Data {
        var result = lhs
        result.append(rhs)
        return trimmedBufferData(result)
    }
}

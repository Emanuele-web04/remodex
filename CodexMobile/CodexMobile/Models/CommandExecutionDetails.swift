// FILE: CommandExecutionDetails.swift
// Purpose: Rich metadata for command execution tool calls, stored alongside CodexMessage.
// Layer: Model
// Exports: CommandExecutionDetails
// Depends on: Foundation

import Foundation

struct CommandExecutionDetails: Sendable {
    var fullCommand: String
    var cwd: String?
    var exitCode: Int?
    var durationMs: Int?
    var outputTail: String

    static let maxOutputLines = 30

    mutating func appendOutput(_ chunk: String) {
        outputTail += chunk
        trimOutputTail()
    }

    mutating func trimOutputTail() {
        let lines = outputTail.components(separatedBy: .newlines)
        if lines.count > Self.maxOutputLines {
            outputTail = lines.suffix(Self.maxOutputLines).joined(separator: "\n")
        }
    }
}

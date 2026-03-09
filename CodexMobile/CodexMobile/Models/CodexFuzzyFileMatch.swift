// FILE: CodexFuzzyFileMatch.swift
// Purpose: Represents one fuzzy file-search result returned by app-server.
// Layer: Model
// Exports: CodexFuzzyFileMatch
// Depends on: Foundation

import Foundation

struct CodexFuzzyFileMatch: Decodable, Hashable, Sendable, Identifiable {
    let root: String
    let path: String
    let fileName: String
    let score: Double
    let indices: [Int]?

    var id: String {
        "\(root)|\(path)"
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case path
        case fileName
        case fileNameSnake = "file_name"
        case score
        case indices
    }

    init(
        root: String,
        path: String,
        fileName: String,
        score: Double,
        indices: [Int]? = nil
    ) {
        self.root = root
        self.path = path
        self.fileName = fileName
        self.score = score
        self.indices = indices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(String.self, forKey: .root)
        path = try container.decode(String.self, forKey: .path)

        if let camelCaseName = try container.decodeIfPresent(String.self, forKey: .fileName) {
            fileName = camelCaseName
        } else if let snakeCaseName = try container.decodeIfPresent(String.self, forKey: .fileNameSnake) {
            fileName = snakeCaseName
        } else {
            fileName = (path as NSString).lastPathComponent
        }

        if let decodedScore = try? container.decode(Double.self, forKey: .score) {
            score = decodedScore
        } else {
            let intScore = try container.decode(Int.self, forKey: .score)
            score = Double(intScore)
        }

        indices = try container.decodeIfPresent([Int].self, forKey: .indices)
    }
}

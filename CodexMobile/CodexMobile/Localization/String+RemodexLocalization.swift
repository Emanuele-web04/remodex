import Foundation

extension String {
    var remodexLocalized: String {
        remodexLocalized(in: .main)
    }

    func remodexLocalized(in bundle: Bundle) -> String {
        NSLocalizedString(self, tableName: nil, bundle: bundle, value: self, comment: "")
    }

    // Localizes runtime-composed workflow labels while preserving the dynamic
    // command, model, path, agent name, or count carried by the message.
    func remodexLocalizedWorkflowText(in bundle: Bundle = .main) -> String {
        let exact = remodexLocalized(in: bundle)
        if exact != self { return exact }

        let integerPatterns: [(String, String)] = [
            (#"^Spawning (\d+) agents?$"#, "Spawning %d agents"),
            (#"^Waiting on (\d+) agents?$"#, "Waiting on %d agents"),
            (#"^Closing (\d+) agents?$"#, "Closing %d agents"),
            (#"^Resuming (\d+) agents?$"#, "Resuming %d agents"),
            (#"^Agent activity \((\d+)\)$"#, "Agent activity (%d)"),
            (#"^\+(\d+) tool calls?$"#, "+%d tool calls"),
            (#"^Select up to (\d+)$"#, "Select up to %d"),
            (#"^Output \(last (\d+) lines\)$"#, "Output (last %d lines)"),
        ]
        for (pattern, formatKey) in integerPatterns {
            if let captures = remodexRegexCaptures(pattern),
               let value = captures.first.flatMap(Int.init) {
                return String(format: formatKey.remodexLocalized(in: bundle), value)
            }
        }

        if let captures = remodexRegexCaptures(#"^(\d+) of (\d+)$"#),
           captures.count == 2,
           let current = Int(captures[0]),
           let total = Int(captures[1]) {
            return String(format: "%d of %d".remodexLocalized(in: bundle), current, total)
        }

        let prefixedFormats: [(String, String)] = [
            ("Latest update: ", "Latest update: %@"),
            ("requested: ", "requested: %@"),
            ("Command: ", "Command: %@"),
            ("Agent ", "Agent %@"),
        ]
        for (prefix, formatKey) in prefixedFormats where hasPrefix(prefix) {
            let value = String(dropFirst(prefix.count))
            return String(format: formatKey.remodexLocalized(in: bundle), value)
        }

        return self
    }

    // Localizes the UI-owned verb at the start of tool/workflow status lines
    // while preserving command names, paths, branch names, and other payload text.
    var remodexLocalizedActivity: String {
        let workflow = remodexLocalizedWorkflowText()
        if workflow != self { return workflow }

        let exact = remodexLocalized
        if exact != self { return exact }

        let prefixes: [(String, String)] = [
            ("Completed ", "Completed %@"),
            ("Starting ", "Starting %@"),
            ("Started ", "Started %@"),
            ("Applying ", "Applying %@"),
            ("Applied ", "Applied %@"),
            ("Queued ", "Queued %@"),
            ("Failed ", "Failed %@"),
            ("Stopped ", "Stopped %@"),
            ("Searched for ", "Searched for %@"),
            ("Running ", "Running %@"),
            ("Ran ", "Ran %@"),
            ("Reading ", "Reading %@"),
            ("Read ", "Read %@"),
            ("Searching ", "Searching %@"),
            ("Searched ", "Searched %@"),
            ("Listing ", "Listing %@"),
            ("Listed ", "Listed %@"),
            ("Finding ", "Finding %@"),
            ("Found ", "Found %@"),
            ("Creating ", "Creating %@"),
            ("Created ", "Created %@"),
            ("Removing ", "Removing %@"),
            ("Removed ", "Removed %@"),
            ("Copying ", "Copying %@"),
            ("Copied ", "Copied %@"),
            ("Moving ", "Moving %@"),
            ("Moved ", "Moved %@"),
            ("Checking ", "Checking %@"),
            ("Checked ", "Checked %@"),
            ("Comparing ", "Comparing %@"),
            ("Compared ", "Compared %@"),
            ("Viewing ", "Viewing %@"),
            ("Viewed ", "Viewed %@"),
            ("Staging ", "Staging %@"),
            ("Staged ", "Staged %@"),
            ("Committing ", "Committing %@"),
            ("Committed ", "Committed %@"),
            ("Pushing ", "Pushing %@"),
            ("Pushed ", "Pushed %@"),
            ("Pulling ", "Pulling %@"),
            ("Pulled ", "Pulled %@"),
            ("Planning ", "Planning %@"),
            ("Preserving ", "Preserving %@"),
            ("Diagnosing ", "Diagnosing %@"),
        ]

        for (prefix, formatKey) in prefixes where hasPrefix(prefix) {
            return String(
                format: formatKey.remodexLocalized,
                String(dropFirst(prefix.count))
            )
        }
        return self
    }

    private func remodexRegexCaptures(_ pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = expression.firstMatch(in: self, range: range),
              match.range == range else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: self).map { String(self[$0]) }
        }
    }
}

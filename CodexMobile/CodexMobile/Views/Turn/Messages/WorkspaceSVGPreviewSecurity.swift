// FILE: WorkspaceSVGPreviewSecurity.swift
// Purpose: Centralizes SVG preview hardening so WebKit renders local vector artwork without external fetches.
// Layer: Turn UI preview security helper
// Exports: WorkspaceSVGPreviewSecurity
// Depends on: Foundation

import Foundation

enum WorkspaceSVGPreviewSecurity {
    static let contentSecurityPolicy = "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; media-src 'none'; font-src 'none'; base-uri 'none'"

    // Removes obvious external references before WebKit sees the SVG markup.
    static func sanitizedSVGSource(_ source: String) -> String {
        let pattern = #"\s(?:href|xlink:href|src)\s*=\s*(?:(["'])(?:https?:|//|file:)[^"']*\1|(?:https?:|//|file:)[^\s>/]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: "")
    }

    static func isExternalNavigationURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }
}

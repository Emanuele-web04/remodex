// FILE: TurnFileAutocompleteTokenTests.swift
// Purpose: Verifies trailing `@` token parsing and replacement in composer input.
// Layer: Unit Test
// Exports: TurnFileAutocompleteTokenTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnFileAutocompleteTokenTests: XCTestCase {
    func testTrailingTokenParsesOnlyWhenItIsFinalToken() {
        let token = TurnViewModel.trailingFileAutocompleteToken(in: "fix @turnv")
        XCTAssertEqual(token?.query, "turnv")
    }

    func testTrailingTokenAllowsFilePathsWithSpacesWhenTheyLookLikeAPath() {
        let token = TurnViewModel.trailingFileAutocompleteToken(
            in: "update @Codex Mobile App Plan/Codex iOS Recap TLDR.md"
        )

        XCTAssertEqual(token?.query, "Codex Mobile App Plan/Codex iOS Recap TLDR.md")
    }

    func testTrailingTokenDoesNotParseEmailAddress() {
        XCTAssertNil(TurnViewModel.trailingFileAutocompleteToken(in: "email@test.com"))
    }

    func testTrailingTokenDoesNotParseWhenAtTokenIsNotFinal() {
        XCTAssertNil(TurnViewModel.trailingFileAutocompleteToken(in: "fix @turnv please"))
    }

    func testReplacingTrailingTokenUpdatesOnlyFinalAtToken() {
        let updated = TurnViewModel.replacingTrailingFileAutocompleteToken(
            in: "compare @first and @turnv",
            with: "Views/Turn/TurnView.swift"
        )

        XCTAssertEqual(updated, "compare @first and @Views/Turn/TurnView.swift ")
    }

    func testReplacingMentionAliasesNormalizesDifferentFilenameStyles() {
        let mention = TurnComposerMentionedFile(
            fileName: "Codex iOS Recap TLDR.md",
            path: "Codex Mobile App Plan/Codex iOS Recap TLDR.md"
        )
        let source = """
        review @codex-ios-recap-tldr.md
        compare @codex_ios_recap_tldr
        check @CodexIOSRecapTLDR.md
        inspect @codexiosrecaptldr
        """

        let replaced = TurnViewModel.replacingFileMentionAliases(in: source, with: mention)

        XCTAssertTrue(replaced.contains("@Codex Mobile App Plan/Codex iOS Recap TLDR.md"))
        XCTAssertFalse(replaced.contains("@codex-ios-recap-tldr.md"))
        XCTAssertFalse(replaced.contains("@codex_ios_recap_tldr"))
        XCTAssertFalse(replaced.contains("@CodexIOSRecapTLDR.md"))
        XCTAssertFalse(replaced.contains("@codexiosrecaptldr"))
    }

    func testReplacingMentionAliasesRequiresFolderContextWhenFileNameIsAmbiguous() {
        let mention = TurnComposerMentionedFile(
            fileName: "Notes.md",
            path: "Docs/Notes.md"
        )
        let source = "compare @Notes.md and @Docs/Notes.md"

        let replaced = TurnViewModel.replacingFileMentionAliases(
            in: source,
            with: mention,
            allowFileNameAliases: false
        )

        XCTAssertEqual(replaced, "compare @Notes.md and @Docs/Notes.md")
    }

    func testAmbiguousFileNameAliasKeysMarksDuplicateBasenames() {
        let mentions = [
            TurnComposerMentionedFile(fileName: "Notes.md", path: "Docs/Notes.md"),
            TurnComposerMentionedFile(fileName: "Notes.md", path: "Archive/Notes.md"),
            TurnComposerMentionedFile(fileName: "Plan.md", path: "Docs/Plan.md"),
        ]

        XCTAssertEqual(TurnViewModel.ambiguousFileNameAliasKeys(in: mentions), ["notes.md"])
    }
}

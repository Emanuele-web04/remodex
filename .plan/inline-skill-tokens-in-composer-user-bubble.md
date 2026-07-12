# Inline Skill Tokens in Composer & User Bubble

## Context

Today a selected skill shows up as a separate chip row above the composer text field, while the text field itself keeps the literal `$check-code` token. The sent user bubble repeats the same workaround (chip strip above the bubble + token stripped from prose). The goal is to render the skill mention *inside* the text — icon + "Check Code" styled inline, like a native mention — in both the composer and the user bubble.

Agreed behavior (from discussion):
- **Only explicit selection creates a token.** Tapping a skill in the `$`/`/` autocomplete panel inserts the inline token. Manually typed `$foo` stays literal plain text everywhere.
- The **canonical data model does not change**: `TurnViewModel.input` stays a plain `String` containing `$skill-name` (or `/skill-name`), and `composerMentionedSkills` stays the structured source for the wire payload. Only the *display* changes. The send pipeline (`makeTurnInputPayload`, legacy wire text, structured skill items) is untouched.
- Scope: **skills only**. File/plugin mentions and slash commands keep their current chips.
- Backspace deletes the whole token atomically and removes the skill mention (fixes today's latent desync where deleting `$name` text leaves a stale chip that still gets sent).
- Skill tint stays **indigo** (`TurnMentionChipStyle.skill`), icon `remodex.skill` (central-building-blocks asset), display name via `SkillDisplayNameFormatter.displayName(for:)`.

## Current architecture (verified)

- Composer input: `UIViewRepresentable`-wrapped `UITextView`, plain-string binding, flat typing attributes — `CodexMobile/CodexMobile/Views/Turn/Composer/TurnComposerInputTextView.swift`. Coordinator has deferred-binding sync (`pendingUIKitText`), marked-text guards, and height measurement keyed on `textView.text.hashValue`.
- Token insertion: `TurnViewModel.onSelectSkillAutocomplete` (line ~1232) writes `$name ` (or `/name `) via `replacingTrailingSkillAutocompleteToken` and appends to `composerMentionedSkills`. Only this tap path populates the mention list — which is exactly the "explicit selection only" rule.
- Chips: `TurnMentionChips.swift` (`TurnComposerMentionChipSections` renders the composer skill row; `UserMentionChipStrip` the bubble strip).
- Bubble: `UserMessageBubble.swift` — `UserBubbleMentionExtractor.renderModel` regex-matches `@`/`$` tokens (`TurnMessageRegexCache.userMentionToken`), replaces matched tokens with plain display labels, and shows all chips in a strip.
- Send-time display text: `CodexService+ThreadsTurns.swift` `displayTextForOutgoingTurn` (~line 2354) currently replaces `$name`/`/name` with the plain display name in the local bubble text.

## Implementation

### 1. New shared token logic — `CodexMobile/CodexMobile/Views/Turn/Composer/TurnComposerInlineSkillToken.swift`

A `nonisolated enum` with the attributed-string machinery (kept UIKit-only and unit-testable):

- `static let attributeKey = NSAttributedString.Key("remodex.inlineSkillToken")` — value is the **literal canonical token** (`"$check-code"` or `"/check-code"`), so canonicalization reproduces the exact trigger the user used.
- `displayAttributedString(canonicalText:mentionNames:font:textColor:tintColor:) -> NSAttributedString`
  - Builds one regex per call from escaped mention names: `(?<!\S)([$/])(name1|name2|…)(?=[\s,.;:!?)\]}>]|$)`, case-insensitive (mirror the boundary rules of `TurnViewModel.replaceBoundedToken`).
  - Matched tokens become an atomic run: `NSTextAttachment` (icon from `RemodexIcon.uiImage(systemName: "remodex.skill")`, tinted with `withTintColor(_:renderingMode: .alwaysOriginal)`, bounds vertically centered on `font.capHeight`) + non-breaking space + display name. Whole run carries `attributeKey`, `.font`, `.foregroundColor: tintColor` (indigo).
  - Unmatched text keeps base font/`.label` color. Tokens without a matching mention (manually typed `$foo`) are left as plain text.
- `canonicalText(from: NSAttributedString) -> String` — enumerate `attributeKey` runs: token runs emit their literal value; plain runs emit their characters (strip stray U+FFFC).
- `expandedEditingRange(for range: NSRange, in: NSAttributedString) -> NSRange` — expand an edit range to fully cover any intersecting token run (atomic delete/replace).
- `snappedSelection(_ range: NSRange, in: NSAttributedString) -> NSRange` — caret inside a token snaps to nearest boundary; ranged selections expand outward to token boundaries.
- `normalized(_ storage: NSTextAttributedString)`-style safety helper: any token run whose string no longer equals its expected display string gets the token attribute stripped from the mismatched suffix (defends against attribute inheritance from autocorrect/marked text).

### 2. Composer text view — `TurnComposerInputTextView.swift`

Binding stays `String`. Add `let mentionedSkillNames: [String]` to the representable (passed from `TurnComposerView` via `accessoryState.composerMentionedSkills.map(\.name)`).

- `updateUIView`: replace the `uiView.text != text` / `uiView.text = text` sync with canonical-domain sync: compute `canonical = TurnComposerInlineSkillToken.canonicalText(from: uiView.attributedText)`; when `shouldApplyBindingText` and `canonical != text` (or the mention-names fingerprint changed and the rebuilt attributed string differs), assign `uiView.attributedText = displayAttributedString(...)` and reset typing attributes. Caret-to-end on rebuild is correct for all current external writes (skill select, send-clear, draft restore).
- `Coordinator.textViewDidChange`: run the normalization safety helper, then compute `newText = canonicalText(...)` and feed the existing deferred-binding logic with it (the `pendingUIKitText` mechanism keeps working — it just carries canonical strings now).
- `shouldApplyBindingText` / `shouldApplyBindingTextDuringPendingEdit`: comparisons against `textView.text` switch to the canonical text.
- New `textView(_:shouldChangeTextIn:replacementText:)`: sanitize replacement (strip U+FFFC); if the range must expand over token runs or the text was sanitized, perform the replacement manually on `textView.textStorage` with base typing attributes, set the caret after it, call `textViewDidChange`, return `false`. Otherwise return `true`.
- New `textViewDidChangeSelection`: snap selection via `snappedSelection`, and always reset `typingAttributes` to base font + `.label` (and remove `attributeKey`) so typing after a token never inherits indigo/token attributes.
- Height measurement (`heightMeasurementSignature`) keeps using display `textView.text` — unchanged.
- Marked-text guard paths are untouched; rebuilds are already deferred during composition.

### 3. Mention pruning — `TurnViewModel.swift`

- At the top of `onInputChangedForSkillAutocomplete` (line ~959), prune `composerMentionedSkills` entries whose token no longer appears in `text`: a small `containsBoundedToken` check (compare `Self.removeBoundedToken("$\(name)", from: text)` / `"/\(name)"` result against the original, case-insensitive). Runs on the composer's coalesced `onChange(of: input)` so backspacing a token also drops the structured mention before send. Draft restore is safe: input + mentions are set in the same main-actor turn before the coalesced handler runs.
- `onSelectSkillAutocomplete` and `replacingTrailingSkillAutocompleteToken` stay exactly as they are.
- Keep `removeMentionedSkill(id:)` (still used by queued-draft/other paths if any; harmless).

### 4. Remove the composer skill chip row

- `TurnMentionChips.swift`: delete the `showsMentionedSkills` block from `TurnComposerMentionChipSections` and drop its `onRemoveMentionedSkill` parameter.
- `TurnComposerViewState.swift`: remove `showsMentionedSkills` from `hasTopAccessoryContent` (the token now lives in the text, so it shouldn't force the accessory area open). Keep `composerMentionedSkills` in the state (used by `hasSendableContent` and the new `mentionedSkillNames` pass-through).
- Ripple the removed `onRemoveMentionedSkill` plumbing through `TurnComposerView.swift` (accessory section) and `TurnComposerHostView.swift`.

### 5. Keep skill tokens in the sent bubble text — `CodexService+ThreadsTurns.swift`

In `displayTextForOutgoingTurn`, delete the `skillMentions` loop (both the `humanTextProbe` stripping and the display-name replacement). Skill tokens stay literal in the locally stored bubble text; a skill-only message now yields `"$check-code"` instead of `""`, so the bubble renders the inline token instead of a bare chip. File mention (`@name`) handling is unchanged. Wire payload (`makeTurnInputPayload`) untouched.

### 6. Bubble inline rendering — `UserMessageBubble.swift` (+ regex)

- `TurnMessageRegexCache.userMentionToken` (only consumer is this extractor): extend the trigger class from `([@$])` to `([@$/])` so `/check-code` tokens are also matchable. Register skill chips in `selectedChipsByToken` under both `$:` and `/:` keys. `/review`-style slash commands never have a matching skill mention, so they stay literal.
- `UserBubbleMentionExtractor.renderModel`, two passes:
  1. File/plugin token replacement exactly as today → intermediate display text; compute `usesBlockMarkdown` from it.
  2. If **not** block markdown: re-scan for skill tokens that match a `skillMentions` entry and split into segments: `enum UserBubbleInlineSegment: Equatable { case text(String); case skillMention(name: String, displayLabel: String) }`. Inline-rendered skills are **removed from the chip strip**. `renderModel.text` still gets the display-label substitution (used for fingerprint/collapse heuristics). If block markdown: current behavior (chips + label substitution), no segments.
  - Skill mentions with no token in the text (older/desktop messages) keep their chip — no information loss.
- `UserBubbleRenderModel` gains `segments: [UserBubbleInlineSegment]` (empty ⇒ render as today).
- New small view (e.g. in `UserBubbleInlineMarkdownText.swift`): builds one concatenated `Text`: text segments go through the existing `UserBubbleInlineMarkdownRenderer.render(...)` per segment; skill segments are `Text(Image(uiImage: scaledTemplateIcon)) + Text(" Check Code")` with `.foregroundColor(indigo)` — SwiftUI `Text` concatenation flows and wraps naturally and works inside `UserBubbleTextBlock`'s collapse/line-limit. The icon is the `remodex.skill` asset pre-rendered as a template `UIImage` scaled to ~the body cap height (asset intrinsic size is 24pt and `Text(Image)` doesn't scale custom assets with the font), cached statically.
- `UserMessageBubble.userBubbleText` inline path: use the segment view when `!segments.isEmpty`, else the current `UserBubbleInlineMarkdownText`.
- Update the `UserBubblePreviewCatalog` previews to reflect inline tokens.

### 7. Tests (update to the new contract; do not run unless asked)

- `TurnSkillAutocompleteTokenTests`, `CodexTurnInputPayloadSkillTests`: unchanged contract, should not need edits.
- `UserMessageParserTests` / any test asserting `displayTextForOutgoingTurn`-derived bubble text or extractor output: update expectations (skill tokens now kept in display text; extractor emits segments and drops inline skill chips).
- Add unit tests for the new pure logic: `TurnComposerInlineSkillToken` round-trip (canonical → display → canonical), atomic range expansion, selection snapping, and mention pruning in `TurnViewModel`.

## Order of work

1. `TurnComposerInlineSkillToken.swift` + unit tests (pure logic, no UI risk).
2. Bubble side (5 + 6) — read-only, validates the visual design quickly.
3. Composer side (2 + 3) — the `UITextView` edge cases live here.
4. Chip-row removal (4) last, once the token is visibly in the text.

## Verification

- Build: `xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile -destination 'generic/platform=iOS Simulator' build` (or the repo's usual scheme). Per repo guardrails: no test runs unless explicitly requested; prefer inspection + targeted build.
- Manual QA checklist (simulator or device):
  - Type `$che`, tap "Check Code" → inline icon+label token appears in the field, no chip row; continue typing plain text after it (color stays normal).
  - Backspace once on the token → whole token disappears; send afterwards → no phantom skill in the outgoing turn (check request payload/log).
  - Type `$whatever` without tapping → stays literal, sends literally.
  - Send with token → user bubble shows icon+"Check Code" inline in the prose (wrapping long text keeps it inline); skill-only message shows a bubble with just the token.
  - Wire compatibility: outgoing `turn/start` still contains the legacy `$check-code` text item + structured `skill` item (unchanged).
  - Regression: file `@mention` chips, plugin mentions, `/review` slash-command chip, paste (text + image), CJK marked-text typing, draft save/restore, send-clear, collapsed-composer morph.

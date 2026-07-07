# Plan 005: Track and cancel composer attachment-decode Tasks so they don't leak or race a fresh view model

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 6f27902..HEAD -- CodexMobile/CodexMobile/Views/Turn/Core/TurnViewModel.swift`
> If it changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as
> a STOP condition.
>
> **Environment note**: This is a Swift/SwiftUI change. There is **no
> command-line build or test gate available to you** — the CI does not run
> Xcode tests and you must not attempt to launch Xcode or a simulator.
> Verification here is by code inspection and pattern-matching against the
> exemplars named below. Be precise; a reviewer with Xcode will confirm.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `6f27902`, 2026-07-07

## Why this matters

When the user attaches a photo or pastes an image, `TurnViewModel` spawns a
`Task` to decode it and write the result back to `composerAttachments`. These
Tasks:
1. capture `self` **strongly** (no `[weak self]`), extending the view model's
   lifetime for the whole decode, and
2. are **not stored anywhere**, so `cancelTransientTasks()` — called from
   `TurnView`'s `.onDisappear` — cannot cancel them.

Attaching an image and immediately switching threads or navigating back leaves
the decode running against a view model that's no longer displayed; when it
finishes it mutates `composerAttachments` on a stale instance. Because `TurnView`
re-creates a fresh `TurnViewModel` per thread, the stale write can race or be
silently lost. The fix mirrors how every other view-scoped Task in this file is
already handled: store the Task, cancel it in `cancelTransientTasks()`, and use
`[weak self]`.

## Current state

- Task property declarations follow this style —
  `CodexMobile/CodexMobile/Views/Turn/Core/TurnViewModel.swift:372-378`:
  ```swift
  @ObservationIgnored private var threadActivationTask: Task<Void, Never>?
  @ObservationIgnored var fileAutocompleteDebounceTask: Task<Void, Never>?
  @ObservationIgnored var skillAutocompleteDebounceTask: Task<Void, Never>?
  @ObservationIgnored var pluginAutocompleteDebounceTask: Task<Void, Never>?
  @ObservationIgnored private var localDraftPersistenceDebounceTask: Task<Void, Never>?
  @ObservationIgnored var gitStatusRefreshTask: Task<Void, Never>?
  ```
- The cancellation site — `:418-432`:
  ```swift
  // Cancels view-scoped async work before the chat view model disappears.
  func cancelTransientTasks() {
      threadActivationTask?.cancel()
      threadActivationTask = nil
      fileAutocompleteDebounceTask?.cancel()
      fileAutocompleteDebounceTask = nil
      skillAutocompleteDebounceTask?.cancel()
      skillAutocompleteDebounceTask = nil
      pluginAutocompleteDebounceTask?.cancel()
      pluginAutocompleteDebounceTask = nil
      localDraftPersistenceDebounceTask?.cancel()
      localDraftPersistenceDebounceTask = nil
      gitStatusRefreshTask?.cancel()
      gitStatusRefreshTask = nil
  }
  ```
- **Leak site 1** — photo picker items, `:1288-1296`:
  ```swift
  let attachmentID = UUID().uuidString
  composerAttachments.append(TurnComposerImageAttachment(id: attachmentID, state: .loading))

  Task {
      let state = await Self.loadComposerAttachmentState(from: item)
      await MainActor.run {
          self.updateComposerAttachment(id: attachmentID, state: state, codex: codex, threadID: threadID)
      }
  }
  ```
- **Leak site 2** — pasted image data, `:1324-1333`:
  ```swift
  let attachmentID = UUID().uuidString
  composerAttachments.append(TurnComposerImageAttachment(id: attachmentID, state: .loading))

  Task {
      let state = Self.loadComposerAttachmentState(fromData: imageData)
      await MainActor.run {
          self.updateComposerAttachment(id: attachmentID, state: state, codex: codex, threadID: threadID)
      }
  }
  ```
- Exemplar of the correct `[weak self]` + stored-Task pattern already in this file
  — the `fileAutocompleteDebounceTask` assignment near `:782-788` and the
  `threadActivationTask` at `:435-436`:
  ```swift
  fileAutocompleteDebounceTask?.cancel()
  fileAutocompleteDebounceTask = Task { @MainActor [weak self] in
      guard let self else { return }
      ...
  }
  ```

Convention: view-scoped Tasks are `@ObservationIgnored private var`, typed
`Task<Void, Never>?`, cancelled+niled in `cancelTransientTasks()`, and capture
`[weak self]`. These attachment Tasks must join that set. Since there can be
several in flight at once (multiple images picked together), store them in a
dictionary keyed by `attachmentID` rather than a single optional.

## Commands you will need

No build/test command is available (see the Environment note in the header).
Verification is by `grep`/inspection:

| Purpose | Command | Expected |
|---------|---------|----------|
| Confirm new storage exists | `grep -n "attachmentLoadTasks" CodexMobile/CodexMobile/Views/Turn/Core/TurnViewModel.swift` | matches the declaration + both call sites + cancel |
| Confirm no bare strong-self Task remains at the leak sites | inspect `:1288-1296` and `:1324-1333` | both now use `[weak self]` and store the Task |

## Scope

**In scope** (the only file you should modify):
- `CodexMobile/CodexMobile/Views/Turn/Core/TurnViewModel.swift`

**Out of scope** (do NOT touch):
- `updateComposerAttachment`, `loadComposerAttachmentState` — their bodies are
  unchanged; you only change how they're invoked.
- `TurnView.swift` — its `.onDisappear → cancelTransientTasks()` wiring already
  exists and is correct; do not modify it.
- Any other Task in the file — leave the existing six as they are.

## Git workflow

- Branch: `advisor/005-composer-attachment-task-cancel`
- One commit; short imperative message, e.g. `Cancel composer attachment decode tasks on view teardown`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add storage for in-flight attachment Tasks

Near the other Task declarations (`:372-378`), add:
```swift
@ObservationIgnored private var attachmentLoadTasks: [String: Task<Void, Never>] = [:]
```

### Step 2: Store + weak-capture the photo-picker Task (leak site 1)

Replace the `Task { ... }` at `:1291-1296` with a stored, weak-capturing Task that
cleans itself out of the dictionary on completion:
```swift
attachmentLoadTasks[attachmentID] = Task { @MainActor [weak self] in
    let state = await Self.loadComposerAttachmentState(from: item)
    guard let self, !Task.isCancelled else { return }
    self.updateComposerAttachment(id: attachmentID, state: state, codex: codex, threadID: threadID)
    self.attachmentLoadTasks[attachmentID] = nil
}
```
Notes:
- `updateComposerAttachment` must run on the main actor; annotating the Task
  `@MainActor` replaces the inner `await MainActor.run { ... }`. Confirm
  `updateComposerAttachment` is main-actor-callable in this context (the view
  model is already a main-actor type in this file — verify by checking the class
  declaration; if it is NOT `@MainActor`, keep the inner `await MainActor.run { }`
  wrapper instead and place the `guard` inside it).

### Step 3: Store + weak-capture the pasted-image Task (leak site 2)

Apply the same transformation at `:1328-1333`. Note this one's
`loadComposerAttachmentState(fromData:)` is **synchronous** (no `await` on the
load), so:
```swift
attachmentLoadTasks[attachmentID] = Task { @MainActor [weak self] in
    let state = Self.loadComposerAttachmentState(fromData: imageData)
    guard let self, !Task.isCancelled else { return }
    self.updateComposerAttachment(id: attachmentID, state: state, codex: codex, threadID: threadID)
    self.attachmentLoadTasks[attachmentID] = nil
}
```

### Step 4: Cancel them in `cancelTransientTasks()`

Add to the end of `cancelTransientTasks()` (`:418-432`):
```swift
for task in attachmentLoadTasks.values { task.cancel() }
attachmentLoadTasks.removeAll()
```

**Verify (inspection)**: `grep -n "attachmentLoadTasks" <file>` shows: 1
declaration, 2 assignments (one per leak site), 2 self-cleanup nil-assignments,
and the cancel-all loop in `cancelTransientTasks`. Both leak sites now contain
`[weak self]` and no longer have a bare unstored `Task {`.

## Test plan

No automated test is runnable in this environment, and the existing
`CodexMobileTests` do not exercise view-teardown Task cancellation with a
command-line runner. Do **not** author an XCTest you cannot run — you'd be
guessing at the harness. Instead:

- Leave a one-line comment at the cancellation loop noting these Tasks are
  view-scoped (matching the existing comment style at `:418`).
- In your completion report, list the manual verification a reviewer with Xcode
  should perform: attach an image, immediately switch threads, confirm no crash
  and no stale attachment appears in the new thread's composer.

If the maintainer later wants coverage, a `TurnViewModel` unit test asserting
`cancelTransientTasks()` cancels a pending attachment Task would be the target —
note that as deferred follow-up.

## Done criteria

Machine-checkable by inspection. ALL must hold:

- [ ] `grep -c "attachmentLoadTasks" CodexMobile/CodexMobile/Views/Turn/Core/TurnViewModel.swift` returns ≥ 6 (declaration + 2 assigns + 2 cleanups + cancel loop)
- [ ] Both former leak sites (`~:1288` and `~:1324`) now capture `[weak self]`
- [ ] `cancelTransientTasks()` contains the `attachmentLoadTasks` cancel-all loop
- [ ] No bare `Task {` remains in the two attachment-intake functions
- [ ] `git status` shows only `TurnViewModel.swift` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The current code no longer matches the "Current state" excerpts (the Tasks may
  already be stored/cancelled, or the functions moved).
- The view model class is **not** main-actor-isolated and removing the inner
  `await MainActor.run { }` would change threading — in that case keep the inner
  `MainActor.run` wrapper (state the version you chose in your report).
- `updateComposerAttachment` or `loadComposerAttachmentState` have signatures
  different from the excerpts — report the mismatch.

## Maintenance notes

- If image decoding is ever moved off the view model (e.g. into a dedicated
  attachment service), the cancellation ownership moves with it; keep the
  view-teardown cancellation wired to whatever holds the Tasks.
- Reviewer should confirm `[weak self]` is present on both Tasks (the strong-self
  capture is the root cause) and that the dictionary self-cleanup can't race the
  cancel loop (cancel + `removeAll` is safe because both run on the main actor).

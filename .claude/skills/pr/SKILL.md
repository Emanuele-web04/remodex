---
name: pr
description: Create, list, check out, review, or merge GitHub pull requests using GitHub CLI. Use when the user wants any pull-request workflow, not when they want to manage issues, releases, or local-only commits.
---

# Pull Requests

Work with pull requests using the GitHub CLI (`gh`): create, list, check out,
review, and merge.

## Arguments

$ARGUMENTS

**Format:** `<action> [args...]`

- `create <head_branch> [base_branch]` - Create a pull request
- `list [filters...]` - List pull requests with filters
- `checkout <pr_number|url|branch>` - Check out a PR locally
- `review <pr_number> [approve|comment|request-changes] [comment]` - Submit a review
- `merge <pr_number> [--squash|--rebase|--merge] [--delete-branch]` - Merge a PR

## Examples

```
/github:pr create feature/user-auth
/github:pr create feature/user-auth develop
/github:pr list --reviewer @me
/github:pr list --state merged --author octocat
/github:pr checkout 123
/github:pr review 123 approve "LGTM! Great work on the refactor."
/github:pr review 123 request-changes "Please add unit tests"
/github:pr merge 123 --squash --delete-branch
```

## Instructions

### Required GitHub CLI preflight

Before any workflow step, read `../../references/github-cli-preflight.md` and complete it. Do not run workflow commands until `gh` installation and authentication are verified.

### Create

1. **Validate and resolve branches:**
   ```bash
   git check-ref-format --branch <head_branch>
   git check-ref-format --branch <base_branch>
   git rev-parse --verify "<head_branch>^{commit}"
   git rev-parse --verify "<base_branch>^{commit}" ||
     git rev-parse --verify "origin/<base_branch>^{commit}"
   ```
   If no base branch was supplied, obtain it from:
   ```bash
   gh repo view --json defaultBranchRef --jq .defaultBranchRef.name
   ```
   Store the successfully resolved local or `origin/` base ref as
   `<resolved_base_ref>` and use it consistently in subsequent `git log`
   commands.

2. **Check if head branch has commits ahead of base:**
   ```bash
   git log <resolved_base_ref>..<head_branch> --oneline
   ```
   If there are none, report "Error: No commits between <base> and <head>".

3. **Generate PR title and description:** Analyze the commits between base and
   head, create a concise title, and write a description that summarizes what
   changed, why, and any testing done:

   ```markdown
   ## Summary

   Brief description of what this PR does.

   ## Changes

   - Change 1
   - Change 2

   ## Testing

   - [ ] Tested locally
   - [ ] Unit tests pass
   ```

4. **Ensure the head exists remotely:** Check whether the head branch has an
   upstream. If it does not, show the repository and branch and ask for
   confirmation before:
   ```bash
   git push -u origin <head_branch>
   ```

5. **Prepare and confirm:** Write the generated title and description to
   separate temporary files. Show the verified repository, base/head branches,
   title, and whether the PR will be draft. Require explicit confirmation
   before creating the PR.

6. **Create the PR safely:** Read the title from its file into a quoted
   variable and pass the body by file:
   ```bash
   pr_title=$(<"$title_file")
   gh pr create --base <base_branch> --head <head_branch> \
     --title "$pr_title" --body-file <description_file>
   ```
   If the PR already exists, report the existing PR URL instead.

7. **Report the PR URL** to the user.

### List

1. **Parse filter arguments:** `--author`, `--assignee`, `--state`
   (open/closed/merged/all), `--label`, `--base`, `--draft`,
   `--search <query>`, `--limit <n>` (default 30). `@me` means the current
   authenticated user.

2. **Build and execute query:**
   ```bash
   gh pr list [--author <user>] [--assignee <user>] [--state <state>] [--label <label>] [--base <branch>] [--limit 30]
   ```

   For reviewer filter (not directly supported):
   ```bash
   gh pr list --search "review-requested:<user>"
   ```

3. **Format output** as a readable table with PR number, title, author, status
   (OPEN/DRAFT/MERGED/CLOSED), labels, and relative updated time, followed by a
   summary line such as `Showing 15 of 42 pull requests (state: open)`. If no
   results, report "No pull requests found matching your filters".

Useful queries to suggest: PRs awaiting your review
(`/github:pr list --reviewer @me`), your open PRs
(`/github:pr list --author @me`).

### Checkout

1. **Protect local changes:** Inspect:
   ```bash
   git status --porcelain
   ```
   If dirty, stop and ask the user whether to stash, commit, or cancel. Never
   stash automatically. If the user chooses stash:
   ```bash
   git stash push -u -m "github:pr checkout <pr_number>"
   git stash list --format='%gd %H %s' -n 1
   ```
   Record the exact stash selector and hash and report them to the user.

2. **Checkout the PR:**
   ```bash
   gh pr checkout <pr_number>
   ```

3. **Display PR info:**
   ```bash
   gh pr view <pr_number> --json title,author,state,body,reviewDecision
   ```

4. **Report success** with the PR title and author, current review status,
   quick follow-up commands (`gh pr diff`, `gh pr checks`), and, when a stash
   was created, the exact saved stash reference and
   `git stash apply <stash_ref>` recovery command. Do not automatically pop the
   stash onto the PR branch.

### Review

1. **Fetch PR details and diff summary:**
   ```bash
   gh pr view <pr_number> --json title,author,files,additions,deletions,commits
   gh pr view <pr_number> --json additions,deletions,files \
     --jq '{additions, deletions, files: [.files[].path]}'
   ```

2. **If no action specified**, ask the user to choose `approve`, `comment`, or
   `request-changes`.

3. **If no comment provided** and the action requires one, generate or prompt.
   `approve` may default to "LGTM!"; `comment` and `request-changes` require a
   comment.

4. **Require final confirmation:** Show the verified repository, PR number,
   title, selected review action, and a comment summary. A submitted review is
   part of the permanent PR audit trail, so do not submit it until the user
   explicitly confirms.

5. **Submit exactly one review:** Write the comment to a temporary Markdown
   file so untrusted review text is not interpolated into a shell command.
   Choose exactly one action flag and run:
   ```bash
   gh pr review <pr_number> <action_flag> --body-file <comment_file>
   ```
   `<action_flag>` must be exactly one of `--approve`, `--comment`, or
   `--request-changes`.

6. **Report success** with review status.

When suggesting review feedback, check for missing tests, security concerns,
undocumented breaking changes, and style inconsistencies; be constructive and
acknowledge good work when approving.

### Merge

1. **Check PR status:**
   ```bash
   gh pr view <pr_number> \
     --json number,title,url,state,baseRefName,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
   ```
   Save `headRefOid` as `<reviewed_head_sha>`.

2. **Verify merge requirements:** PR is open, mergeable (no conflicts),
   required reviews are approved, and CI checks pass. If not mergeable, report
   the specific blocker (conflicts, missing reviews, or failing checks) and
   stop.

3. **Choose merge strategy** if not specified: show the repository's default
   strategy and ask the user. `--merge` preserves full history, `--squash`
   cleans up messy history, `--rebase` keeps linear history.

4. **Require final confirmation:** Show the verified repository, PR number,
   title, base branch, exact `<reviewed_head_sha>`, selected strategy, and
   whether the remote branch will be deleted. Do not merge until the user
   explicitly confirms this exact operation.

5. **Merge the reviewed commit only:** Choose exactly one strategy flag and run:
   ```bash
   gh pr merge <pr_number> <strategy_flag> \
     --match-head-commit <reviewed_head_sha> [--delete-branch]
   ```
   `<strategy_flag>` must be exactly one of `--squash`, `--rebase`, or
   `--merge`. If GitHub reports that the head commit changed, stop and repeat
   the review/readiness checks against the new SHA; never retry without showing
   the new commit to the user.

6. **Report success** with the merge commit SHA, branch deletion status, and a
   link to the merged PR. Suggest local cleanup:
   ```bash
   git checkout main
   git pull
   git branch -d <feature-branch>
   ```

## Important

- Do NOT add any AI/LLM attribution or co-author lines
- Keep titles and descriptions professional and focused on the code changes

## Error Handling

- If the GitHub CLI preflight fails, stop and follow its installation or
  browser-authentication guidance; do not run the PR command.
- If PR not found: "Error: PR #<number> not found"
- If branch doesn't exist: "Error: Branch '<branch>' not found"
- If already merged: "Error: PR #<number> is already merged"
- If reviewing your own PR with `approve` or `request-changes`: "Error: GitHub
  does not allow approving or requesting changes on your own PR." A `comment`
  review is still allowed.
- If checkout finds conflicts: "Warning: Merge conflicts detected. Resolve before testing."

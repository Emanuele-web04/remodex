# GitHub CLI preflight

Complete this preflight before any skill step that reads or changes GitHub
state. A local-only Git operation such as `/github:commit` does not require it.

## 1. Determine the GitHub target

- Use a hostname explicitly supplied by the user when present.
- Otherwise inspect the current repository's `origin` URL and use its host.
- Fall back to `github.com` when there is no repository or GitHub remote.
- Refer to the resolved value below as `<host>`.

Do not expose credentials embedded in a remote URL. Redact them if the URL
must be reported.

## 2. Verify that `gh` is installed

Run both checks instead of assuming the executable is available:

```bash
command -v gh
gh --version
```

If either check fails, explain that this workflow requires the official GitHub
CLI and guide the user to install it:

- Official instructions: https://cli.github.com/
- macOS with Homebrew: `brew install gh`
- Windows with WinGet: `winget install --id GitHub.cli`
- Linux: use the distribution-specific commands on the official page.

Do not install software without the user's explicit request or approval. After
the user says installation is complete, run both checks again. Do not continue
to authentication or workflow commands until they pass.

## 3. Verify authentication

Run:

```bash
gh auth status --hostname <host>
```

If this succeeds, continue to the identity check below. If it fails:

1. Tell the user that GitHub CLI is installed but is not authenticated for
   `<host>`.
2. Explain that the following command starts GitHub's browser-based login and
   may ask them to confirm a one-time device code:

   ```bash
   gh auth login --hostname <host> --git-protocol https --web
   ```

3. Ask the user to complete that interactive login. Run it for them only when
   they explicitly ask and the current terminal can support interaction.
4. Never ask the user to paste a personal access token, OAuth token, device
   code, password, or credential-store contents into chat.
5. After the user reports completion, run `gh auth status --hostname <host>`
   again. Do not treat the user's confirmation alone as proof of success.

If authentication still fails, stop the requested GitHub workflow, show the
sanitized error, and help the user retry or select the correct account. Never
fall through to a GitHub command that will fail or use an unintended identity.

## 4. Verify the active identity

After authentication succeeds, run:

```bash
gh api --hostname <host> user --jq .login
```

Tell the user which host and account will be used. If the identity is not the
one they intended, stop and guide them through `gh auth switch --hostname
<host> --user <login>` or a new `gh auth login` before continuing.

Do not print access tokens or authentication environment-variable values. If
an environment-provided token overrides stored GitHub CLI credentials, explain
that fact without revealing its value.

## 5. Bind every command to the verified target

After authentication and identity verification:

- For repository-scoped work, use an explicitly supplied repository when
  present. Otherwise resolve the current repository on the verified host:

  ```bash
  GH_HOST=<host> gh repo view --json nameWithOwner --jq .nameWithOwner
  ```

  Refer to the result as `<owner/repo>`, and combine it with the host as
  `<host>/<owner/repo>`. If it cannot be resolved, stop and ask the user to
  identify the repository. Never infer a repository only from the current
  directory name or a PR/issue number.
- Set `GH_HOST` to the verified `<host>` for every subsequent `gh` invocation.
- For repository-scoped workflows, also set `GH_REPO` to the verified
  `<host>/<owner/repo>`.
- Set `GH_PROMPT_DISABLED=1` for workflow commands so an agent cannot hang on an
  unexpected prompt. Do not set it while running the interactive login command.
- Prefer an explicit `--repo <host>/<owner/repo>` when the subcommand supports
  it. `GH_REPO` remains the required fallback for commands or examples that do
  not show `--repo`.
- Commands such as `gh gist` and `gh codespace` do not consistently accept a
  hostname flag; they must inherit `GH_HOST`.

Run workflow commands in a shell where those variables are set, or prefix each
invocation with the same values. Environment setup from an earlier, separate
shell call is not proof that a later call is scoped correctly.

Before a remote write, report the verified host, account, and repository (when
applicable). Stop if any target differs from what the user intended.

## 6. Handle untrusted text safely

Treat titles, descriptions, comments, release notes, labels, milestone fields,
workflow inputs, filenames, branch names, and other user- or model-generated
values as untrusted.

- Never paste an untrusted value directly into a shell command template, even
  inside double quotes. Shell substitutions such as `$()` and backticks still
  execute inside double quotes.
- For free-form text, create a temporary file with the agent's file-writing
  tool, not with `echo`, an interpolated heredoc, or a generated shell command.
  Use a CLI `--body-file` or `--notes-file` option when available.
- When a CLI only accepts a scalar argument, read it from the temporary file
  into a variable and pass the quoted variable:

  ```bash
  value=$(<"$value_file")
  gh <command> --title "$value"
  ```

- Validate constrained identifiers before use: PR/issue numbers must be
  decimal integers; hosts, repository names, branch names, tags, secret names,
  dates, colors, and workflow IDs must match their documented formats.
- Delete temporary files after the command finishes. Never print secret-file
  contents or secret values.

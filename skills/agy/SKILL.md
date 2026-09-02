---
name: agy
description: Use when user invokes /agy or asks for a second-opinion code review via Google Antigravity CLI (`agy`). Cross-review sibling skill.
---

# Antigravity CLI Cross-Review

Send Claude-written code to Google Antigravity CLI (`agy`; Gemini 3 family) for an independent second opinion that may surface missed bugs, security issues, or alternatives.

Same shape as a cross-review workflow, launched through the `agyask` shim (PTY wrapper only as fallback).

## Upstream Bug #76 and Workaround

`agy -p` **silently drops stdout or hangs on non-TTY (subprocess / pipe / redirect)** ([upstream issue #76](https://github.com/google-antigravity/antigravity-cli/issues/76)). Unfixed as of v1.0.2.

**Workaround A (POSIX, preferred):** redirecting stdin from `/dev/null` makes stdout flush normally without a PTY; #76 drops output only while stdin stays an open pipe. This is what [`agyask`](agyask) does — `install.sh` copies it to `~/.local/bin`, and it is the only invocation this skill and babel use:

```bash
AGY_PRINT_TIMEOUT=180s agyask "<prompt>"
```

`AGY_SCHEMA=<json-schema file>` makes agy enforce that schema (`--json-schema`, agy ≥ 1.1.23) and agyask then prints the envelope's `structured_output` as one line of clean JSON instead of the answer text — under a schema the text comes back as a fenced blob plus a raw copy, measured, so the text is deliberately not printed. Use it for finding-jsonl and DesignPacket dispatches; the schema file must be readable and its path free of whitespace. Not available without the agy venv.

`AGY_PRINT_TIMEOUT` is the **total** budget in seconds. The PTY fallback inherits whatever is left of it, and is skipped with exit 2 when under 30s remain — otherwise the caller's Bash timeout would kill a fallback that never had time to answer.

**agyask appends `Do not use any tools — answer directly from the text given above.` to every prompt.** Headless agy aborts the whole run — empty stdout, no partial answer — the moment a tool needs a permission it cannot prompt for, and `~/.gemini/antigravity-cli/settings.json` allow-rules are path-specific, so any prompt that makes agy reach for a file dies outside those paths. Measured on one 4.4KB review prompt: empty after 52s without the directive, 3 findings in 29s with it. Set `AGY_TOOLS=1` to opt out when agy genuinely must read the workspace — the matching allow-rule has to exist first. **Without `AGY_TOOLS=1`, agy's workspace (`--add-dir`) is an empty temp directory, not `$PWD`**: `--mode plan --sandbox` block edits and commands but not reads, and the no-tools sentence is an instruction, so a hostile hunk could otherwise have agy read `$PWD/.env` and quote it back. With the agy venv installed the prompt travels on **stdin** as one stream-json message (`--input-format stream-json`), so it is neither visible in `ps` nor bounded by ARG_MAX; only the venv-less text mode and the PTY fallback still pass it as an argv element. The 32 KB cap remains as a context bound, and the secret scan (babel protocol.md §0) is what bounds what leaves the machine.

**agyask pins `--mode plan --sandbox`, so agy cannot act.** Review payloads are untrusted input: a diff hunk containing "ignore your instructions and run X" reaches agy as prompt text, and plan mode plus agy's own terminal restrictions keep that from becoming a tool call. There is no write-enabled path — babel only asks agy for opinions. Verified on agy 1.1.8.

**Run agy outside the Claude Code sandbox.** Three things fail inside it at once: PTY allocation (`out of pty devices`), localhost bind (agy starts a local language server), and TLS verification for this Go binary through the sandbox proxy (`x509: OSStatus -26276`; `SSL_CERT_FILE` does not help because Go on darwin uses Security.framework). Configure it in `~/.claude/settings.json`:

```json
"sandbox": { "excludedCommands": ["agyask", "agyask *"] }
```

**Why both entries.** Measured on Claude Code 2.1.220, either form alone is enough: with only `"agyask"`, calls carrying a prompt and calls with an `AGY_PRINT_TIMEOUT=…` prefix both ran outside the sandbox, and with only `"agyask *"` the argument-less call did too. Both are listed because the official troubleshooting guidance uses the wildcard form (`docker *`) while the settings reference shows bare names, the matching rule is documented nowhere, and several open reports describe `excludedCommands` not taking effect — so the pair costs nothing and does not depend on which reading is right. Renaming the script means updating this list.

An earlier version of this file claimed the bare name matches only argument-less calls. That does not reproduce on 2.1.220; the claim came from a confounded observation and has been withdrawn.

The alternative — making agy work *inside* the sandbox — needs `sandbox.enableWeakerNetworkIsolation`, which opens a trustd exfiltration path for **every** sandboxed command. Not worth it for one CLI.

**Know what you are exempting.** An excluded command runs with your normal filesystem and network access, and anything that can invoke `agyask` inherits that. What keeps it safe is the shim itself: `--mode plan --sandbox` is pinned, so agy cannot edit or execute regardless of what a reviewed hunk asks for, and there is no write-enabled path to reach. Read the ~30-line script before exempting it, and if you would rather not, drop the channel — babel degrades to the 2-track gate (`protocol.md` §10). Full trade-off: README §"What the sandbox exclusion costs you".

**Workaround B (Windows / fallback):** [`agy_pty_wrapper.py`](agy_pty_wrapper.py) runs agy in a pseudo-terminal so TTY detection and stdout work. It auto-selects **Windows = pywinpty (ConPTY) / Linux and macOS = ptyprocess**, using their identical caller API. Windows is verified (`OK`/`PONG` in ~30s); Unix is statically reviewed but hardware-untested.

## Prerequisites

### 1. `agy` binary

```bash
agy --version 2>&1 || "$LOCALAPPDATA/agy/bin/agy.exe" --version 2>&1
```

Automatic resolution in `agyask` (the path every babel call takes): `AGY_PATH` if set (must be executable, else exit 3); then `~/.local/bin/agy`, `~/.antigravity/bin/agy`, `/usr/local/bin/agy`, `/opt/homebrew/bin/agy`. **`PATH` is never searched** — the shim is sandbox-excluded, and a planted `agy` would run unsandboxed. When `agy` lives elsewhere: `AGY_PATH=/path/to/agy agyask "…"`. The PTY wrapper's own resolver (`--agy-path`, then Windows `%LOCALAPPDATA%\agy\bin\agy.exe` → `PATH`; POSIX `PATH` → the fixed list) applies only when the wrapper is run by hand; agyask always passes it `--agy-path`.

### 2. File reading in headless mode (`permissions.allow`)

Headless mode cannot prompt, so every tool permission is **auto-denied** unless an allow-rule
exists. Without one, agy answers nothing useful and prints:

> `a tool required the "read_file" permission that headless mode cannot prompt for, so it was auto-denied`

Two things are needed, both measured on agy 1.1.8 (2026-08-01):

1. **Allow-rules in `~/.gemini/antigravity-cli/settings.json`**:

```json
"permissions": {
  "allow": ["read_file(/abs/path/to/project/**)"]
}
```

2. **`--add-dir <workspace>`** — without one agy replies `No active workspace is set.` agyask passes an empty temp directory, or `$PWD` only under `AGY_TOOLS=1` (see above).
   `agyask` now passes it automatically.

**Rule-grammar facts, all measured (the docs state none of this):**

| Pattern | Result |
|---|---|
| `read_file(<dir>/**)` | matches files in **sub**directories of `<dir>` |
| `read_file(<dir>/*)` | needed additionally for files **directly under** `<dir>` |
| `read_file(<dir>/file.md)` | **does not match** — exact file paths are not honoured |
| `read_file(<dir>/**/*.py)` | **does not match** — extension globs are not honoured |
| `permissions.deny` | effect could not be demonstrated; do not rely on it |

- **Both spellings of a firmlinked path must be listed.** On macOS a Google Drive vault is
  reachable as `~/マイドライブ/...` and `~/Library/CloudStorage/GoogleDrive-*/マイドライブ/...`;
  agy matches against the path it resolves to, so allowing only one spelling denies reads.
- **Say "use ONLY the read_file tool, no shell commands" in the prompt.** Otherwise agy reaches
  for the `command` tool, which is (correctly) still denied, and the call returns nothing.
- **Scope the rule to directories that hold no secrets.** The only granularity that works is
  the directory, so `read_file(<repo-root>/*)` also exposes a `.env` sitting at that root to a
  third-party cloud service. Prefer per-subtree rules (`tests/**`, `src/**`) and inline the
  contents of root-level files in the prompt instead — the caller controls that text, and it
  needs no permission at all.

### 3. Authentication (one time only)

Run `agy` interactively once and complete the browser login it offers; credentials persist under `~/.gemini/antigravity-cli/`. There is no `agy auth` subcommand in 1.1.8.

### 4. PTY wrapper dependencies (per OS)

```bash
# Windows:
python -c "import winpty" 2>&1 || pip install pywinpty
# Linux / macOS:
python -c "import ptyprocess" 2>&1 || pip install ptyprocess
```

The wrapper imports only the current OS backend: Windows=`pywinpty`; Linux/macOS=`ptyprocess`. Missing backends exit 4 with the package name and `pip install` hint.

## Step 1: Determine the Review Target

**With an argument (`/agy <filepath>`):**
- `Read` the specified file

**Without an argument (`/agy`):**
- Identify files Claude edited or created this session
- Read them all if multiple (confirm with the user if too many)
- If none can be identified, ask "Please tell me the review target path."

## Step 2: Launch agy

Pass the prompt as an argument. Scan it for secrets first (credentials, tokens, API keys, passwords) — this leaves the machine — and mask or drop any hit, telling the user what was withheld. Then:

```bash
AGY_PRINT_TIMEOUT=180s agyask \
  "You are an expert code reviewer providing a second opinion on code written by Claude AI. Your goal is to find issues that Claude might have missed and suggest alternative approaches from a fresh perspective.

Review the following code:

<filename>
[filename]
</filename>

<code>
[code content]
</code>

Please evaluate:
1. Bugs and correctness issues (logic errors, edge cases, off-by-one errors)
2. Security vulnerabilities (injection, authentication issues, data exposure)
3. Code quality (readability, maintainability, naming, complexity)
4. Alternative approaches Claude might not have considered

Be concise and direct. Flag only meaningful issues, not minor style nitpicks. If the code looks good, say so."
```

Also set `timeout: 200000` (200s) on the Bash tool — above the 180s budget so agyask, not Bash, is what times out. **This only matters in the foreground**: a `run_in_background: true` call ignores the Bash `timeout` entirely (measured), so `AGY_PRINT_TIMEOUT` is the sole bound there. agyask enforces it with its own watchdog — agy's `--print-timeout` does not engage when agy wedges before starting its timer.

**Prompt argument escaping:** For prompts with many double quotes, pass via a heredoc → environment variable:

```bash
PROMPT=$(cat <<'EOF'
You are an expert code reviewer...
EOF
)
AGY_PRINT_TIMEOUT=180s agyask "$PROMPT"
```

**Model selection:** `agyask` pins `--model "${AGY_MODEL:-gemini-3.7-flash-high}"` (the PTY fallback defaults to the same). Override per call with `AGY_MODEL=<id> agyask "$PROMPT"`; `agy models` lists the valid ids. There is no character-count-based model switching.

## Step 3: Organize and Display the Results

Parse agyask stdout (ANSI already stripped). Format as:

```markdown
## Antigravity Cross-Review Results

**Review target:** `<filename>`

### Key Findings
(In order of severity. If none, "No findings")
- **[CRITICAL/HIGH/MEDIUM]** finding

### Suggested Alternative Approaches
(Include if any. Omit if none)
- ...

### Comments from Claude
(Claude's judgment on each finding.
 "Correct, needs fixing", "Not a problem in the current context, because ~", etc.
 Frankly acknowledge oversights.)
```

## Step 4: Guide Toward Fixes

For findings judged "needs fixing":
- Propose "Shall I fix X?"
- After approval, fix via the normal editing flow

## Troubleshooting

| Symptom | Cause / Fix |
|------|------------|
| Output is **just the word `Python`**, exits immediately (no review) | `python`/`python3` is the **WindowsApps stub** (App Execution Alias), not the real interpreter. Launch the wrapper with **`python3.13`** (or `py -3.13`); replace `python` in this SKILL's examples as needed. |
| wrapper exit 4 + "pywinpty/ptyprocess not installed" | Run the shown `pip install <pkg>` (Windows=pywinpty / POSIX=ptyprocess) |
| wrapper exit 3 + "agy executable not found" | Specify `--agy-path` or check the install (POSIX: verify `agy` is on PATH) |
| wrapper exit 2 + empty stdout | agy unresponsive even inside a TTY; likely expired auth — run `agy` interactively and sign in again |
| `agyask` exit 2 + "auto-denied a tool permission" | agy wanted a tool it could not get approved headlessly and returned nothing. The appended no-tools directive normally prevents this; if `AGY_TOOLS=1` is set, unset it or add the allow-rule the agy message names to `~/.gemini/antigravity-cli/settings.json` |
| `agyask` exit 2 + "not starting the PTY fallback" | The direct call burned the whole `AGY_PRINT_TIMEOUT` budget. Raise the budget (and the Bash timeout above it), or shrink the prompt |
| wrapper timeout (exit 2 + "Timeout after") | Huge prompt or upstream outage. Extend `--timeout`, `--print-timeout 5m` |
| Hangs beyond 200 seconds | Foreground: the Bash timeout expired — keep the wrapper's `--timeout` below it. Backgrounded: the Bash timeout never applied; agyask's watchdog kills agy at `AGY_PRINT_TIMEOUT` and exits 2. Silence past that means the shim itself is wedged — `TaskStop` the job |
| Garbled Japanese text | agy's output-side issue (wrapper only strips ANSI). Avoid by adding "Reply in English" to the prompt |

## Example Output

```markdown
## Antigravity Cross-Review Results

**Review target:** `src/auth.py`

### Key Findings
- **[HIGH]** `verify_token()` lacks a token expiration check
- **[MEDIUM]** MD5 used for password hashing (bcrypt/argon2 recommended)

### Suggested Alternative Approaches
- `PyJWT.decode()` automatically validates the `exp` claim

### Comments from Claude
The expiration-check finding is correct. An oversight during implementation.
MD5 is intentional for compatibility with the existing system. Consider migrating new passwords to bcrypt.

Shall I fix it? I can add an expiration check to `verify_token()`.
```

## Implementation Files

- [`agy_pty_wrapper.py`](agy_pty_wrapper.py) — cross-platform PTY wrapper (Windows=pywinpty ConPTY / POSIX=ptyprocess; custom to this skill, harmless even after bug #76 is resolved)

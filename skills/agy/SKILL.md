---
name: agy
description: Use when user invokes /agy or asks for a second-opinion code review via Google Antigravity CLI (`agy`). Sibling of gemini-cli-review.
---

# Antigravity CLI Cross-Review

Send Claude-written code to Google Antigravity CLI (`agy`; Gemini 3 family) for an independent second opinion that may surface missed bugs, security issues, or alternatives.

Same workflow as `gemini-cli-review`, but launched via CLI binary + PTY wrapper.

## Upstream Bug #76 and Workaround

`agy -p` **silently drops stdout or hangs on non-TTY (subprocess / pipe / redirect)** ([upstream issue #76](https://github.com/google-antigravity/antigravity-cli/issues/76)). Unfixed as of v1.0.2.

**Workaround A (POSIX, preferred):** redirecting stdin from `/dev/null` makes stdout flush normally without a PTY; #76 drops output only while stdin stays an open pipe. Shim (`~/.local/bin/agyask`, verified on macOS + agy 1.1.8):

```sh
#!/bin/sh
out=$(agy --print-timeout "${AGY_PRINT_TIMEOUT:-150s}" -p "$@" < /dev/null)
if [ -n "$out" ]; then printf '%s\n' "$out"; exit 0; fi
exec python3 "$HOME/.claude/skills/agy/agy_pty_wrapper.py" "$@"
```

**Run agy outside the Claude Code sandbox.** Three things fail inside it at once: PTY allocation (`out of pty devices`), localhost bind (agy starts a local language server), and TLS verification for this Go binary through the sandbox proxy (`x509: OSStatus -26276`; `SSL_CERT_FILE` does not help because Go on darwin uses Security.framework). Configure it in `~/.claude/settings.json`:

```json
"sandbox": { "excludedCommands": ["agyask", "agyask *"] }
```

**`"agyask"` alone is not enough.** `excludedCommands` uses permission-rule syntax: a bare command name matches only the no-argument invocation. The `"agyask *"` entry is what exempts calls carrying a prompt — without it every real call runs sandboxed and hits the three failures above. Renaming the script means updating this list.

The alternative — making agy work *inside* the sandbox — needs `sandbox.enableWeakerNetworkIsolation`, which opens a trustd exfiltration path for **every** sandboxed command. Not worth it for one CLI.

**Workaround B (Windows / fallback):** [`agy_pty_wrapper.py`](agy_pty_wrapper.py) runs agy in a pseudo-terminal so TTY detection and stdout work. It auto-selects **Windows = pywinpty (ConPTY) / Linux and macOS = ptyprocess**, using their identical caller API. Windows is verified (`OK`/`PONG` in ~30s); Unix is statically reviewed but hardware-untested.

## Prerequisites

### 1. `agy` binary

```bash
agy --version 2>&1 || "$LOCALAPPDATA/agy/bin/agy.exe" --version 2>&1
```

Automatic resolution: `--agy-path` first; then Windows: `%LOCALAPPDATA%\agy\bin\agy.exe` → `PATH` (`shutil.which agy`); Linux/macOS: `PATH` → `~/.local/bin/agy`, `~/.antigravity/bin/agy`, `/usr/local/bin/agy`. On POSIX, use `--agy-path` when `agy` is off `PATH`.

### 2. Authentication (one time only)

```powershell
agy auth login
```

Run in PowerShell → log in via browser. Persists afterward.

### 3. PTY wrapper dependencies (per OS)

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

## Step 2: Launch agy via the PTY Wrapper

Pass the prompt as an argument. Set the timeout on both the wrapper (`--timeout`) and Bash (`timeout`):

```bash
python "$HOME/.claude/skills/agy/agy_pty_wrapper.py" \
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

Be concise and direct. Flag only meaningful issues, not minor style nitpicks. If the code looks good, say so." \
  --timeout 180
```

Also set `timeout: 200000` (200s) on the Bash tool.

**Prompt argument escaping:** For prompts with many double quotes, pass via a heredoc → environment variable:

```bash
PROMPT=$(cat <<'EOF'
You are an expert code reviewer...
EOF
)
python "$WRAPPER" "$PROMPT" --timeout 180
```

**Model selection:** `agy` has no `-m` flag; the model is fixed CLI-side (currently the Gemini 3 family). Unlike `gemini-cli-review`, it does not switch models by character count.

## Step 3: Organize and Display the Results

Parse the wrapper's stdout (ANSI already stripped). Format as:

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
| wrapper exit 2 + empty stdout | agy unresponsive even inside a TTY; likely expired auth — re-run `agy auth login` |
| wrapper timeout (exit 2 + "Timeout after") | Huge prompt or upstream outage. Extend `--timeout`, `--print-timeout 5m` |
| Hangs beyond 200 seconds | Bash timeout expired. Keep the wrapper's `--timeout` below the Bash timeout |
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

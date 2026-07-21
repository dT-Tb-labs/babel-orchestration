---
name: agy
description: Use when user invokes /agy or asks for a second-opinion code review via Google Antigravity CLI (`agy`). Sibling of gemini-cli-review.
---

# Antigravity CLI Cross-Review

Send code written by Claude Code to the Google Antigravity CLI (`agy`) and get a review from an independent second perspective.
By incorporating findings from Antigravity (Gemini 3 family), which has different training data and reasoning patterns than Claude,
you surface missed bugs, security issues, and alternative approaches.

Same workflow as `gemini-cli-review`. Difference: launched via CLI binary + PTY wrapper.

## Upstream Bug #76 and Workaround

`agy -p` **silently drops stdout or hangs on non-TTY (subprocess / pipe / redirect)** ([upstream issue #76](https://github.com/google-antigravity/antigravity-cli/issues/76)). Unfixed as of v1.0.2.

**Workaround (implemented):** [`agy_pty_wrapper.py`](agy_pty_wrapper.py) allocates a pseudo-terminal (PTY) and launches agy inside it. agy's TTY detection succeeds and stdout flushes normally. The PTY backend is auto-selected per OS: **Windows = pywinpty (ConPTY) / Linux and macOS = ptyprocess**. The caller-side API is identical for both (pywinpty intentionally mirrors the Unix `ptyprocess` API). Verified working (Windows: returns `OK`/`PONG` in ~30 seconds. The Unix path has been statically reviewed but not tested on real hardware).

## Prerequisites

### 1. `agy` binary

```bash
agy --version 2>&1 || "$LOCALAPPDATA/agy/bin/agy.exe" --version 2>&1
```

Path resolution order (handled automatically by the wrapper): first, explicit `--agy-path`. Next, an **OS branch** — on Windows, `%LOCALAPPDATA%\agy\bin\agy.exe` → `PATH` (`shutil.which agy`); on Linux and macOS, `PATH` → POSIX default candidates (`~/.local/bin/agy`, `~/.antigravity/bin/agy`, `/usr/local/bin/agy`). On POSIX, `agy` is auto-detected if it is on PATH; otherwise, specify `--agy-path`.

### 2. Authentication (one time only)

```powershell
agy auth login
```

Launch PowerShell → log in via browser. Persistent after completion.

### 3. PTY wrapper dependencies (per OS)

```bash
# Windows:
python -c "import winpty" 2>&1 || pip install pywinpty
# Linux / macOS:
python -c "import ptyprocess" 2>&1 || pip install ptyprocess
```

`pywinpty` is required on Windows, `ptyprocess` on Linux and macOS. The wrapper imports only the backend for the current OS, and if it is missing, exits with code 4, showing the package name and a `pip install` hint.

## Step 1: Determine the Review Target

**With an argument (`/agy <filepath>`):**
- Read the specified file with `Read`

**Without an argument (`/agy`):**
- Identify files Claude edited or created in the recent session
- If there are multiple, read them all (confirm with the user if there are too many)
- If none can be identified, ask "Please tell me the review target path."

## Step 2: Launch agy via the PTY Wrapper

Pass the prompt as an argument. Set the timeout on both the wrapper side (`--timeout`) and the Bash side (`timeout`):

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

Also use `timeout: 200000` (200 seconds) on the Bash tool side.

**Prompt argument escaping:** If the prompt contains many double quotes, passing it via a heredoc → environment variable is safer:

```bash
PROMPT=$(cat <<'EOF'
You are an expert code reviewer...
EOF
)
python "$WRAPPER" "$PROMPT" --timeout 180
```

**About model selection:** `agy` has no flag equivalent to `-m`. It is fixed on the CLI side (currently the Gemini 3 family). Unlike `gemini-cli-review`, it does not switch models by character count.

## Step 3: Organize and Display the Results

Parse the wrapper's stdout (ANSI already stripped). Organize it in the following format:

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

If there are findings judged as "needs fixing":
- Propose "Shall I fix X?"
- After approval, fix it through the normal editing flow

## Troubleshooting

| Symptom | Cause / Fix |
|------|------------|
| Output is **just the single word `Python`** and exits immediately (no review) | `python`/`python3` is the **WindowsApps stub** (App Execution Alias), not the real interpreter. Launch the wrapper with **`python3.13`** (or `py -3.13`). The `python` in this SKILL's command examples may need to be replaced depending on the environment. |
| wrapper exit 4 + "pywinpty/ptyprocess not installed" | Run the `pip install <pkg>` shown (Windows=pywinpty / POSIX=ptyprocess) |
| wrapper exit 3 + "agy executable not found" | Specify `--agy-path` or check the installation (on POSIX, verify `agy` is on PATH) |
| wrapper exit 2 + empty stdout | agy is unresponsive even inside a TTY. Check for expired auth: re-run `agy auth login` |
| wrapper timeout (exit 2 + "Timeout after") | Prompt is huge or upstream outage. Extend `--timeout`, `--print-timeout 5m` |
| Hangs beyond 200 seconds | Bash-side timeout expired. Verify the wrapper's `--timeout` value is less than the Bash timeout |
| Garbled Japanese text | The wrapper only strips ANSI. Garbled text is an issue on agy's output side. Avoid it by specifying "Reply in English" in the prompt |

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

- [`agy_pty_wrapper.py`](agy_pty_wrapper.py) — cross-platform PTY wrapper (Windows=pywinpty ConPTY / POSIX=ptyprocess; custom implementation for this skill, harmless even after bug #76 is resolved)

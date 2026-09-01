#!/usr/bin/env sh
# install.sh — install the babel / cdx-sol / agy skill set into ~/.claude/skills
# and self-test each channel. babel (the lead) is the only hard requirement;
# cdx-sol and agy are optional force-multiplier channels — a missing one is a
# warning, not a failure (babel degrades to fewer channels at runtime).
#
# Usage:
#   sh install.sh              # install + self-test
#   sh install.sh --check      # self-test only, no copy
#   CLAUDE_SKILLS=/path sh install.sh   # override destination
set -eu

SRC_DIR="$(CDPATH= cd "$(dirname "$0")/skills" && pwd)"
DEST="${CLAUDE_SKILLS:-$HOME/.claude/skills}"
BIN="${CLAUDE_BIN:-$HOME/.local/bin}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

pass=0; warn=0
ok()   { printf '  [ok]   %s\n' "$1"; }
note() { printf '  [warn] %s\n' "$1"; warn=$((warn+1)); }

# agy_present: mirror agyask's resolution, not the PTY wrapper's — agyask is what
# runs, and it deliberately never searches PATH (it is sandbox-excluded). Checking
# `command -v agy` here reported "channel ready" for an agy that only PATH could
# find, and the first real call then exited 3 "agy not found".
agy_present() {
  [ -n "${AGY_PATH:-}" ] && [ -x "$AGY_PATH" ] && return 0
  if [ "$OS" = windows ]; then
    [ -f "${LOCALAPPDATA:-}/agy/bin/agy.exe" ] && return 0
  else
    for p in "$HOME/.local/bin/agy" "$HOME/.antigravity/bin/agy" /usr/local/bin/agy /opt/homebrew/bin/agy; do
      [ -x "$p" ] && return 0
    done
  fi
  return 1
}

# ---- OS detection (for the PTY backend hint) ----
case "$(uname -s 2>/dev/null || echo unknown)" in
  # Pinned: this package is imported by a Python that runs OUTSIDE the Claude Code
  # sandbox, so an unpinned install makes any future release of it — or a registry
  # compromise — privileged code on this host. Bump deliberately, not silently.
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OS=windows ; PTY_PKG=pywinpty==2.0.15 ;;
  *) OS=posix ; PTY_PKG=ptyprocess==0.7.0 ;;
esac

# ---- copy ----
if [ "$CHECK_ONLY" -eq 0 ]; then
  printf 'Installing skills -> %s\n' "$DEST"
  mkdir -p "$DEST"

  # One installer at a time. mkdir is atomic on every POSIX filesystem, so this
  # is a real lock, not a check-then-act: it also covers the venv creation below,
  # which was its own check-then-act race.
  LOCK="$DEST/.babel-install.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    # A lock left behind by a SIGKILLed installer would otherwise block every
    # future install forever, with no way to tell it from a live one. The pid
    # file makes that decision mechanical.
    # mkdir fails for two very different reasons: someone holds the lock, or we
    # cannot write here at all (read-only mount, sandbox, wrong owner). Only the
    # first is a lock conflict; reporting the second as one sent the reader
    # hunting for a nonexistent stale lock.
    if [ ! -d "$LOCK" ]; then
      printf '  [FAIL] cannot create %s — the destination is not writable by this process.\n' "$LOCK"
      exit 1
    fi
    _owner=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    if [ -z "$_owner" ]; then
      # A missing pid is indeterminate, not stale: the holder takes the lock with
      # mkdir and writes its pid on the next line, so a racer landing in that gap
      # would otherwise declare a live lock dead and delete it. Give it a moment.
      sleep 2
      _owner=$(cat "$LOCK/pid" 2>/dev/null || echo "")
      [ -n "$_owner" ] || { printf '  [FAIL] install lock at %s has no owner pid — remove it by hand if no install is running.\n' "$LOCK"; exit 1; }
    fi
    if kill -0 "$_owner" 2>/dev/null; then
      printf '  [FAIL] another install is running (pid %s). Wait for it to finish.\n' "$_owner"
      exit 1
    fi
    printf '  [warn] stale install lock from pid %s — taking it over.\n' "$_owner"
    # Rename-then-delete, not `rm -rf` + `mkdir`: an unconditional clear lets two
    # installers reading the same dead pid both re-create the lock and both win.
    # Only one rename of a given directory can succeed, so the loser's `mv` fails
    # and it re-tests the lock instead of installing concurrently.
    mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null || { printf '  [FAIL] lost the race to take over the stale lock at %s — re-run the install.\n' "$LOCK"; exit 1; }
    rm -rf "$LOCK.stale.$$"
    mkdir "$LOCK" || { printf '  [FAIL] could not take the install lock at %s\n' "$LOCK"; exit 1; }
  fi
  printf '%s\n' "$$" > "$LOCK/pid"
  # Remove only a lock we still own. After a takeover the previous holder is dead,
  # but the fresh-lock race above is not the only way two installers can overlap,
  # and an unconditional rm here deletes the *other* installer's lock on exit.
  # EXIT cleans up; INT/TERM clean up AND exit. A POSIX trap handler returns to
  # where it left off, so sharing one handler across all three meant a signal
  # released the lock and then let the install carry on copying unlocked — with a
  # second installer free to start on top of it.
  # Also drops the self-check stub: it is created much later, and INT between its
  # chmod and its rm would otherwise leave an executable behind for good.
  _unlock() { [ "$(cat "$LOCK/pid" 2>/dev/null || echo "")" = "$$" ] && rm -rf "$LOCK" 2>/dev/null; rm -f "${_stub:-}" 2>/dev/null; : ; }
  trap '_unlock' EXIT
  trap '_unlock; exit 130' INT
  trap '_unlock; exit 143' TERM

  # Per-file atomic replace, never a directory swap. A directory swap always has
  # a window where the target does not exist, and a live shim exec'ing its
  # wrapper in that window fails and reports the channel dead. Renaming each file
  # into place has no such window: every path is either the old file or the new
  # one, whole, at all times.
  for s in babel cdx-sol agy; do
    if [ -d "$SRC_DIR/$s" ]; then
      (cd "$SRC_DIR/$s" && find . -type f) | while IFS= read -r f; do
        rel=${f#./}
        mkdir -p "$DEST/$s/$(dirname "$rel")"
        cp "$SRC_DIR/$s/$rel" "$DEST/$s/.$(basename "$rel").tmp.$$"
        mv "$DEST/$s/.$(basename "$rel").tmp.$$" "$DEST/$s/$rel"
      done
      # Remove files the source no longer has, after the new ones are in place.
      (cd "$DEST/$s" && find . -type f) | while IFS= read -r f; do
        rel=${f#./}
        case "$rel" in .*|*/.*) continue ;; esac
        [ -f "$SRC_DIR/$s/$rel" ] || rm -f "$DEST/$s/$rel"
      done
      ok "copied $s"
    else
      note "source skill missing: $s (skipped)"
    fi
  done
  for shim in agy/agyask cdx-sol/solask; do
    if [ -f "$SRC_DIR/$shim" ]; then
      mkdir -p "$BIN"
      # cp truncates the destination in place: a shim executing at that moment
      # reads a half-written script. Write beside it and rename — rename is atomic
      # on the same filesystem, so a concurrent exec sees either version whole.
      cp "$SRC_DIR/$shim" "$BIN/.${shim#*/}.$$"
      chmod +x "$BIN/.${shim#*/}.$$"
      mv "$BIN/.${shim#*/}.$$" "$BIN/${shim#*/}"
      ok "installed ${shim#*/} -> $BIN"
    fi
  done
fi

# ---- self-test ----
printf '\nSelf-test:\n'

# babel (required): files present at destination
# advanced.md is in the required set, not optional: L acceptance, the delta routing
# and the stuck playbook all dispatch out of it, and an interrupted copy that left
# it behind used to self-test as a complete install. loop.md is required for the
# same reason one step earlier: Phase 0.5 reads it on EVERY task to pick the route,
# so an install missing it silently runs every task linear.
if [ -f "$DEST/babel/SKILL.md" ] && [ -f "$DEST/babel/references/protocol.md" ] && [ -f "$DEST/babel/references/patterns.md" ] && [ -f "$DEST/babel/references/advanced.md" ] && [ -f "$DEST/babel/references/loop.md" ]; then
  ok "babel (lead) installed"
  pass=$((pass+1))
else
  printf '  [FAIL] babel not installed at %s — this is the one hard requirement.\n' "$DEST"
  exit 1
fi
# The A6 acceptance Workflow script lives inside a fenced block in advanced.md, so
# nothing else parses it before a live L round tries to run it. Check it here, and
# exercise its receipt gate (protocol.md §7) on the two cases that decide whether a
# lazy round is detectable at all: a response with no receipt, and one echoing a
# token that is not this dispatch's.
if command -v node >/dev/null 2>&1; then
  # Same temp idiom as the copy step above: a sibling of the destination, which the
  # lock already proved writable. mktemp would put it in TMPDIR, which is exactly the
  # kind of host difference this script keeps getting bitten by.
  # A workflow script is NOT a standalone module in either format: it carries
  # `export const meta` (ESM-only) AND a top-level `return` (illegal in ESM) AND
  # top-level `await`, because the harness runs the body as an async function. So
  # check it the way the harness loads it — strip the `export` keyword and wrap the
  # body — rather than trusting an extension. Measured: as .mjs it dies on "Illegal
  # return statement"; as .js it happened to pass on Node 26 with no package.json
  # above $DEST, and would fail under one saying "type":"commonjs". Both readings
  # abort the install claiming the A6 script is broken when it is not.
  a6="$DEST/.babel-a6-check.$$.js"
  { printf '(async () => {\n'
    awk '/^```javascript/{f=1;next} f&&/^```$/{exit} f' "$DEST/babel/references/advanced.md" \
      | sed 's/^export const meta/const meta/'
    printf '\n})()\n'
  } > "$a6"
  if node --check "$a6" 2>/dev/null && node -e '
    const fs = require("fs"), src = fs.readFileSync(process.argv[1], "utf8")
    const grab = re => (src.match(re) || [""])[0]
    const fn = grab(/^const receiptFailure[\s\S]*?\n}$/m) + "\n" + grab(/^const LENS = \{[\s\S]*?\n\}$/m)
    const A = { receiptTokens: ["tok-a", "tok-b"] }
    const CHANGESET = "cs.diff", SPEC = "spec.md"
    const gate = new Function("A", "DISPATCHED", fn + "; return receiptFailure")(A, [CHANGESET, SPEC])
    const keys = ["correctness"]
    const good = { tokens: ["tok-a", "tok-b"], paths: ["a.py"], dimensions: keys, unread: [] }
    if (gate({ receipt: good }, keys)) throw new Error("valid receipt rejected")
    if (!gate({}, keys)) throw new Error("missing receipt accepted")
    if (!gate({ receipt: { ...good, tokens: ["tok-a", "tok-x"] } }, keys)) throw new Error("wrong token accepted")
    if (!gate({ receipt: { ...good, tokens: ["tok-b", "tok-a"] } }, keys)) throw new Error("swapped tokens accepted")
    if (!gate({ receipt: { ...good, tokens: ["tok-a"] } }, keys)) throw new Error("one-ended receipt accepted")
    if (!gate({ receipt: { ...good, paths: [] } }, keys)) throw new Error("empty paths accepted")
    if (!gate({ receipt: { ...good, unread: [CHANGESET, SPEC] } }, keys)) throw new Error("all-unread accepted")
  ' "$a6" 2>/dev/null; then
    ok "babel A6 workflow script parses and its receipt gate holds"
    pass=$((pass+1))
  else
    printf '  [FAIL] babel A6 script failed node --check or its receipt gate did not hold (%s)\n' "$a6"
    rm -f "$a6"
    exit 1
  fi
  rm -f "$a6"
fi

# The loop route's frozen-set gate (loop.md §L2) is the one control standing between
# a candidate and the evaluator it is scored by, and like the A6 script it lives in a
# fenced block nothing parses until a live loop runs it. Check it here: extract, and
# require it to be valid sh that defines all three functions. The behavioural test
# (does it catch modification, deletion AND addition) is skills/babel/tests/loop-selftest.sh
# in the repo, which needs the repo checkout this installer may not be run from.
lp="$DEST/.babel-loop-check.$$.sh"
awk '/^```bash$/{b="";inb=1;next} /^```$/{if(inb&&b~/frozen_manifest\(\) \{/){printf "%s",b;exit} inb=0;next} inb{b=b $0 "\n"}' \
  "$DEST/babel/references/loop.md" > "$lp"
if grep -q 'frozen_check() {' "$lp" && grep -q 'frozen_record() {' "$lp" && sh -n "$lp" 2>/dev/null; then
  ok "babel loop.md frozen-set gate parses"
  pass=$((pass+1))
else
  printf '  [FAIL] babel loop.md frozen-set gate missing or not valid sh (%s)\n' "$lp"
  rm -f "$lp"
  exit 1
fi
rm -f "$lp"

# babel runtime prereqs (superpowers + Workflow tool) live inside Claude Code and
# cannot be probed from a shell — see skills/babel/SKILL.md "Dependencies & minimal setup".
note "babel needs the superpowers skill set + Workflow tool inside Claude Code (not shell-checkable; see SKILL.md)"

# cdx-sol (optional): Node + companion + auth
if command -v node >/dev/null 2>&1; then
  if [ -f "$DEST/cdx-sol/cdx-sol.mjs" ] && node "$DEST/cdx-sol/cdx-sol.mjs" --selftest >/dev/null 2>&1; then
    ok "cdx-sol channel ready (node + companion; --selftest never calls SOL, so auth stays unverified — run 'codex login' if the first real call returns empty)"
    if [ "$(command -v solask 2>/dev/null)" -ef "$BIN/solask" ] 2>/dev/null; then
      note "cdx-sol runs outside the Claude Code sandbox: add \"solask\" AND \"solask *\" to sandbox.excludedCommands in ~/.claude/settings.json (its own sandbox-exec cannot nest inside Claude's). An excluded command runs unsandboxed — read the shim and README 'What the sandbox exclusion costs you' first, or skip it and let the channel degrade off. Then call SOL as: solask --tier normal --cwd <repo> \"<prompt>\""
    else
      note "solask not on PATH — babel calls SOL through it. Add $BIN to PATH (until then every SOL call needs a per-call sandbox bypass)."
    fi
  else
    note "cdx-sol present but self-test failed — check Codex CLI install + 'codex login'. Channel will degrade off."
  fi
else
  note "node not found — cdx-sol channel unavailable (babel degrades to fewer channels)"
fi

# agy (optional): PTY backend + agy binary
PYTHON=""
for c in python3.13 python3 python; do command -v "$c" >/dev/null 2>&1 && { PYTHON="$c"; break; }; done
AGY_VENV="$HOME/.local/share/babel/agy-venv"
if [ -n "$PYTHON" ]; then
  # Prefer a dedicated venv: PEP 668 blocks `pip install` into a system Python, and
  # the venv lives outside $DEST because installing wipes and recopies that tree.
  # agyask resolves the same path, falling back to plain python3.
  # Windows venvs put executables in Scripts/ with .exe names; the POSIX-only
  # bin/python3 paths made every Windows install fall back to the system Python
  # while reporting the venv step as done.
  case "$OS" in
    windows) VENV_PY="$AGY_VENV/Scripts/python.exe"; VENV_PIP="$AGY_VENV/Scripts/pip.exe" ;;
    *)       VENV_PY="$AGY_VENV/bin/python3";        VENV_PIP="$AGY_VENV/bin/pip" ;;
  esac
  if [ ! -x "$VENV_PY" ]; then
    "$PYTHON" -m venv "$AGY_VENV" >/dev/null 2>&1 || true
  fi
  # Install the package whenever it is missing, not only when the venv is new: an
  # interrupted first run left a venv whose python existed but whose package never
  # landed, and the old "only if python is absent" guard skipped it forever after.
  if [ -x "$VENV_PY" ] && ! "$VENV_PY" -c "import importlib,sys;importlib.import_module('winpty' if sys.platform.startswith('win') else 'ptyprocess')" >/dev/null 2>&1; then
    "$VENV_PIP" -q install "$PTY_PKG" >/dev/null 2>&1 || true
  fi
  [ -x "$VENV_PY" ] && PYTHON="$VENV_PY"
  if "$PYTHON" - <<PYEOF >/dev/null 2>&1
import importlib, sys
importlib.import_module("winpty" if sys.platform.startswith("win") else "ptyprocess")
PYEOF
  then
    if agy_present; then
      # Compare against the copy just installed: a bare `command -v` happily
      # reports a stale agyask from some other PATH entry as "ready".
      # -ef compares inode, so a PATH entry that symlinks to the installed shim
      # still counts; plain string equality rejected it.
      if [ "$(command -v agyask 2>/dev/null)" -ef "$BIN/agyask" ] 2>/dev/null; then
        ok "agy channel ready ($PYTHON + $PTY_PKG + agy binary + agyask)"
      else
        note "agyask not on PATH — babel calls agy through it. Add $BIN to PATH (channel degrades off until then)."
      fi
      # agyask's usage reporting runs agy under --output-format json and then owns
      # stdout: it must print the response text and nothing else, because the caller
      # parses every stdout line as a finding and an envelope is valid JSON on every
      # line. Exercised against a stub agy on the three shapes that decide it —
      # a good envelope, an envelope with no usage, and a truncated one. Mutation-
      # checked: dropping the parser's exit-3 guard makes the truncated case print
      # `{"conversation_id":` to stdout and exit 0.
      # Gated on the venv interpreter, because agyask only turns JSON mode on when
      # it finds one. Without it the shim runs exactly as it always did and reports
      # tokens: null — documented graceful degradation, not a failure, so asserting
      # the JSON contract there would fail an install that is working as designed.
      if [ -x "$HOME/.local/share/babel/agy-venv/bin/python3" ] || [ -x "$HOME/.local/share/babel/agy-venv/Scripts/python.exe" ]; then
      # Not in $BIN: that directory is on the user's PATH, and an install that
      # aborts between here and the rm below would leave an executable behind in it.
      _stub="$DEST/.agyask-stub.$$"
      cat > "$_stub" <<'STUB'
#!/bin/sh
case "$STUB_CASE" in
ok) cat <<'J'
{"status":"SUCCESS","response":"line1\nline2\n","usage":{"total_tokens":12}}
J
;;
nousage) cat <<'J'
{"status":"SUCCESS","response":"hi"}
J
;;
badusage) cat <<'J'
{"status":"SUCCESS","response":"hi","usage":"unavailable"}
J
;;
jsonl) cat <<'J'
{"receipt":{"tokens":["t-a","t-b"],"paths":["x.py"],"dimensions":["correctness"],"unread":[]}}
["F1","H","x.py",1,"claim","evidence"]
J
;;
jsonlnone) cat <<'J'
{"receipt":{"tokens":["t-a","t-b"],"paths":["x.py"],"dimensions":["correctness"],"unread":[]}}
NONE
J
;;
text) printf 'plain answer\n' ;;
broken) printf '%s' '{"conversation_id":' ;;
errenv) printf '%s' '{"status":"ERROR","error":"quota exceeded"}' ;;
esac
STUB
      chmod +x "$_stub"
      _p="agyask usage self-check padded past the payload floor"
      _run() { STUB_CASE=$1 AGY_PATH="$_stub" AGY_PRINT_TIMEOUT=30s "$BIN/agyask" "$_p" 2>/dev/null || :; }
      _usage() { STUB_CASE=$1 AGY_PATH="$_stub" AGY_PRINT_TIMEOUT=30s "$BIN/agyask" "$_p" 2>&1 >/dev/null | grep -c "$2" || :; }
      _o1=$(_run ok); _u1=$(_usage ok 'BABEL_USAGE {"provider":"agy","total_tokens":12}')
      _u2=$(_usage nousage '"total_tokens":null')
      _u3=$(_usage badusage '"total_tokens":null')   # usage present but not an object
      _o4=$(_run jsonl); _o5=$(_run text); _o6=$(_run broken); _o7=$(_run jsonlnone)
      _o8=$(_run errenv)   # an agy error envelope with exit 0 is not an answer either
      rm -f "$_stub"
      # The jsonl case is the one that matters most: a real review answer starts
      # with `{"receipt":…}`, so an agy build that ignores --output-format returns
      # something that *looks* like an envelope. It must pass through verbatim, not
      # be unwrapped and not be refused. The text case is the pre-change contract.
      if [ "$_o1" = "line1
line2" ] \
         && [ "$_u1" -ge 1 ] && [ "$_u2" -ge 1 ] && [ "$_u3" -ge 1 ] \
         && [ "${_o4#\{\"receipt\"}" != "$_o4" ] && [ "${_o4%\"evidence\"]}" != "$_o4" ] \
         && [ "$_o5" = "plain answer" ] && [ -z "$_o6" ] && [ -z "$_o8" ] \
         && [ "${_o7##*
}" = "NONE" ]; then
        ok "agyask usage reporting holds (envelope unwrapped, finding-jsonl and receipt+NONE passed through, plain text unchanged, garbage refused, usage null when unavailable)"
        pass=$((pass+1))
      else
        printf '  [FAIL] agyask usage self-check: contract broken (envelope=%s usage=%s null=%s badusage=%s jsonl=%s text=%s garbage_stdout=%s clean_none=%s error_envelope_stdout=%s)\n' \
          "$_o1" "$_u1" "$_u2" "$_u3" "$_o4" "$_o5" "$_o6" "$_o7" "$_o8"
        exit 1
      fi
      else
        note "agy-venv python not found — agyask runs in plain-text mode and the channel reports tokens: null (fine; the usage self-check is skipped)."
      fi
      note "agy runs outside the Claude Code sandbox: add \"agyask\" AND \"agyask *\" to sandbox.excludedCommands in ~/.claude/settings.json (list both forms: on Claude Code 2.1.220 either alone works, but the docs use the wildcard form in one place and bare names in another, so the pair is free insurance). An excluded command runs unsandboxed — read the shim and README 'What the sandbox exclusion costs you' first, or skip it and let the channel degrade off."
    else
      note "agy binary not found (PATH or known locations) — install agy and sign in by running it interactively once, or pass --agy-path. Channel will degrade off."
    fi
  else
    note "$PTY_PKG unavailable — venv setup at $AGY_VENV failed; run: $PYTHON -m venv \"$AGY_VENV\" && \"$VENV_PIP\" install $PTY_PKG (only the PTY fallback degrades; the direct agy path still works)"
  fi
else
  note "python not found — agy channel unavailable (babel degrades to fewer channels)"
fi

# The checks above extract the two fenced blocks the installer can reach and test
# them in isolation. The repo's own test files go further — the A6 template's
# reviewer brackets, verify routing and cap accounting, the merge block's
# anonymisation, the loop gate's three violation classes — and until this block
# nothing ran them: no CI, and the installer only ever checked that files existed.
# A test nobody runs is the same defect as no test, one level up.
#
# Optional, not required, and deliberately so: two of those tests need to create and
# delete a scratch directory at the repo root, which a sandboxed run denies, and an
# install has no business failing because a directory could not be removed. The
# runner reports that case as BLOCKED rather than FAIL and exits 0, so a real
# assertion failure here is a real assertion failure.
if [ -f "$SRC_DIR/babel/tests/run-all.sh" ]; then
  if sh "$SRC_DIR/babel/tests/run-all.sh" >/dev/null 2>&1; then
    ok "babel self-tests: no failures (run 'sh skills/babel/tests/run-all.sh' to see them, and to see any that did not run)"
    pass=$((pass+1))
  else
    note "babel self-tests reported a failure — run 'sh skills/babel/tests/run-all.sh' OUTSIDE the Claude Code sandbox to see which. The install itself is fine; this is about the source."
  fi
else
  note "babel test files not present (installing from a copy without tests/) — the self-test suite was not run."
fi

printf '\nDone. %d required OK, %d optional warning(s).\n' "$pass" "$warn"
printf 'babel runs with whatever channels passed above; missing optional channels just reduce independent review depth.\n'

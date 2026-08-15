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

# agy_present: mirror agy_pty_wrapper.py's resolve_agy_path so the self-test does
# not warn "degrade off" for an agy the wrapper would actually resolve.
agy_present() {
  command -v agy >/dev/null 2>&1 && return 0
  if [ "$OS" = windows ]; then
    [ -f "${LOCALAPPDATA:-}/agy/bin/agy.exe" ] && return 0
  else
    for p in "$HOME/.local/bin/agy" "$HOME/.antigravity/bin/agy" /usr/local/bin/agy; do
      [ -f "$p" ] && return 0
    done
  fi
  return 1
}

# ---- OS detection (for the PTY backend hint) ----
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OS=windows ; PTY_PKG=pywinpty ;;
  *) OS=posix ; PTY_PKG=ptyprocess ;;
esac

# ---- copy ----
if [ "$CHECK_ONLY" -eq 0 ]; then
  printf 'Installing skills -> %s\n' "$DEST"
  mkdir -p "$DEST"
  for s in babel cdx-sol agy; do
    if [ -d "$SRC_DIR/$s" ]; then
      # Copy beside the target, then swap. `rm -rf` first leaves a window where a
      # live shim's exec target (agy_pty_wrapper.py, cdx-sol.mjs) is missing or
      # half-written, and a babel round running during a re-install then reports
      # that channel dead. The swap is two renames, not one, so it is not atomic
      # either — but it is short and holds no partially-copied tree.
      # $$ in the staging names: two installers running at once would otherwise
      # share .new/.old and delete each other's half-installed tree.
      rm -rf "$DEST/.$s.new.$$" "$DEST/.$s.old.$$"
      cp -R "$SRC_DIR/$s" "$DEST/.$s.new.$$"
      if [ -d "$DEST/$s" ]; then mv "$DEST/$s" "$DEST/.$s.old.$$"; fi
      mv "$DEST/.$s.new.$$" "$DEST/$s"
      rm -rf "$DEST/.$s.old.$$"
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
if [ -f "$DEST/babel/SKILL.md" ] && [ -f "$DEST/babel/references/protocol.md" ] && [ -f "$DEST/babel/references/patterns.md" ]; then
  ok "babel (lead) installed"
  pass=$((pass+1))
else
  printf '  [FAIL] babel not installed at %s — this is the one hard requirement.\n' "$DEST"
  exit 1
fi
# babel runtime prereqs (superpowers + Workflow tool) live inside Claude Code and
# cannot be probed from a shell — see skills/babel/SKILL.md "Dependencies & minimal setup".
note "babel needs the superpowers skill set + Workflow tool inside Claude Code (not shell-checkable; see SKILL.md)"

# cdx-sol (optional): Node + companion + auth
if command -v node >/dev/null 2>&1; then
  if [ -f "$DEST/cdx-sol/cdx-sol.mjs" ] && node "$DEST/cdx-sol/cdx-sol.mjs" --selftest >/dev/null 2>&1; then
    ok "cdx-sol channel ready (node + companion; --selftest never calls SOL, so auth stays unverified — run 'codex login' if the first real call returns empty)"
    if [ "$(command -v solask 2>/dev/null)" = "$BIN/solask" ]; then
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
    "$PYTHON" -m venv "$AGY_VENV" >/dev/null 2>&1 \
      && "$VENV_PIP" -q install "$PTY_PKG" >/dev/null 2>&1 || true
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
      if [ "$(command -v agyask 2>/dev/null)" = "$BIN/agyask" ]; then
        ok "agy channel ready ($PYTHON + $PTY_PKG + agy binary + agyask)"
      else
        note "agyask not on PATH — babel calls agy through it. Add $BIN to PATH (channel degrades off until then)."
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

printf '\nDone. %d required OK, %d optional warning(s).\n' "$pass" "$warn"
printf 'babel runs with whatever channels passed above; missing optional channels just reduce independent review depth.\n'

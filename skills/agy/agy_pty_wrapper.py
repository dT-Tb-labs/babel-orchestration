"""Cross-platform PTY wrapper for `agy -p` to bypass upstream bug #76 (non-TTY stdout drop).

Usage:
    python agy_pty_wrapper.py "<prompt>" [--timeout SEC] [--agy-path PATH] [--model MODEL]

Spawns `agy -p <prompt>` inside a pseudo-terminal so agy's TTY detection
succeeds and stdout is flushed normally. Prints captured stdout to this
script's stdout (which CAN be piped/captured by callers, since the PTY
backend handles the TTY illusion internally).

PTY backend is selected per-OS:
    Windows       -> winpty.PtyProcess      (pywinpty, ConPTY)
    Linux/macOS   -> ptyprocess.PtyProcess  (Unix pty/forkpty)
pywinpty's PtyProcess API intentionally mirrors the Unix `ptyprocess`
package, so the spawn/read/isalive/terminate call sites are identical; the
only backend difference handled below is that ptyprocess.read() returns
bytes while winpty.read() returns str.

Exit codes:
    0  - success, agy completed and produced output
    2  - agy produced no output within timeout
    3  - agy executable not found (or process did not start)
    4  - PTY backend library not installed for this platform
"""

from __future__ import annotations

import argparse
import os
import re
import select
import shutil
import sys
import time

IS_WINDOWS = os.name == "nt"

if IS_WINDOWS:
    try:
        from winpty import PtyProcess
    except ImportError:
        sys.stderr.write("pywinpty not installed. Run: pip install pywinpty\n")
        sys.exit(4)
else:
    try:
        from ptyprocess import PtyProcess
    except ImportError:
        sys.stderr.write("ptyprocess not installed. Run: pip install ptyprocess\n")
        sys.exit(4)

# CSI sequences (\x1b[...) + OSC sequences (\x1b]...\x07 or \x1b...\x1b\)
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


def _drain(proc, chunks: list) -> None:
    """POSIX final drain: pull any bytes still buffered on the pty master after the
    child has exited, so trailing output written just before exit is not lost."""
    while True:
        try:
            rlist, _, _ = select.select([proc.fd], [], [], 0)
        except (OSError, ValueError):
            return
        if not rlist:
            return
        try:
            data = proc.read(4096)
        except EOFError:
            return
        except Exception:
            return
        if not data:
            return
        chunks.append(data)


def resolve_agy_path(explicit: str | None) -> str | None:
    """Resolve the agy executable. Precedence: explicit --agy-path wins; then the
    Windows production default; then PATH; then POSIX fallback locations. Returns
    the first existing path, or None if nothing is found."""
    if explicit:
        return explicit if os.path.isfile(explicit) else None

    candidates: list[str | None] = []
    if IS_WINDOWS:
        # Preserve the established Windows default ahead of PATH so production
        # behavior does not change on machines that already rely on it.
        candidates.append(os.path.expandvars(r"%LOCALAPPDATA%\agy\bin\agy.exe"))
        candidates.append(shutil.which("agy"))
    else:
        # On POSIX, PATH is authoritative; install locations vary by distro.
        candidates.append(shutil.which("agy"))
        candidates.append(os.path.expanduser("~/.local/bin/agy"))
        candidates.append(os.path.expanduser("~/.antigravity/bin/agy"))
        candidates.append("/usr/local/bin/agy")

    for cand in candidates:
        if cand and os.path.isfile(cand):
            return cand
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt", help="Prompt text to send to agy -p")
    ap.add_argument("--timeout", type=int, default=180, help="Wall-clock timeout seconds (default 180)")
    ap.add_argument(
        "--agy-path",
        default=None,
        help="Full path to the agy executable (default: auto-resolve per-OS via PATH and known locations)",
    )
    ap.add_argument("--print-timeout", default="3m", help="agy internal --print-timeout value")
    ap.add_argument("--model", default=None, help="Model to use (passed as agy --model)")
    args = ap.parse_args()

    agy_path = resolve_agy_path(args.agy_path)
    if not agy_path:
        if args.agy_path:
            sys.stderr.write(f"agy executable not found at: {args.agy_path}\n")
        else:
            sys.stderr.write("agy executable not found on PATH or in known locations. Pass --agy-path.\n")
        return 3

    cmd = [agy_path, "-p", args.prompt, "--print-timeout", args.print_timeout]
    if args.model:
        cmd += ["--model", args.model]
    try:
        proc = PtyProcess.spawn(cmd, dimensions=(40, 200))
    except Exception as exc:  # pragma: no cover
        sys.stderr.write(f"Failed to spawn agy under PTY: {exc}\n")
        return 3

    deadline = time.time() + args.timeout
    # Accumulate raw chunks without decoding per-read: on POSIX the backend
    # returns bytes and a multibyte UTF-8 char can straddle a read boundary,
    # so we join first and decode once at the end.
    chunks: list = []
    timed_out = False
    while True:
        if time.time() > deadline:
            sys.stderr.write(f"Timeout after {args.timeout}s\n")
            timed_out = True
            try:
                proc.terminate(force=True)
            except Exception:
                pass
            break
        if IS_WINDOWS:
            # winpty.read() is non-blocking: it returns '' when no data is ready,
            # so the deadline check at the top of the loop stays reachable.
            try:
                data = proc.read(4096)
            except EOFError:
                break
            except Exception:
                break
            if not data:
                if not proc.isalive():
                    break
                time.sleep(0.1)
                continue
            chunks.append(data)
        else:
            # ptyprocess.read() wraps a blocking os.read() with no timeout, so a
            # silent/hung child would never let us re-check the deadline. Poll the
            # pty fd with select() first to keep the wall-clock timeout effective.
            try:
                rlist, _, _ = select.select([proc.fd], [], [], 0.1)
            except (OSError, ValueError):
                break
            if not rlist:
                if not proc.isalive():
                    # The child may have written its final bytes and exited in the
                    # window between select() timing out and this isalive() check.
                    # Drain everything still readable (timeout 0) before breaking so
                    # trailing output is never dropped.
                    _drain(proc, chunks)
                    break
                continue
            try:
                data = proc.read(4096)
            except EOFError:
                break
            except Exception:
                break
            if not data:
                if not proc.isalive():
                    _drain(proc, chunks)
                    break
                continue
            chunks.append(data)

    if IS_WINDOWS:
        # winpty.read() already returns str.
        raw = "".join(chunks)
    else:
        # ptyprocess.read() returns bytes; decode once to avoid boundary splits.
        raw = b"".join(chunks).decode("utf-8", errors="replace")
    clean = strip_ansi(raw)
    if timed_out:
        # Same rule agyask applies to a watchdog kill: whatever arrived before the
        # deadline is a partial answer, and a partial finding-jsonl still parses
        # line by line, so printing it lets a truncated review pass a format check
        # as a completed one. Report the size on stderr and print nothing.
        sys.stderr.write(
            "agy_pty_wrapper: timed out; discarding %d bytes of partial output.\n"
            % len(clean)
        )
        return 2
    # Write via buffer to avoid cp932 encode errors on Windows with emoji output
    sys.stdout.buffer.write(clean.encode("utf-8", errors="replace"))
    sys.stdout.buffer.flush()
    return 0 if clean.strip() else 2


if __name__ == "__main__":
    sys.exit(main())

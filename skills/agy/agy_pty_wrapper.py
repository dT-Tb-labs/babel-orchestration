"""PTY wrapper for `agy -p` to bypass upstream bug #76 (non-TTY stdout drop).

Usage:
    python agy_pty_wrapper.py "<prompt>" [--timeout SEC] [--agy-path PATH] [--model MODEL]

Spawns `agy -p <prompt>` inside a ConPTY allocated via pywinpty so agy's
TTY detection succeeds and stdout is flushed normally. Prints captured
stdout to this script's stdout (which CAN be piped/captured by callers
since pywinpty handles the TTY illusion internally).

Exit codes:
    0  - success, agy completed and produced output
    2  - agy produced no output within timeout
    3  - agy process did not start
    4  - pywinpty not installed
"""

import argparse
import os
import re
import sys
import time

try:
    from winpty import PtyProcess
except ImportError:
    sys.stderr.write("pywinpty not installed. Run: pip install pywinpty\n")
    sys.exit(4)

# CSI sequences (\x1b[...) + OSC sequences (\x1b]...\x07 or \x1b...\x1b\)
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt", help="Prompt text to send to agy -p")
    ap.add_argument("--timeout", type=int, default=180, help="Wall-clock timeout seconds (default 180)")
    ap.add_argument(
        "--agy-path",
        default=os.path.expandvars(r"%LOCALAPPDATA%\agy\bin\agy.exe"),
        help="Full path to agy.exe",
    )
    ap.add_argument("--print-timeout", default="3m", help="agy internal --print-timeout value")
    ap.add_argument("--model", default=None, help="Model to use (passed as agy --model)")
    args = ap.parse_args()

    if not os.path.isfile(args.agy_path):
        sys.stderr.write(f"agy.exe not found at: {args.agy_path}\n")
        return 3

    cmd = [args.agy_path, "-p", args.prompt, "--print-timeout", args.print_timeout]
    if args.model:
        cmd += ["--model", args.model]
    try:
        proc = PtyProcess.spawn(cmd, dimensions=(40, 200))
    except Exception as exc:  # pragma: no cover
        sys.stderr.write(f"Failed to spawn agy under PTY: {exc}\n")
        return 3

    deadline = time.time() + args.timeout
    chunks: list[str] = []
    while True:
        if time.time() > deadline:
            sys.stderr.write(f"Timeout after {args.timeout}s\n")
            try:
                proc.terminate(force=True)
            except Exception:
                pass
            break
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

    raw = "".join(chunks)
    clean = strip_ansi(raw)
    # Write via buffer to avoid cp932 encode errors on Windows with emoji output
    sys.stdout.buffer.write(clean.encode("utf-8", errors="replace"))
    sys.stdout.buffer.flush()
    return 0 if clean.strip() else 2


if __name__ == "__main__":
    sys.exit(main())

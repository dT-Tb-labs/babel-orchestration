#!/usr/bin/env python3
"""babel context-cost oracle.

Measures the bytes a lead must actually read to run a task at a given
scale+route, following the reading maps in patterns.md and SKILL.md. Bytes are
a stated proxy for tokens (~4 bytes/token for English prose); the proxy is the
metric, not the tokens, so that the number is exactly reproducible.

Usage: context-cost.py <profile>      profiles: s-linear | m-linear | l-loop
Prints one line: "<profile> <bytes>"
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BABEL = ROOT / "skills" / "babel"


def whole(rel: str) -> bytes:
    return (BABEL / rel).read_bytes()


def sections(rel: str, starts_with: list[str]) -> bytes:
    """Slice out each named section: from a heading line that startswith the
    given prefix, up to the next heading of the same or higher level."""
    text = (BABEL / rel).read_text()
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    for prefix in starts_with:
        level = len(prefix) - len(prefix.lstrip("#"))
        grabbing = False
        found = False
        for line in lines:
            if grabbing:
                m = re.match(r"^(#{1,6})\s", line)
                if m and len(m.group(1)) <= level:
                    break
                out.append(line)
                continue
            if line.startswith(prefix):
                grabbing = True
                found = True
                out.append(line)
        if not found:
            raise SystemExit(f"section not found in {rel}: {prefix!r}")
    return "".join(out).encode()


PROFILES = {
    # S, linear: SKILL.md whole + loop.md L0 (route decision, read at every
    # task) + patterns.md build-debug + protocol.md §0-§4 and §7.
    "s-linear": lambda: (
        whole("SKILL.md")
        + sections("references/loop.md", ["## L0."])
        + sections("references/patterns.md", ["## build-debug"])
        + sections(
            "references/protocol.md",
            ["## 0.", "## 1.", "## 2.", "## 3.", "## 4.", "## 7."],
        )
    ),
    # M, linear: adds design debate, the full acceptance gate, protocol §5 and
    # §8-§10.
    "m-linear": lambda: (
        PROFILES["s-linear"]()
        + sections(
            "references/patterns.md", ["## debate-aggregation", "## acceptance-gate"]
        )
        + sections(
            "references/protocol.md",
            ["## 5.", "## 7b.", "## 8.", "## 9.", "## 10."],
        )
    ),
    # L, loop: the M set plus all of loop.md and the advanced sections an L
    # loop dispatches out of.
    "l-loop": lambda: (
        PROFILES["m-linear"]()
        + whole("references/loop.md")
        + sections(
            "references/advanced.md", ["## A1.", "## A2.", "## A5.", "## A9."]
        )
    ),
}


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in PROFILES:
        raise SystemExit(f"usage: {sys.argv[0]} <{' | '.join(PROFILES)}>")
    profile = sys.argv[1]
    print(f"{profile} {len(PROFILES[profile]())}")


if __name__ == "__main__":
    main()

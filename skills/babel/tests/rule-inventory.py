#!/usr/bin/env python3
"""babel held-out guard: what survives a compression pass.

This is NOT a measure of output quality. It is a guard against the two ways a
byte-count optimizer wins without improving anything: deleting rules, and
breaking the cross-references that make a rule reachable. Read its verdict as
"nothing was silently dropped", never as "the skill still works as well".

Emits three numbers and a pass/fail:
  rules   — lines carrying a normative marker (never/must/always/do not/...)
  why     — normative lines that also carry a rationale marker (because/since/
            otherwise/the failure.../rather than), i.e. rules that still say
            what they prevent. babel's whole editorial claim is that a rule
            without its reason gets discarded by the next reader.
  refs    — cross-references (protocol.md §7, advanced.md §A9, loop.md §L2,
            patterns.md #acceptance-gate) that resolve to a real heading.
  broken  — cross-references that do not resolve. Any broken ref fails.
"""
import re
import sys
from pathlib import Path

BABEL = Path(__file__).resolve().parents[1]
DOCS = ["SKILL.md"] + [f"references/{n}.md" for n in
                       ("protocol", "patterns", "advanced", "loop")]

NORM = re.compile(
    r"\b(never|must|always|do not|don't|prohibited|mandatory|required|"
    r"forbidden|is not|cannot|only if|only when)\b", re.I)
WHY = re.compile(
    r"\b(because|since|otherwise|so that|rather than|which is why|the failure|"
    r"the defect|or the|leaves the|would then|exists for|exists to)\b", re.I)

# "protocol.md §7", "§A9", "advanced.md §A1", "patterns.md #acceptance-gate"
REF = re.compile(r"(?:(\w[\w.-]*\.md)\s*)?(§+\s*([A-Z]?\d+[a-z]?)|#([a-z][a-z-]+))")


def headings(path: Path) -> set[str]:
    out: set[str] = set()
    for line in path.read_text().splitlines():
        m = re.match(r"^#{2,3}\s+(.*)$", line)
        if not m:
            continue
        title = m.group(1).strip()
        out.add(title.lower())
        # "## 7. Verification conventions" -> "7";  "## A9. ..." -> "A9";
        # "## L2. The oracle contract" -> "L2"
        n = re.match(r"^([A-Z]?L?\d+[a-z]?)\.", title)
        if n:
            out.add(n.group(1))
        out.add(re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-"))
    return out


def main() -> None:
    head = {d: headings(BABEL / d) for d in DOCS}
    # a bare §N in a file resolves against that file first, then protocol.md,
    # which is where babel's unqualified § references point by convention.
    rules = why = refs = 0
    broken: list[str] = []
    for d in DOCS:
        text = (BABEL / d).read_text()
        for line in text.splitlines():
            if NORM.search(line):
                rules += 1
                if WHY.search(line):
                    why += 1
        for fname, _, num, anchor in REF.findall(text):
            key = num.strip() if num else anchor
            if fname:
                cands = [head.get(f"references/{Path(fname).stem}.md", set()),
                         head.get(fname, set())]
            else:
                # Unqualified refs resolve by babel's own naming convention:
                # L* lives in loop.md, A* in advanced.md, #anchors are
                # patterns.md playbook names, bare digits are protocol.md
                # sections. Without this the check reports every correct
                # cross-file shorthand in the skill as broken, which is the
                # opposite of a guard.
                if key.startswith("L"):
                    cands = [head["references/loop.md"]]
                elif key.startswith("A"):
                    cands = [head["references/advanced.md"]]
                elif anchor:
                    cands = [head["references/patterns.md"], head[d]]
                else:
                    cands = [head[d], head["references/protocol.md"]]
            if any(key in c or key.lower() in c for c in cands):
                refs += 1
            else:
                broken.append(f"{d}: {fname or ''}{'§' if num else '#'}{key}")

    print(f"rules {rules}")
    print(f"why {why}")
    print(f"refs {refs}")
    print(f"broken {len(broken)}")
    for b in broken[:20]:
        print(f"  ! {b}")
    sys.exit(1 if broken else 0)


if __name__ == "__main__":
    main()

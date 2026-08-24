#!/bin/sh
# Extracts the frozen-set gate from loop.md §L2 and exercises it.
# Same contract as gate-selftest.sh: the block in the document is runnable AS
# WRITTEN — this test never copies it, so a block that stops being valid sh, or
# that stops catching one of the three ways a frozen set can move, fails here.
#
# The three cases matter separately. Modification is the obvious one; deletion
# and ADDITION are the ones a hash-the-listed-files gate misses, and addition is
# the cheapest real attack (drop a conftest.py beside the oracle, monkeypatch the
# timer, touch nothing that was ever hashed).
set -u

REPO=$(git rev-parse --show-toplevel) || exit 1
DOC=$REPO/skills/babel/references/loop.md
TMP=$REPO/.loop-selftest-tmp
# mkdir, not rm -rf then mkdir: the scratch path is fixed, and a test must not
# delete a directory it did not create.
mkdir "$TMP" || { echo "FAIL: $TMP already exists — remove it yourself and re-run"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BLOCK=$TMP/block.sh

# the fenced bash block that defines frozen_manifest()
awk '/^```bash$/{b="";inb=1;next} /^```$/{if(inb&&b~/frozen_manifest\(\) \{/){printf "%s",b;exit} inb=0;next} inb{b=b $0 "\n"}' \
  "$DOC" > "$BLOCK"
grep -q 'frozen_manifest() {' "$BLOCK" || { echo "FAIL: frozen_manifest block not found in $DOC"; exit 1; }
grep -q '^frozen_record() {'   "$BLOCK" || { echo "FAIL: block never defines frozen_record"; exit 1; }
grep -q '^frozen_check() {'    "$BLOCK" || { echo "FAIL: block never defines frozen_check"; exit 1; }
sh -n "$BLOCK" || { echo "FAIL: extracted block is not valid sh"; exit 1; }

# $BABEL is the blackboard root the runbook says the manifest lives under, and it
# is deliberately NOT the tree candidates are applied in — a manifest a candidate
# can reach is a manifest it can edit to match. Sourcing with BABEL pointing
# inside $TMP/work would silently pass this test while documenting the hole.
BABEL=$TMP/blackboard
mkdir "$BABEL"
. "$BLOCK"
case $FROZEN in
  "$BABEL"/*) ;;
  *) echo "FAIL: block put the manifest at '$FROZEN', outside \$BABEL"; exit 1;;
esac

WORK=$TMP/work
mkdir -p "$WORK/tests" "$WORK/src"
printf 'def test_speed(): assert bench() < 100\n' > "$WORK/tests/oracle.py"
printf 'cases = [1, 2, 3]\n'                      > "$WORK/tests/fixtures.py"
printf 'def bench(): return 120\n'                > "$WORK/src/app.py"

frozen_record "$WORK" tests || { echo 'FAIL: frozen_record failed on a clean tree'; exit 1; }
[ -s "$FROZEN" ] || { echo 'FAIL: frozen_record wrote no manifest'; exit 1; }
# src/ is not frozen: a gate that rejects every change has not gated anything.
grep -q 'src/app.py' "$FROZEN" && { echo 'FAIL: manifest covers a non-frozen root'; exit 1; }

frozen_check "$WORK" tests 2>/dev/null || { echo 'FAIL: unchanged tree rejected'; exit 1; }

# the candidate everyone expects: edit the assertion
printf 'def test_speed(): assert bench() < 100000\n' > "$WORK/tests/oracle.py"
frozen_check "$WORK" tests >/dev/null 2>&1 && { echo 'FAIL: modified oracle accepted'; exit 1; }
printf 'def test_speed(): assert bench() < 100\n'    > "$WORK/tests/oracle.py"
frozen_check "$WORK" tests 2>/dev/null || { echo 'FAIL: restored tree rejected'; exit 1; }

# deletion — the oracle simply stops existing and everything "passes"
mv "$WORK/tests/fixtures.py" "$TMP/fixtures.py"
frozen_check "$WORK" tests >/dev/null 2>&1 && { echo 'FAIL: deleted frozen file accepted'; exit 1; }
mv "$TMP/fixtures.py" "$WORK/tests/fixtures.py"

# addition — nothing hashed was touched, and the oracle now measures a stub
printf 'def bench(): return 1\n' > "$WORK/tests/conftest.py"
frozen_check "$WORK" tests >/dev/null 2>&1 && { echo 'FAIL: added file inside a frozen root accepted'; exit 1; }
rm "$WORK/tests/conftest.py"

# a frozen root that does not exist is a setup error (2), not a violation (1):
# the two get different handling in §L2 and must stay distinguishable.
frozen_manifest "$WORK" nosuchdir >/dev/null 2>&1
[ $? -eq 2 ] || { echo 'FAIL: missing frozen root did not return 2'; exit 1; }

# checking with no manifest at all must not read as "intact"
mv "$FROZEN" "$TMP/manifest.away"
frozen_check "$WORK" tests >/dev/null 2>&1
[ $? -eq 2 ] || { echo 'FAIL: frozen_check with no manifest did not return 2'; exit 1; }
mv "$TMP/manifest.away" "$FROZEN"

# an empty frozen set is an unenforceable oracle, not a satisfied gate
mkdir "$WORK/empty"
frozen_record "$WORK" empty >/dev/null 2>&1
[ $? -eq 2 ] || { echo 'FAIL: empty frozen set recorded as a valid manifest'; exit 1; }

echo 'PASS: loop.md frozen-set gate catches modification, deletion and addition'

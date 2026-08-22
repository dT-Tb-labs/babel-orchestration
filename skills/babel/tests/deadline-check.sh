#!/bin/sh
# Extracts the wedged-shim check from protocol.md §8 and exercises it.
# Like gate-selftest.sh, it never copies the block: a block that stops being
# valid sh, or stops flagging a wedge, fails here.
set -u

REPO=$(git rev-parse --show-toplevel) || exit 1
DOC=$REPO/skills/babel/references/protocol.md
TMP=$REPO/.deadline-selftest-tmp
mkdir "$TMP" || { echo "FAIL: $TMP already exists — remove it yourself and re-run"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BLOCK=$TMP/block.sh

awk '/^```bash$/{b="";inb=1;next} /^```$/{if(inb&&b~/BABEL_DEADLINE/){printf "%s",b;exit} inb=0;next} inb{b=b $0 "\n"}' \
  "$DOC" > "$BLOCK"
grep -q 'BABEL_DEADLINE' "$BLOCK" || { echo "FAIL: deadline block not found in $DOC"; exit 1; }
# the block is written against .babel/<task>/results/*-r<N>.err; point it at the fixture
sed 's#\.babel/<task>/results/\*-r<N>\.err#'"$TMP"'/results/*-r1.err#' "$BLOCK" > "$BLOCK.src"
sh -n "$BLOCK.src" || { echo "FAIL: extracted block is not valid sh"; exit 1; }

R=$TMP/results
mkdir -p "$R"
now=$(date +%s)
past=$((now - 120)) ; future=$((now + 600))

fails=0
# expect <substring or ''> <label>
expect() {
  out=$(sh "$BLOCK.src" 2>&1)
  if [ -z "$1" ]; then
    [ -z "$out" ] || { echo "FAIL: $2 — expected silence, got: $out"; fails=$((fails+1)); }
  else
    case "$out" in *"$1"*) : ;; *) echo "FAIL: $2 — expected '$1', got: ${out:-<silence>}"; fails=$((fails+1)) ;; esac
  fi
}

# 1. nothing dispatched: the glob matches nothing
expect 'no .err files' 'empty results dir'

# 2. answered inside its bound
printf 'BABEL_DEADLINE {"provider":"sol","cap_s":540,"deadline":%s}\n' "$future" > "$R/sol-r1.err"
printf '{"receipt":{}}\n' > "$R/sol-r1.raw"
expect '' 'answered, inside bound'

# 3. answered but past its bound — still not a wedge, the answer is there
printf 'BABEL_DEADLINE {"provider":"sol","cap_s":540,"deadline":%s}\n' "$past" > "$R/sol-r1.err"
expect '' 'answered, past bound'

# 4. no answer, still inside its bound — waiting is correct
: > "$R/sol-r1.raw"
printf 'BABEL_DEADLINE {"provider":"sol","cap_s":540,"deadline":%s}\n' "$future" > "$R/sol-r1.err"
expect '' 'unanswered, inside bound'

# 5. no answer, past its bound — the wedge this check exists for
printf 'BABEL_DEADLINE {"provider":"sol","cap_s":540,"deadline":%s}\n' "$past" > "$R/sol-r1.err"
expect 'past its own bound' 'unanswered, past bound'

# 6. .err exists but carries no deadline: the shim never started
printf 'some unrelated stderr noise\n' > "$R/sol-r1.err"
expect 'no BABEL_DEADLINE' 'err without a deadline line'

# 7. a real agyask/cdx-sol line shape parses (guards the printf format in both shims)
rm -f "$R"/sol-r1.*
printf 'BABEL_DEADLINE {"provider":"agy","cap_s":300,"deadline":%s}\n' "$past" > "$R/agy-r1.err"
: > "$R/agy-r1.raw"
expect 'past its own bound' 'agy line shape'

[ "$fails" -eq 0 ] && { echo "deadline-check: PASS"; exit 0; }
echo "deadline-check: $fails FAILURE(S)"; exit 1

#!/bin/sh
# Extracts A10's mechanical half from advanced.md and exercises it.
# Like gate-selftest.sh and deadline-check.sh, it never copies the block: a block
# that stops being valid sh, or stops rejecting what it exists to reject, fails here.
set -u

REPO=$(git rev-parse --show-toplevel) || exit 1
DOC=$REPO/skills/babel/references/advanced.md
TMP=$REPO/.rule-attribution-selftest-tmp
# mkdir, not rm -rf then mkdir: the scratch path is fixed, and a test must not
# delete a directory it did not create.
mkdir "$TMP" || { echo "FAIL: $TMP already exists — remove it yourself and re-run"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BLOCK=$TMP/block.sh

# the fenced bash block that defines rule_present()
awk '/^```bash$/{b="";inb=1;next} /^```$/{if(inb&&b~/rule_present\(\) \{/){printf "%s",b;exit} inb=0;next} inb{b=b $0 "\n"}' \
  "$DOC" > "$BLOCK"
grep -q 'rule_present() {' "$BLOCK" || { echo "FAIL: rule_present block not found in $DOC"; exit 1; }
grep -q 'enough_tasks() {'  "$BLOCK" || { echo "FAIL: enough_tasks not defined in the same block"; exit 1; }
sh -n "$BLOCK" || { echo "FAIL: extracted block is not valid sh"; exit 1; }
. "$BLOCK"

fails=0
ok()  { if ! "$@"; then echo "FAIL: expected pass — $*"; fails=$((fails+1)); fi; }
no()  { if   "$@"; then echo "FAIL: expected reject — $*"; fails=$((fails+1)); fi; }

# --- test A: the quote is present at the named file:line, or it is not ---------
RULES=$TMP/rules.md
cat > "$RULES" <<'EOF'
first line
Surgical changes: only what is needed. Do not improve adjacent code.
a line with glob metacharacters: match *.py and [abc] literally
EOF

ok rule_present "$RULES" 2 'Do not improve adjacent code'
no rule_present "$RULES" 3 'Do not improve adjacent code'   # right quote, wrong line
no rule_present "$RULES" 2 'Do not improve adjacent codez'  # fabricated quote
no rule_present "$RULES" 2 ''                               # empty matches everything
no rule_present "$TMP/absent.md" 2 'Do not improve adjacent code'
# and it must reject a missing file *quietly*: the pass walks many records, and
# without the -f guard sed writes "No such file" to stderr for every one of them
# while the return value alone stays correct — a guard the exit status cannot test.
noise=$(rule_present "$TMP/absent.md" 2 'Do not improve adjacent code' 2>&1 >/dev/null || true)
[ -z "$noise" ] || { echo "FAIL: missing file produced stderr: $noise"; fails=$((fails+1)); }
no rule_present "$RULES" abc 'first line'                   # non-numeric line
# a glob-matching quote must not pass on a line that only glob-matches it
ok rule_present "$RULES" 3 'match *.py and [abc] literally'
no rule_present "$RULES" 3 'match *.js and [abc] literally'

# --- N=1 refusal --------------------------------------------------------------
ONE=$TMP/one.jsonl
TWO=$TMP/two.jsonl
printf '%s\n' \
  '{"t":"P6","task":"add-pagination","round":1,"what":"x","prescribed":"y","rule":null}' \
  '{"t":"P4","task":"add-pagination","round":2,"what":"x","prescribed":"y","rule":null}' > "$ONE"
cat "$ONE" > "$TWO"
printf '%s\n' \
  '{"t":"P6","task":"fix-timeout","round":1,"what":"x","prescribed":"y","rule":null}' >> "$TWO"

no enough_tasks "$ONE"              # two records, one task — still N=1
ok enough_tasks "$TWO"
no enough_tasks "$TMP/absent.jsonl"
no enough_tasks "$TMP/empty.jsonl"  # never created

[ "$fails" -eq 0 ] && echo "PASS: A10 mechanical half (rule_present, enough_tasks)"
exit "$fails"

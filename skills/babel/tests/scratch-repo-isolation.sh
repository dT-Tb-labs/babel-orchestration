#!/bin/sh
# Regression: loop-selftest.sh must never write to the repo it lives in.
#
# Its scratch git repo sits INSIDE this working tree. When `git init` failed there
# (observed in the Claude Code sandbox) the test carried on, and its next
# `git add -A && git commit` walked up to the outer repo and committed every
# pending change in it as "init". This test makes `git init` fail on purpose and
# checks that the outer repo is untouched.
#
# It never runs loop-selftest.sh against this repo: if the guard regressed, that
# run would be the incident. It runs against a throwaway clone instead, carrying
# the working-tree copies of the files under test.
set -u

REPO=$(git rev-parse --show-toplevel) || exit 1
REALGIT=$(command -v git) || exit 1
W=$(mktemp -d "${TMPDIR:-/tmp}/babel-iso.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT

git clone -q "$REPO" "$W/clone" || { echo "FAIL: could not clone $REPO"; exit 1; }
for f in skills/babel/tests/loop-selftest.sh skills/babel/references/loop.md; do
  cp "$REPO/$f" "$W/clone/$f" || exit 1
done
C=$W/clone
git -C "$C" -c user.email=t@t -c user.name=t commit -qam 'files under test' --allow-empty || exit 1
# a pending change of the kind the incident swept into its "init" commit
printf 'pending\n' > "$C/pending.txt"

# a git whose `init` fails, and everything else passes through
mkdir "$W/bin"
cat > "$W/bin/git" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = init ] && { echo 'shim: git init refused' >&2; exit 1; }; done
exec "$REALGIT" "\$@"
EOF
chmod +x "$W/bin/git"

before=$(git -C "$C" rev-parse HEAD)
out=$(cd "$C" && PATH="$W/bin:$PATH" sh skills/babel/tests/loop-selftest.sh 2>&1)
rc=$?
after=$(git -C "$C" rev-parse HEAD)

[ "$before" = "$after" ] ||
  { echo "FAIL: loop-selftest committed to the outer repo when git init failed:"; git -C "$C" log --oneline -1; exit 1; }
[ -z "$(git -C "$C" diff --cached --name-only)" ] ||
  { echo 'FAIL: loop-selftest staged files in the outer repo'; exit 1; }
[ "$rc" -ne 0 ] ||
  { echo 'FAIL: loop-selftest reported success although git init failed'; printf '%s\n' "$out"; exit 1; }

echo 'scratch-repo-isolation: PASS'

#!/bin/sh
# Extracts the grounding path gate from protocol.md and exercises it.
# The point is that the block in the contract is runnable AS WRITTEN: the test
# never copies it, so a block that stops being valid sh fails here.
set -u

ROOT=$(git rev-parse --show-toplevel) || exit 1
DOC=$ROOT/skills/babel/references/protocol.md
TMP=$ROOT/.gate-selftest-tmp
trap 'rm -rf "$TMP"' EXIT
rm -rf "$TMP" && mkdir -p "$TMP" || exit 1
BLOCK=$TMP/block.sh

# the fenced bash block that defines gate(), minus its trailing invocation
awk '/^```bash$/{b="";inb=1;next} /^```$/{if(inb&&b~/gate\(\) \{/){printf "%s",b;exit} inb=0;next} inb{b=b $0 "\n"}' \
  "$DOC" > "$BLOCK"
grep -q 'gate() {' "$BLOCK" || { echo "FAIL: gate block not found in $DOC"; exit 1; }
# a failure branch that is an undefined command does not stop anything (sh: 127, then carries on)
grep -q '^reject() {' "$BLOCK" || { echo "FAIL: block calls reject but never defines it"; exit 1; }
grep -q '^ROOT=' "$BLOCK"      || { echo "FAIL: block compares against ROOT but never sets it"; exit 1; }
grep -v '^gate "\$path"' "$BLOCK" > "$BLOCK.src"
sh -n "$BLOCK.src" || { echo "FAIL: extracted block is not valid sh"; exit 1; }
. "$BLOCK.src"

# a throwaway root, so every banned path below is a file that really exists:
# a gate that rejects only because the file is missing has not been tested.
mkdir -p "$TMP/repo/.ssh" "$TMP/repo/.aws" "$TMP/repo/sub" "$TMP/repo/dir"
cd "$TMP/repo" || exit 1
ROOT=$PWD
for f in .env .env.local server.pem server.key id_rsa id_ed25519 \
         .ssh/config .aws/credentials my_secret.md api_token.json db_password.txt \
         'version..js' plain.txt sub/id_rsa sub/deep.txt; do
  : > "$f"
done
ln -sf /etc/passwd link.txt
ln -sfn /etc outdir
mkdir -p "$TMP/outside" && : > "$TMP/outside/loot.txt"

fails=0
deny() { if gate "$1" 2>/dev/null; then echo "FAIL: opened $1"; fails=$((fails+1)); fi; }
allow() { if ! gate "$1" 2>/dev/null; then echo "FAIL: rejected $1"; fails=$((fails+1)); fi; }

deny /etc/passwd                 # absolute
deny ../outside/loot.txt         # traversal, and lands outside the root
deny sub/../../outside/loot.txt
deny outdir/passwd               # symlinked directory out of the tree
deny link.txt                    # symlink to a file out of the tree
deny .env
deny .env.local
deny server.pem
deny server.key
deny id_rsa                      # root-level: no */-anchored pattern reaches these
deny id_ed25519
deny sub/id_rsa
deny .ssh/config
deny .aws/credentials
deny my_secret.md
deny api_token.json
deny db_password.txt
deny dir                         # a directory is not a regular file
deny does-not-exist.txt

allow plain.txt
allow sub/deep.txt
allow 'version..js'              # a double dot is not a traversal component

[ "$fails" -eq 0 ] && { echo "gate-selftest: PASS"; exit 0; }
echo "gate-selftest: $fails FAILURE(S)"; exit 1

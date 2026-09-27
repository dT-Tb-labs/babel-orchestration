#!/bin/sh
# The babel dispatch must be ONE plain command: sandbox.excludedCommands stops
# matching on an env prefix, redirect, $(...) or variable, and the call then dies
# inside the sandbox. This checks the shim options that make a plain command
# possible (--timeout/--in/--out/--err) and the one-line sandbox refusal.
set -u

REPO=$(git rev-parse --show-toplevel) || exit 1
AGY=$REPO/skills/agy/agyask
SOL=$REPO/skills/cdx-sol/solask
command -v pgrep >/dev/null 2>&1 && ! pgrep -l -P 1 >/dev/null 2>&1 && {
  echo "Operation not permitted: pgrep cannot read the process table — this is the sandbox; run outside it"; exit 1; }

D=$(mktemp -d "${TMPDIR:-/tmp}/shim-plain.XXXXXX") || exit 1
trap 'rm -rf "$D"' EXIT
printf '#!/bin/sh\nprintf "plain answer\\n"\n' > "$D/agy"; chmod +x "$D/agy"
printf 'a prompt long enough to pass the payload floor\n' > "$D/in.txt"

fails=0
bad() { echo "FAIL: $1"; fails=$((fails+1)); }

# 1. every option together, no shell syntax around the call
AGY_PATH="$D/agy" sh "$AGY" --timeout 30s --in "$D/in.txt" --out "$D/o" --err "$D/e"
rc=$?
[ "$rc" -eq 0 ] || bad "plain dispatch exited $rc"
grep -qx 'plain answer' "$D/o" 2>/dev/null || bad "--out did not receive the answer"
grep -q '"cap_s":30,' "$D/e" 2>/dev/null || bad "--timeout not applied / --err missing BABEL_DEADLINE"

# 2. refusals: ambiguous payload, missing file, missing value
AGY_PATH="$D/agy" sh "$AGY" --in "$D/in.txt" "also a prompt argument here ok" >/dev/null 2>&1
[ $? -eq 3 ] || bad "--in plus a prompt argument was not refused"
AGY_PATH="$D/agy" sh "$AGY" --in "$D/nope" >/dev/null 2>&1
[ $? -eq 3 ] || bad "unreadable --in was not refused"
AGY_PATH="$D/agy" sh "$AGY" --timeout >/dev/null 2>&1
[ $? -eq 3 ] || bad "--timeout without a value was not refused"

# HOME="$D" on every solask call: a regressed shim must not reach the real
# companion (it resolves cdx-sol.mjs under $HOME) and spend a live SOL call.

# 2b. --schema reaches the envelope parser (it reads AGY_SCHEMA from the
#     environment, so a set-but-unexported variable would print `response`).
#     Needs the agy venv; without it agyask refuses AGY_SCHEMA by design.
if [ -x "$HOME/.local/share/babel/agy-venv/bin/python3" ]; then
  cat > "$D/agys" <<'S'
#!/bin/sh
printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"fenced blob","structured_output":{"a":1},"usage":{"total_tokens":5}}}'
S
  chmod +x "$D/agys"; printf '{}' > "$D/schema.json"
  AGY_PATH="$D/agys" sh "$AGY" --schema "$D/schema.json" --in "$D/in.txt" --out "$D/os" --err /dev/null
  grep -qx '{"a": 1}' "$D/os" || bad "--schema did not reach the parser (got: $(cat "$D/os"))"
fi

# 3. sandbox signature -> one-line refusal, before agy is ever started
mkdir "$D/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$D/fakebin/pgrep"; chmod +x "$D/fakebin/pgrep"
printf '#!/bin/sh\ntouch "%s/agy-ran"\n' "$D" > "$D/agy2"; chmod +x "$D/agy2"
PATH="$D/fakebin:$PATH" AGY_PATH="$D/agy2" sh "$AGY" --in "$D/in.txt" --err "$D/e2"
[ $? -eq 3 ] || bad "agyask did not refuse inside the sandbox"
[ -e "$D/agy-ran" ] && bad "agyask started agy inside the sandbox"
grep -q 'INSIDE the Claude Code sandbox' "$D/e2" || bad "agyask sandbox refusal message missing"
HOME="$D" PATH="$D/fakebin:$PATH" sh "$SOL" --err "$D/e3" --tier quick hi
[ $? -eq 3 ] || bad "solask did not refuse inside the sandbox"
grep -q 'INSIDE the Claude Code sandbox' "$D/e3" || bad "solask sandbox refusal message missing"

# 4. solask strips --out/--err before its own argv scan (the --model refusal proves
#    the redirect landed and the scan still sees the remaining arguments)
HOME="$D" sh "$SOL" --out "$D/so" --err "$D/se" --model x hi
[ $? -eq 3 ] || bad "solask --model refusal lost after --out/--err"
grep -q 'model is pinned' "$D/se" || bad "solask --err did not receive stderr"

[ "$fails" -eq 0 ] && { echo "shim-plain-dispatch: PASS"; exit 0; }
echo "shim-plain-dispatch: $fails FAILURE(S)"; exit 1

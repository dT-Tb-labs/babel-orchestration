#!/bin/sh
# Runs every babel self-test and reports one line each.
#
# Why this exists: there were six tests and nothing ran any of them — no CI, and
# install.sh checked only that files were present. A test nobody runs is the same
# defect as no test, one level up, and this repo has paid for that shape before.
#
# Exit status: non-zero if any test FAILED. A test that could not run (missing
# runtime, or a leftover scratch directory) is reported as SKIP/BLOCKED and does
# NOT fail the run — but it is counted and named in the summary, because a silent
# skip is how coverage disappears without anyone deciding to drop it.
#
# Two of these tests create a scratch directory at the repo root and delete it on
# exit. Inside the Claude Code sandbox that delete is denied, so the directory
# survives and every later run refuses to start. Run this OUTSIDE the sandbox, or
# from a clone in a writable scratch path.
set -u

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "run-all: not in a git repository"; exit 1; }
T=$REPO/skills/babel/tests
[ -d "$T" ] || { echo "run-all: $T not found"; exit 1; }

pass=0; fail=0; skip=0
failed=''; skipped=''

report() {  # name status detail
  printf '  [%-7s] %-26s %s\n' "$2" "$1" "${3:-}"
}

# run <name> <runner> <file>
run() {
  _name=$1; _runner=$2; _file=$3
  if [ "$_runner" != sh ] && ! command -v "$_runner" >/dev/null 2>&1; then
    report "$_name" SKIP "$_runner not found — this test did not run"
    skip=$((skip+1)); skipped="$skipped $_name"
    return
  fi
  _out=$("$_runner" "$T/$_file" 2>&1)
  _rc=$?
  # The scratch-dir tests refuse to start when a previous run left their directory
  # behind. That is not a failing assertion and must not be reported as one, or the
  # real signal drowns in a message about a directory.
  case $_out in
    *"already exists — remove it yourself"*)
      report "$_name" BLOCKED "leftover scratch dir — remove it and re-run (see the header of this script)"
      skip=$((skip+1)); skipped="$skipped $_name"
      return ;;
    # A sandboxed run denies the writes these tests need, and the failure surfaces
    # as a perfectly ordinary-looking assertion message several lines later — the
    # test says a gitignored artifact read as a violation, when what actually
    # happened is that `git init` could not copy its hook templates. Reporting that
    # as FAIL sends the next reader to debug an assertion that is fine. Measured on
    # this repo: loop-selftest and gate-selftest both do it.
    *"Operation not permitted"*)
      report "$_name" BLOCKED "sandbox denied a write it needs — re-run outside the sandbox; any assertion message above it is a symptom, not the cause"
      skip=$((skip+1)); skipped="$skipped $_name"
      return ;;
  esac
  if [ "$_rc" -eq 0 ]; then
    report "$_name" PASS ""
    pass=$((pass+1))
  else
    report "$_name" FAIL ""
    printf '%s\n' "$_out" | sed 's/^/           /'
    fail=$((fail+1)); failed="$failed $_name"
  fi
}

printf 'babel self-tests:\n'
run gate-selftest          sh      gate-selftest.sh
run loop-selftest          sh      loop-selftest.sh
run deadline-check         sh      deadline-check.sh
run rule-attribution       sh      rule-attribution-check.sh
run a6-selftest            node    a6-selftest.mjs
run rule-inventory         python3 rule-inventory.py

printf '\n%d passed, %d failed, %d not run.\n' "$pass" "$fail" "$skip"
[ -n "$skipped" ] && printf 'not run:%s — coverage those tests provide was NOT checked.\n' "$skipped"
[ -n "$failed" ]  && printf 'failed:%s\n' "$failed"
exit "$fail"

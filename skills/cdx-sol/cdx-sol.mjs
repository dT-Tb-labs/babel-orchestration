#!/usr/bin/env node
// cdx-sol.mjs — stable, token-efficient, safe GPT-5.6-SOL invocation from Claude Code.
// Wraps codex-companion.mjs: background launch + internal poll-until-done + result.
// Read-only by default; effort via quick|normal|deep tier; terse output; oversized-output offload.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import assert from "node:assert";

// Plugin auto-updates bump the version directory (e.g. 1.0.6 -> 1.0.7); a pinned
// path silently breaks on update. Resolve the highest installed version instead.
function resolveCompanion() {
  if (process.env.CDX_SOL_COMPANION) return path.resolve(process.env.CDX_SOL_COMPANION);
  const codexDir = path.join(os.homedir(), ".claude", "plugins", "cache", "openai-codex", "codex");
  let versions = [];
  try {
    versions = fs.readdirSync(codexDir, { withFileTypes: true })
      .filter(d => d.isDirectory())
      .map(d => d.name);
  } catch { /* fall through to error below */ }
  versions.sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  const latest = versions[versions.length - 1];
  if (!latest) {
    throw new Error(
      `No openai-codex plugin version found under ${codexDir}. Set CDX_SOL_COMPANION to the codex-companion.mjs path.`
    );
  }
  return path.join(codexDir, latest, "scripts", "codex-companion.mjs");
}

const COMPANION = resolveCompanion();

const TIER_EFFORT = { quick: "low", normal: "medium", deep: "high" };
const POLL_TIMEOUT_MS = 100000; // each status --wait slice; < Claude's 120s Bash timeout
const WALL_CAP_MS = 540000;     // stop polling ~9min, before a 600s Bash call is killed
const OFFLOAD_CHARS = 24000;    // ~6k tokens; above this, offload full output to a file (balanced)
const TERSE_SUFFIX =
  "\n\n---\nReply terse: no preamble, no restatement of the task, structured bullets, code only if essential.";

function tierToEffort(tier) {
  if (tier == null) return TIER_EFFORT.normal;
  const e = TIER_EFFORT[String(tier).toLowerCase()];
  if (!e) throw new Error(`Unknown --tier "${tier}". Use quick|normal|deep.`);
  return e;
}

function buildLaunchArgs({ prompt, cwd, effort, write }) {
  const args = ["task", "--background", "--json", "--cwd", cwd, "--effort", effort];
  if (write) args.push("--write");
  args.push(`${prompt}${TERSE_SUFFIX}`);
  return args;
}

let offloadSeq = 0;

function guardOutput(text, cwd, offloadChars = OFFLOAD_CHARS) {
  const body = String(text ?? "");
  if (body.length <= offloadChars) return { rendered: body, offloaded: null };
  try {
    const dir = path.join(cwd, ".sol");
    fs.mkdirSync(dir, { recursive: true });
    // Write the ignore rule once. Rewriting it every call silently discarded any
    // edit the user had made to that file.
    // Append the rule if the file exists without it: preserving a user's file is
    // right, but leaving offloaded model output committable is not.
    const ignore = path.join(dir, ".gitignore");
    const cur = fs.existsSync(ignore) ? fs.readFileSync(ignore, "utf8") : "";
    if (!cur.split(/\r?\n/).some(l => l.trim() === "*")) {
      // Write beside it and rename: writeFileSync truncates first, so a disk-full
      // failure mid-write would destroy an existing file the catch then swallows.
      const tmp = `${ignore}.tmp.${process.pid}`;
      fs.writeFileSync(tmp, cur ? `${cur.replace(/\n?$/, "\n")}*\n` : "*\n", "utf8");
      fs.renameSync(tmp, ignore);
    }
    // pid + counter, not just a millisecond stamp: two calls landing in the same
    // millisecond would name the same file and one answer would overwrite the other.
    const file = path.join(dir, `sol-output-${Date.now()}-${process.pid}-${offloadSeq++}.md`);
    fs.writeFileSync(file, body, "utf8");
    const head = body.slice(0, 2000);
    return {
      rendered: `${head}\n\n[...truncated ${body.length} chars. Full output: ${file}]`,
      offloaded: file,
    };
  } catch {
    // Never lose SOL output: if the workspace isn't writable, return it in full.
    return { rendered: body, offloaded: null };
  }
}

function runSelftest() {
  assert.equal(tierToEffort("quick"), "low");
  assert.equal(tierToEffort("normal"), "medium");
  assert.equal(tierToEffort("deep"), "high");
  assert.equal(tierToEffort(undefined), "medium");
  assert.equal(tierToEffort("NORMAL"), "medium");
  assert.throws(() => tierToEffort("turbo"), /Unknown --tier/);

  const ro = buildLaunchArgs({ prompt: "count lines", cwd: "C:/x", effort: "medium", write: false });
  assert.deepEqual(ro.slice(0, 6), ["task", "--background", "--json", "--cwd", "C:/x", "--effort"]);
  assert.equal(ro[6], "medium");
  assert.ok(!ro.includes("--write"));
  assert.ok(ro[ro.length - 1].startsWith("count lines"));
  assert.ok(ro[ro.length - 1].includes("Reply terse"));

  const rw = buildLaunchArgs({ prompt: "fix bug", cwd: "C:/x", effort: "high", write: true });
  assert.ok(rw.includes("--write"));

  const small = guardOutput("hello", process.cwd());
  assert.equal(small.rendered, "hello");
  assert.equal(small.offloaded, null);

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "cdx-sol-selftest-"));
  const big = "x".repeat(30000);
  const g = guardOutput(big, tmp, 24000);
  assert.ok(g.offloaded && fs.existsSync(g.offloaded));
  assert.equal(fs.readFileSync(g.offloaded, "utf8").length, 30000);
  assert.ok(g.rendered.includes("truncated 30000 chars"));
  fs.rmSync(tmp, { recursive: true, force: true });

  // parseArgs: prompt assembly, "--" terminator, missing-value + numeric guards
  assert.equal(parseArgs(["--tier", "quick", "hello", "world"]).prompt, "hello world");
  assert.equal(parseArgs(["--tier", "quick", "x"]).tier, "quick");
  const term = parseArgs(["--", "--allow-write"]);
  assert.equal(term.prompt, "--allow-write");
  assert.equal(term.write, false); // terminator kept the flag-like text as prompt
  assert.throws(() => parseArgs(["--cwd"]), /Missing value/);
  assert.throws(() => parseArgs(["--offload-chars", "abc"]), /must be a number/);

  console.log("cdx-sol.mjs selftest: PASS");
}

function parseArgs(a) {
  const o = {
    tier: undefined, cwd: process.cwd(), write: false,
    attach: null, offloadChars: OFFLOAD_CHARS, prompt: "", selftest: false,
  };
  const rest = [];
  const need = (i, name) => {
    if (i >= a.length) throw new Error(`Missing value for ${name}`);
    return a[i];
  };
  let end = false; // "--" terminates option parsing so a prompt may contain flag-like text
  for (let i = 0; i < a.length; i++) {
    const t = a[i];
    if (end) { rest.push(t); continue; }
    if (t === "--") end = true;
    else if (t === "--selftest") o.selftest = true;
    else if (t === "--tier") o.tier = need(++i, "--tier");
    else if (t === "--cwd") o.cwd = need(++i, "--cwd");
    else if (t === "--allow-write") o.write = true;
    else if (t === "--attach") o.attach = need(++i, "--attach");
    else if (t === "--offload-chars") {
      const n = Number(need(++i, "--offload-chars"));
      if (!Number.isFinite(n)) throw new Error("--offload-chars must be a number");
      o.offloadChars = n;
    }
    else rest.push(t);
  }
  o.prompt = rest.join(" ");
  return o;
}

// timeoutMs bounds the child itself. Without it WALL_CAP_MS is only as real as the
// companion's own --timeout-ms: a companion that wedges (stale job file, lapsed
// auth, EPERM on the state root) never returns, so the remaining-budget check
// below it is never reached and the caller waits forever for a notification that
// cannot arrive. A backgrounded call has no harness timeout to fall back on.
// Default the bound rather than making it opt-in: an omitted argument would put
// the unbounded wedge back, and a call site that forgets is exactly how it got
// here. Callers that wait on purpose pass their own, larger value.
function runCompanion(args, cwd, timeoutMs = 60000) {
  const r = spawnSync(process.execPath, [COMPANION, ...args], {
    cwd, encoding: "utf8", maxBuffer: 64 * 1024 * 1024,
    timeout: timeoutMs, killSignal: "SIGKILL",
  });
  // Keep whatever the child managed to write. On a launch timeout the jobId may
  // already be on stdout, and discarding it orphans a live codex job that nothing
  // can re-attach to or kill.
  const stdout = r.stdout ?? "";
  const stderr = r.stderr ?? "";
  if (r.error) {
    if (r.error.code === "ETIMEDOUT") {
      return { code: -1, stdout, stderr: `${stderr}\ncompanion did not return within ${timeoutMs}ms`, timedOut: true };
    }
    // maxBuffer overflow and friends: report, but do not silently drop what came back.
    return { code: -1, stdout, stderr: `${stderr}\ncompanion failed: ${r.error.message}`, failed: true };
  }
  // status is null when the child died on a signal; `?? 0` called that success.
  const code = r.status ?? (r.signal ? -1 : 0);
  return { code, stdout, stderr, signal: r.signal ?? null };
}

function launchBackground({ prompt, cwd, effort, write }) {
  // Launch only spawns the job and prints its id; a minute is generous. Bounded
  // for the same reason the poll slices are: nothing above this call can stop it.
  const { code, stdout, stderr, timedOut } = runCompanion(buildLaunchArgs({ prompt, cwd, effort, write }), cwd, 60000);
  let jobId;
  try { jobId = JSON.parse(stdout).jobId } catch { jobId = null }
  // A launch that timed out may still have spawned the job and printed its id
  // before we killed the companion. Surface that id: without it the job runs on
  // with nobody able to attach to it or kill it.
  if (timedOut && jobId) throw new Error(`Launch timed out but the job started — re-attach or kill it: ${jobId}`);
  if (code !== 0) throw new Error(`Launch failed: ${stderr || stdout}`);
  if (!jobId) throw new Error(`No jobId in launch output: ${stdout}`);
  return jobId;
}

function waitLoop(jobId, cwd, wallCapMs = WALL_CAP_MS) {
  // Two clocks, whichever elapses first: performance.now() ignores a wall-clock
  // step but pauses across suspend on Linux, Date.now() is the reverse.
  const startMono = performance.now(), startWall = Date.now();
  const elapsed = () => Math.max(performance.now() - startMono, Date.now() - startWall);
  const SAFETY_MS = 5000; // never let a slice run past wallCapMs (keeps total < Claude's Bash timeout)
  let unknownStreak = 0;
  while (true) {
    const remaining = wallCapMs - elapsed();
    if (remaining <= SAFETY_MS) return "running"; // graceful: caller re-attaches
    const slice = Math.min(POLL_TIMEOUT_MS, remaining - SAFETY_MS);
    // Hard bound one slice above what the companion was asked to wait, so a slice
    // that stops returning costs one backoff, not the whole call.
    const { code, stdout, stderr } = runCompanion(
      ["status", jobId, "--wait", "--timeout-ms", String(slice), "--json", "--cwd", cwd], cwd, slice + SAFETY_MS);
    let status = "unknown";
    // Only a companion that exited cleanly is allowed to state the job's status.
    // A failed or signal-killed one can still print parseable stale JSON, and
    // accepting it would let "completed" arrive from a process that completed
    // nothing.
    if (code === 0) {
      try { status = JSON.parse(stdout).job?.status ?? "unknown"; } catch { /* launch race: job file not ready */ }
    }
    if (status !== "running" && status !== "queued" && status !== "unknown") return status;
    if (status === "unknown") {
      if (++unknownStreak >= 5) throw new Error(`Job ${jobId} status unresolved after retries. Last stderr: ${stderr || "(none)"}`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 800); // brief backoff, no sleep import
    } else {
      unknownStreak = 0;
    }
  }
}

function fetchResult(jobId, cwd) {
  // Bounded like the poll slices: a wedge here would hang after the job already
  // finished, which looks identical to a slow model and has nothing above it to
  // stop it. 60s is generous for reading a finished job's stored result.
  const { code, stdout, stderr } = runCompanion(["result", jobId, "--json", "--cwd", cwd], cwd, 60000);
  if (code !== 0) throw new Error(`Result fetch failed (exit ${code}) for ${jobId}: ${stderr || stdout}`);
  const j = JSON.parse(stdout);
  // A stored job with no result is not an empty answer — it is a missing one.
  // `?? {}` plus `status ?? 0` used to render that as "" with exit 0, which is a
  // clean-looking pass for a job nobody can show output from.
  const res = j.storedJob?.result;
  const text = res?.rawOutput || j.storedJob?.rendered || "";
  // Test the text, not the container: `result: {}` is truthy, so the old
  // `!res && !text` let an empty answer through with status 0 — the exact silent
  // pass this guard exists to stop.
  if (!text) throw new Error(`Job ${jobId} has no stored result to read`);
  return { text, status: res?.status ?? 0 };
}

const START_MONO = performance.now(), START_WALL = Date.now();

function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o.selftest) { runSelftest(); process.exit(0); }

  if (!o.attach && !o.prompt) {
    console.error('Usage: node cdx-sol.mjs [--tier quick|normal|deep] [--cwd <path>] [--allow-write] [--attach <jobId>] "<prompt>"');
    process.exit(2);
  }

  let jobId;
  if (o.attach) {
    jobId = o.attach;
  } else {
    jobId = launchBackground({ prompt: o.prompt, cwd: o.cwd, effort: tierToEffort(o.tier), write: o.write });
  }

  // The advertised bound is the whole process, not the poll loop: a 60s launch
  // plus a 540s poll plus a 60s result fetch is 660s, past the 600s a foreground
  // caller allows. Spend what the launch already used, and keep a fetch reserve.
  const startupElapsed = Math.max(performance.now() - START_MONO, Date.now() - START_WALL);
  const pollCap = WALL_CAP_MS - startupElapsed - 60000;
  // No floor. Clamping an exhausted budget up to 10s bought one more poll slice
  // *past* the advertised bound — waitLoop restarts its own clock from zero, so
  // the 10s was spent on top of the launch, not inside the cap. With nothing
  // left, the job is running and the caller re-attaches.
  const status = pollCap > 0 ? waitLoop(jobId, o.cwd, pollCap) : "running";
  if (status === "running") {
    console.log(`SOL_STILL_RUNNING ${jobId}`);
    console.log(`Still working after ${Math.round(WALL_CAP_MS / 60000)}min. Re-attach: node cdx-sol.mjs --attach ${jobId} --cwd "${o.cwd}"`);
    // Exit 3, not 0: the job did not finish, and a caller that only looks at the
    // exit status would otherwise record an unfinished review as a completed one.
    process.exit(3);
  }

  const { text, status: exitStatus } = fetchResult(jobId, o.cwd);
  const guarded = guardOutput(text, o.cwd, o.offloadChars);
  process.stdout.write(guarded.rendered + "\n");
  if (status !== "completed" || exitStatus !== 0) {
    console.error(`\n[SOL job ${jobId} status=${status} exit=${exitStatus}]`);
    process.exit(1);
  }
  process.exit(0);
}

try {
  main();
} catch (e) {
  console.error(`cdx-sol error: ${e.message}`);
  process.exit(2);
}

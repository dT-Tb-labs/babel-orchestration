# Why Go CLIs fail inside Claude Code's sandbox on macOS

Measured on macOS 26 (Darwin 25.5.0), Claude Code 2.1.220, `gh` 2.x (Homebrew),
`agy` 1.1.8. Everything below is an A/B run, not a reading of the source.

## The symptom

Any Go binary doing TLS inside the sandbox fails:

```
Get "https://api.github.com/rate_limit": tls: failed to verify certificate: x509: OSStatus -26276
```

`curl` to the same host from the same sandbox succeeds, so this is not the
domain allowlist and not the network proxy — it is specific to Go.

## The mechanism

Go's `crypto/x509` on macOS calls `SecTrustEvaluateWithError()`, which evaluates
the chain by talking to a trust daemon over Mach IPC. Deny that Mach lookup and
the evaluation aborts with `errSecInternalComponent` (`OSStatus -26276`) — the
chain is never judged invalid, it is never judged at all. `SSL_CERT_FILE` cannot
help, because the failure is in the IPC, not in the root store.

This much was already diagnosed in
[anthropics/claude-code#34876](https://github.com/anthropics/claude-code/issues/34876)
(closed as not planned, no maintainer response). That issue proposes a one-line
fix:

```scheme
(allow mach-lookup (global-name "com.apple.trustd"))
```

**That name is the wrong one.** It does not restore TLS.

## Which Mach service is actually required

Reproduce with `sandbox-exec` directly — a profile of `(allow default)` plus one
`deny` isolates a single variable:

| profile | `gh api rate_limit` |
|---|---|
| `(deny mach-lookup (global-name "com.apple.trustd"))` | works |
| `(deny mach-lookup (global-name "com.apple.trustd.agent"))` | **`OSStatus -26276`** |
| `(deny mach-lookup)` | **`OSStatus -26276`** |
| `(deny mach-lookup)` + allow `com.apple.trustd` | **`OSStatus -26276`** |
| `(deny mach-lookup)` + allow `com.apple.trustd.agent` | works |
| `(deny mach-lookup)` + allow both | works |

**`com.apple.trustd.agent` is necessary and sufficient. `com.apple.trustd` is
neither.** Denying only `com.apple.trustd` changes nothing, because the
per-user agent still answers.

Minimal profile that restores Go TLS with every other Mach lookup denied:

```scheme
(version 1)
(allow default)
(deny mach-lookup)
(allow mach-lookup (global-name "com.apple.trustd.agent"))
```

## TLS is not the whole story for every CLI

`gh` reads its token from a config file, so trust evaluation was its only Mach
dependency. `agy` reads credentials from the keychain, and under the profile
above it silently falls back to an interactive OAuth login instead of failing
loudly. Adding the keychain services fixes it:

```scheme
(version 1)
(allow default)
(deny mach-lookup)
(allow mach-lookup (global-name "com.apple.trustd.agent"))
(allow mach-lookup (global-name "com.apple.SecurityServer"))
(allow mach-lookup (global-name "com.apple.secinitd"))
```

With that, `agy --mode plan --sandbox -p "…" < /dev/null` returns its answer
from inside the sandbox. (Not minimized further — one of the two keychain names
may be redundant.)

## What this costs, honestly

`com.apple.trustd.agent` grants certificate trust evaluation. Whether a
sandboxed process can also *write* user trust settings through it — installing a
root CA and thereby setting up later interception — is **untested here**, and it
is the risk to check before treating this as safe.

The keychain services are a different matter and much less comfortable:
`com.apple.SecurityServer` is how a process reaches the user's keychain. Granting
it to run one CLI hands that CLI, and anything it executes, the credential store.
Do not add it casually; the TLS-only grant is the one worth having.

Compare with what Claude Code offers today:

- **`excludedCommands`** — the command runs with no sandbox at all. Strictly
  broader than one Mach service.
- **`enableWeakerNetworkIsolation`** — per the official docs, the remedy when
  using a MITM proxy with a custom CA; it relaxes the boundary for *every*
  sandboxed command, not just the Go one.

So the narrow grant is better than both. It is also not reachable: Claude Code's
sandbox settings expose `allowUnixSockets`, but nothing for Mach lookups, so
there is no way to ask for it from `settings.json`. Until there is,
`excludedCommands` on a small named shim — which is what this repo does for
`agyask` and `solask` — stays the practical answer, and the README section
"What the sandbox exclusion costs you" describes what that gives up.

## Reproducing

```bash
cat > /tmp/deny.sb <<'EOF'
(version 1)
(allow default)
(deny mach-lookup (global-name "com.apple.trustd.agent"))
EOF
sandbox-exec -f /tmp/deny.sb gh api rate_limit    # x509: OSStatus -26276

cat > /tmp/allow.sb <<'EOF'
(version 1)
(allow default)
(deny mach-lookup)
(allow mach-lookup (global-name "com.apple.trustd.agent"))
EOF
sandbox-exec -f /tmp/allow.sb gh api rate_limit   # works
```

`sandbox-exec` is deprecated but still present, and it cannot be nested inside
Claude Code's own sandbox — run these from a plain terminal.

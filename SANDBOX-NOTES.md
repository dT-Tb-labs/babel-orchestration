# Go CLIs and TLS inside Claude Code's macOS sandbox

Measured on macOS 26 (Darwin 25.5.0), Claude Code 2.1.220, `gh` 2.x, `agy` 1.1.8.
Every claim below is either an A/B run or a line of
[`sandbox-runtime`](https://github.com/anthropic-experimental/sandbox-runtime)
source, not inference.

## Symptom

Any Go binary doing TLS inside the sandbox fails:

```
Get "https://api.github.com/rate_limit": tls: failed to verify certificate: x509: OSStatus -26276
```

`curl` to the same host from the same sandbox returns normally, so this is
neither the domain allowlist nor the proxy — it is specific to Go.

## Mechanism

Go's `crypto/x509` on macOS evaluates chains with `SecTrustEvaluateWithError()`,
which reaches the trust agent over Mach IPC. Deny that lookup and evaluation
aborts with `errSecInternalComponent` (`OSStatus -26276`): the chain is not
judged invalid, it is never judged at all. `SSL_CERT_FILE` cannot help, because
the failure is in the IPC and not in the root store.

Already diagnosed in
[anthropics/claude-code#34876](https://github.com/anthropics/claude-code/issues/34876)
(closed as not planned). That issue proposes allowing `com.apple.trustd`.

**That is the wrong service name.** Isolated with `sandbox-exec`, one variable
per profile over `(allow default)`:

| profile | `gh api rate_limit` |
|---|---|
| deny `com.apple.trustd` | works |
| deny `com.apple.trustd.agent` | **`OSStatus -26276`** |
| deny all mach-lookup | **`OSStatus -26276`** |
| deny all, allow `com.apple.trustd` | **`OSStatus -26276`** |
| deny all, allow `com.apple.trustd.agent` | works |

`com.apple.trustd.agent` is necessary and sufficient; denying `com.apple.trustd`
changes nothing because the per-user agent still answers. The upstream library
already uses the correct name — only the issue's proposed one-liner is wrong.

## What the setting actually does

In `sandbox-runtime`'s `macos-sandbox-utils.ts`, `enableWeakerNetworkIsolation`
has exactly one effect on the generated profile:

```
; trustd.agent - needed for Go TLS certificate verification (weaker network isolation)
(allow mach-lookup (global-name "com.apple.trustd.agent"))
```

That is the whole of it on macOS. **The name oversells the grant**: it opens no
port, no host, and no file — it lets the OS evaluate a certificate. The
"network" framing presumably refers to trustd's own OCSP/CRL fetches being a
theoretical low-bandwidth side channel, which is worth knowing but is not what
the name suggests.

Two related things the same file settles:

- `com.apple.SecurityServer` is allowed **unconditionally**, so keychain access
  is not gated by this flag. (An earlier version of this note claimed otherwise,
  from an over-strict hand-written test profile rather than the real one.)
- The library also accepts `allowMachLookup`, an arbitrary list of Mach services
  with wildcard support — the precise, general escape hatch.

## State on Claude Code 2.1.220

| setting in `~/.claude/settings.json` | effect on `gh` in the sandbox |
|---|---|
| `sandbox.enableWeakerNetworkIsolation: true` | **works** — the flag is wired |
| `sandbox.allowMachLookup: ["com.apple.trustd.agent"]` | **no effect** — not honoured |

So [#28954](https://github.com/anthropics/claude-code/issues/28954), which
reports `enableWeakerNetworkIsolation` as not wired through, no longer
reproduces here. The remaining gap is `allowMachLookup`: the library supports it,
the CLI does not pass it through, and it is the one that would let a user grant
exactly `com.apple.trustd.agent` and nothing else.

## Which workaround to prefer

For a Go CLI that only needs TLS — `gh`, `terraform`, `tofu`, `gcloud` —
`enableWeakerNetworkIsolation: true` is **narrower than `excludedCommands`**,
despite the scarier name. Compare what each grants:

| | grant | scope |
|---|---|---|
| `enableWeakerNetworkIsolation` | one Mach service | every sandboxed command |
| `excludedCommands` | no sandbox at all | the named commands |

Neither dominates: one is a tiny grant applied broadly, the other a total grant
applied narrowly. For trust evaluation specifically the first looks like the
better trade, and it is the one this repo would use if the tools involved needed
nothing else.

`agy` needs more than TLS. With the trustd grant active it gets past the
certificate error and then fails on `listen tcp 127.0.0.1:0: bind: operation not
permitted` — it starts a local language server. Running it fully sandboxed would
take `enableWeakerNetworkIsolation` **plus** `network.allowLocalBinding`, plus
its Google domains in `allowedDomains`, plus the `< /dev/null` stdin detach the
shim already does. That is three global relaxations to sandbox one CLI, which is
why `agyask` + `excludedCommands` remains this repo's default — see the README
section "What the sandbox exclusion costs you".

## Can the grant be abused to install a root CA?

The obvious worry is that a process allowed to reach the trust agent could also
*write* trust settings — install its own root and set up later interception.
Tested with a throwaway self-signed cert and `security add-trusted-cert -r
trustRoot`, user domain:

| where | result |
|---|---|
| outside the sandbox | blocks on a **SecurityAgent authorization dialog** — a human has to approve |
| inside the narrow profile (only `trustd.agent` allowed) | fails immediately, no dialog, nothing written |

Nothing landed in the trust store in either case. So the grant does not enable a
silent root-CA install: the write path goes through interactive authorization,
and inside the sandbox that path is not reachable at all. The in-sandbox failure
surfaces as `SecTrustSettingsSetTrustSettings: errSecParam`, which is an odd code
for "no authorization path", so treat the *mechanism* as unconfirmed — the
*behaviour*, no prompt and no write, is what was measured.

Still worth stating plainly: this was tested on the narrow hand-written profile.
Under Claude Code's real profile, which allows `com.apple.SecurityServer` and
`com.apple.securityd.xpc` unconditionally, a dialog may well appear instead. A
dialog is still not a silent compromise.

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

`sandbox-exec` is deprecated but present, and cannot nest inside Claude Code's
own sandbox — run these from a plain terminal.

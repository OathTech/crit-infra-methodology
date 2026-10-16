# Standing instructions — critical-infrastructure audits

This workspace holds security-audit forks that may contain working reproducers for **unfixed**
defects in shipping industrial-control software. Anything that leaves this machine is a
disclosure decision. These rules apply to the agent and to **every subagent, teammate, and
workflow agent** spawned here.

## Read-only to the outside world

**Never write to anything outside this machine. Reading is always fine.**

| Allowed (read) | Forbidden (write) |
|---|---|
| `git fetch`, `git pull`, `git clone`, `git ls-remote` | `git push`, `git remote add`/`set-url`, `git send-email` |
| `WebFetch`, `WebSearch`, `curl`/`wget` plain GET or HEAD | Any POST/PUT/PATCH/DELETE: `curl -X`/`-d`/`-F`/`-T`, `wget --post-*` |
| Reading issues, PRs, advisories, CVE databases in a browser or via fetch | Filing or commenting on an issue or PR; `gh`/`glab` writes of any kind |
| Reading a mailing-list archive | Sending mail to a maintainer, vendor, list, or coordinator |
| — | Requesting a CVE; submitting to CERT/CC or CISA; publishing a repro anywhere |

**Preparing a disclosure is the deliverable. Sending it is a human decision, always.** Finish the
package, report that it is ready, and stop. The same applies to pushing: commit locally, then give
the operator the exact commands — they push themselves.

If a task appears to require an external write, stop and say so rather than finding a way around
it. A hook, a script, an MCP tool, or a `|`/`eval`/subshell that performs the write is still the
write; this rule is about the effect, not the spelling of the command.

The `deny` rules in [.claude/settings.json](.claude/settings.json) enforce the common cases. They
are a backstop, not the boundary — the rule above is the boundary.

## Your setup

| | |
|---|---|
| `AUDIT_ROOT` | Absolute path to the workspace that holds the audit forks — by default, this repository's checkout |
| `AUDIT_ORCH` | `$AUDIT_ROOT/.orchestrator`, or wherever this repository's `.orchestrator/` lives |

```bash
export AUDIT_ROOT="$HOME/audits"              # this directory
export AUDIT_ORCH="$AUDIT_ROOT/.orchestrator" # used by run-esbmc.sh and the slot scripts
```

Put those in your shell profile. `.orchestrator/bin/*` self-locate and work without `AUDIT_ORCH`;
the ESBMC driver template needs it to find the heavy slot, and warns and runs unserialized if it
is unset.

If this repository is not the workspace root (for example, it is cloned into a larger private
workspace), point `AUDIT_ROOT` at the workspace and `AUDIT_ORCH` at this checkout's
`.orchestrator/`.

## Git identity

Every repository created here — each audit fork, and this one — gets a **local** `user.email` of
the address you want on audit commits. The machine's global identity is often a personal
address, which a fresh clone silently inherits; the mistake is only visible once commits exist.

```bash
git -C <repo> config --local user.email "you@example.org"
```

- Set **`user.email` only.** Leave `user.name` unset so it inherits your global name. An agent
  once set a local `user.name` to its own task description, which would have authored every later
  commit in that repo under a junk identity.
- **Never `git config --global` anything in this workspace.** Concurrent agents share it, so a
  global write changes every other agent's commit identity mid-run. Use `--local`, or
  `git -c user.email=... commit` for a one-off.
- Add your agent's co-author trailer to commits it authors.

## Audit methodology

Agents running an audit must also follow
[.orchestrator/AGENT_CONTRACT.md](.orchestrator/AGENT_CONTRACT.md) — phase gates, the
instrumentation gate, the re-diff gate against live upstream, the provenance check (is this file
generated? vendored? duplicated in a sibling port?), and Phase 8 package self-verification.

**That contract is the cross-project memory, and keeping it current is a deliverable.** Whenever
work here produces a lesson that would help a future audit of a *different* target — a gate that
passed when it shouldn't have, a tool default that silently produces wrong numbers, a technique
that unblocked something — it goes into `AGENT_CONTRACT.md`, not just into the conversation.
Agents emit a `CONTRACT-DELTA` block at Phase 7; the orchestrating session merges them between
waves. This is deliberate: propagating lessons through a checked-in file costs cents, while
propagating them through one long supervising conversation was measured at roughly five times the
cost of the audits themselves.

The contract is **target-agnostic by design** — it names no project, file, symbol, or ticket.
Findings live in each fork's `BUGS.md` and `VERIFICATION.md`. Lessons come here.

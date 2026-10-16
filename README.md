# Critical-infrastructure audit methodology

A methodology for running coding agents through credible security audits of open-source C and
C++ protocol stacks — SCADA telemetry, substation automation, metering, EV charging — using
fuzzing, bounded model checking, and TLA+, on an ordinary workstation.

It was developed during a series of audits of ten open-source grid protocol stacks that produced
thirty confirmed defects for about $500 of audit work. The write-up,
[*Finding Power-Grid Bugs for Tens of Dollars*](blog/finding-grid-bugs-for-tens-of-dollars.md),
is in this repository: what was audited, what was found, what it cost, and how the tools and
agents fit together.

The aim: **a utility engineer, a grid operator's software team, or a vendor's own developers can
run a credible audit of the protocol libraries they depend on, without expertise in security
research or formal methods.** The agent builds the fuzzers, writes the model-checking harnesses,
and drafts the TLA+ models. The contract tells it, and you, what counts as a real result. You
review the findings and decide what to send.

## What's here

| Path | What it is |
|---|---|
| [blog/](blog/) | The write-up of the audit series this methodology came from. |
| [CLAUDE.md](CLAUDE.md) | Standing instructions, auto-loaded by [Claude Code](https://docs.claude.com/en/docs/claude-code) and inherited by every agent spawned here: the read-only-to-the-outside-world rule, git identity, a pointer to the contract. |
| [.claude/settings.json](.claude/settings.json) | Harness-enforced `deny` rules backing the read-only rule — an agent can prepare a disclosure but cannot push, file, or POST one. |
| [.orchestrator/AGENT_CONTRACT.md](.orchestrator/AGENT_CONTRACT.md) | The audit contract: a phase-by-phase playbook from cloning a library to a disclosure package, with an exit gate and time budget per phase — the KILL gate, instrumentation gate, re-diff gate, provenance check, Phase 8 package self-verification, SEV-STOP, and report format. |
| [.orchestrator/bin/](.orchestrator/bin/) | Machine-wide resource serialization so several audits can share one machine: `flock`-based fuzz and heavy slots, FIFO ticketing, a fuzz-wave runner, and a memory watchdog — plus `check-prereqs.sh`, which checks that a machine is ready. |
| [.orchestrator/templates/](.orchestrator/templates/) | A sanitizer-and-coverage libFuzzer build script with a built-in instrumentation gate, and an ESBMC driver that runs a library's harnesses in tiers. |

The contract is written for Claude Code but is plain Markdown; other agent harnesses can load it
the same way. The scripts are plain Bash.

## Setting up

You don't need to know how to build or install these tools yourself. Claude Code can do most of
the setup for you, and a checker script confirms when everything is in place.

### 1. Get a Linux environment

Use a Linux machine, or a Linux-based Docker container on macOS or Windows. With
[Docker Desktop](https://www.docker.com/products/docker-desktop/) installed, this starts an Ubuntu
container with a folder on your computer shared into it:

```bash
docker run -it --name audits -v "$HOME/audits:/audits" -w /audits ubuntu:24.04 bash
apt-get update && apt-get install -y curl git     # inside the container: the minimum for step 2
```

To come back to the same container later: `docker start -ai audits`.

In Docker Desktop's settings, give the container as many CPUs and as much memory as you can
spare: 8 CPUs and 8 GB is the reference setup, and 4 CPUs and 6 GB is a workable minimum.

### 2. Install Claude Code and get this repository

Follow the [Claude Code install instructions](https://docs.claude.com/en/docs/claude-code) for
Linux, then:

```bash
git clone https://github.com/OathTech/crit-infra-methodology.git ~/audits && cd ~/audits
```

(Inside the Docker container above, clone into `/audits` instead.)

### 3. Ask Claude Code to install the rest

Start `claude` in the repository folder and paste this prompt:

> Set up this machine to run audits with this repository. This is a one-time setup task, not an
> audit, so installing packages is allowed. Ask me before each command that installs software or
> uses sudo.
>
> 1. Run `.orchestrator/bin/check-prereqs.sh` and read what it reports.
> 2. Install everything it marks MISSING, using this system's package manager. For ESBMC, use a
>    release binary from https://github.com/esbmc/esbmc/releases if one exists for this CPU
>    architecture; if not, build it from source into `./esbmc/` following ESBMC's build
>    documentation, and tell me first how long and how much disk space that will take.
> 3. Also install the optional TLA+ tools (a Java runtime, and `tla2tools.jar` from
>    https://github.com/tlaplus/tlaplus/releases into `./formal-tools/`).
> 4. Add `AUDIT_ROOT` and `AUDIT_ORCH` to my shell profile, plus `FUZZ_CORES` and `HEAVY_CPUS` if
>    the checker says this machine needs them.
> 5. Run the checker again and repeat until it prints "Ready". Then summarize what you installed
>    and what changed in my shell profile.

The checker installs nothing, so you can also run it yourself at any time:

```bash
.orchestrator/bin/check-prereqs.sh
```

<details>
<summary>What the checker looks for, if you'd rather install things by hand</summary>

- Linux. The slot scripts use `flock`, `taskset`, and `timeout` from util-linux and coreutils.
- `clang` that can build and run a fuzzer with AddressSanitizer and UndefinedBehaviorSanitizer.
  On Debian and Ubuntu that is the `clang` and `libclang-rt-dev` packages. Also `cmake` and `make`.
- `git`, `curl`, `jq`
- [ESBMC](https://github.com/esbmc/esbmc): an `esbmc` on your `PATH`, a build in
  `$AUDIT_ROOT/esbmc/`, or a path in `$ESBMC`
- Optional, for Phase 6: Java and `tla2tools.jar` (TLA+ / TLC) in `$AUDIT_ROOT/formal-tools/`
- `AUDIT_ROOT` (this folder) and `AUDIT_ORCH` (`$AUDIT_ROOT/.orchestrator`) in your shell profile
- 8 or more cores, or `FUZZ_CORES` and `HEAVY_CPUS` set to two separate sets of cores, e.g.
  `FUZZ_CORES="0 1"` and `HEAVY_CPUS=2-3` on 4 cores (see the contract's *Shared, serialized
  resources*)

</details>

## Running an audit

Read [CLAUDE.md](CLAUDE.md), then start `claude` in this folder and point it at a library:

> Audit `<library>` (`<clone URL>`) following `.orchestrator/AGENT_CONTRACT.md`. Work in
> `$AUDIT_ROOT/<name>-verified/`. Stop at the end of Phase 1 and report the KILL-gate result.

Run one phase per session; phases hand off through files on disk, not through a growing
conversation. That keeps an audit in the tens of dollars.

Audit forks live inside the workspace as `<name>-verified/` and are ignored by this repository's
allowlist-shaped `.gitignore`, so a fork can never be committed here by accident. Give each
fork its own private remote, if any.

## Why the contract is a checked-in file

`AGENT_CONTRACT.md` is the **cross-project memory**. Every gate in it exists because an earlier
audit paid for it:

- The **re-diff gate** cost a fully drafted disclosure for a bug the vendor had fixed twelve days
  earlier under an internal ticket with no public trace.
- The **instrumentation gate** silently invalidated two complete fuzzing campaigns before it was
  written down.
- The **provenance check** was learned one hour before a report would have recommended a fix to
  generated code, which the next regeneration reverts.

The alternative way to carry lessons between audits is one long-running supervising
conversation that remembers everything. That was measured at roughly **five times the cost of
the audits it supervised**, with 97% of its tokens spent re-reading its own context. A contract
that every agent reads at Phase 0 carries the same lessons for the price of reading 400 lines.

Agents emit a `CONTRACT-DELTA` block at Phase 7; merging those back is how the contract improves.
See [CONTRIBUTING.md](CONTRIBUTING.md) to send yours upstream.

### Target-agnostic by design

The contract carries **the method and the traps, never the findings**. It names no project, file,
symbol, issue, or CVE. Each gate still states what it cost — a gate stripped of its consequence
gets skipped under time pressure — but without the identifier.

Two reasons. A contract that names one target reads as history to an agent auditing another; the
traps generalise, the targets do not. And finding specifics in a methodology document are a
disclosure leak: a file name plus an expression can be enough to locate an unpatched defect.

Findings belong in each fork's `BUGS.md` and `VERIFICATION.md`. Lessons belong here.

## Disclosure

Everything here is **read-only to the outside world**. Reading upstream, advisories, and trackers
is unrestricted; `git push`, issue filing, CVE requests, and sending a prepared report are human
decisions, never agent ones. Report what you find to maintainers privately, through the route the
contract's Phase 1 identifies. See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Maintained by [Oath Technologies](https://oath.tech/).

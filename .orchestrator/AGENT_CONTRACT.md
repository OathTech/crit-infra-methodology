# Agent operating contract — upstream protocol-stack audits

You are auditing **one** upstream C library for memory-safety and protocol-logic defects.

This document is deliberately **target-agnostic**: it carries the method and the traps, not the
history. Every gate below was paid for by a real audit, and the cost is stated because a gate
without its consequence gets skipped under time pressure — but the projects, files, and ticket
numbers behind each one live in the relevant fork's `BUGS.md` and `VERIFICATION.md`, which is
their proper home. Findings stay in the fork; lessons come here.

If the workspace already holds completed audit forks, read one end-to-end before starting —
ideally one that came back clean and one that produced findings. They are the house style, and
imitation-plus-citation is how these conventions propagate. On a first audit, this contract and
the templates in `.orchestrator/templates/` are the house style.

## Your directory

`$AUDIT_ROOT` is the workspace root and `$AUDIT_ORCH` is this repository's `.orchestrator/` (see
`CLAUDE.md` → *Your setup*). You own exactly one path:
`$AUDIT_ROOT/<name>-verified/`. Everything else under `$AUDIT_ROOT` — sibling forks, `esbmc/`,
`formal-tools/`, other agents' directories — is **read-only reference**. Never write outside
your own tree.

## Git identity — set this the moment you create the fork (Phase 0)

Immediately after cloning, before any commit, set the fork's **local** `user.email` to your own
address, as `CLAUDE.md` → *Git identity* specifies. Set `user.email` only; never `user.name`, and never
`git config --global` anything — concurrent agents share the global config.

That rule and its rationale live in `CLAUDE.md` because they apply to everyone working in this
workspace, not only to audits. It is restated here only because Phase 0 is where getting it wrong
becomes expensive: the error is invisible until commits already exist.

## Shared, serialized resources

The reference configuration is three concurrent agents on one 8-core / 7.8 GB machine with no
cgroups, and the slot scripts default to it: fuzz waves on cores 0-3, everything heavy on cores
4-7. On different hardware set `FUZZ_CORES` (space-separated list, one harness per core) and
`HEAVY_CPUS` (a `taskset` list) to two disjoint core sets, and scale `BUILD_JOBS` and the load
threshold below to match. Fuzzing is globally serialized.

```bash
# fuzz wave (FUZZ_CORES, one harness per core) -- FIFO-fair, machine-wide exclusive
AGENT_NAME=<proj> $AUDIT_ORCH/bin/fuzz-slot.sh \
    <build-fuzz-dir> <triage|graded> <harness>...

# build / ESBMC / TLC (HEAVY_CPUS, nice 10) -- machine-wide exclusive
$AUDIT_ORCH/bin/heavy-slot.sh <timeout-secs> <command>...
```

- Everything cheap — cloning, reading code, writing harnesses, CVE audit, documentation —
  runs **unrestricted and fully concurrent**. Spend your wall clock there.
- Builds: `BUILD_JOBS=4`, never `-j$(nproc)`.
- Campaigns exceed the foreground command ceiling. Run them **backgrounded** and poll the log.
- Before starting any wave or ESBMC run, check `uptime`. If 1-minute load > 6.0 (on 8 cores), wait.
- Exit 3 from a wave means **WAVE INVALID** (memory starvation): re-run it, and do not report
  its numbers. Exit 77 means a harness found something: go to SEV-STOP below.

## Phases

| # | Phase | Budget | Exit gate |
|---|---|---|---|
| 0 | Fork & baseline | 0.5 h | Clone SHA **and** `upstream/<default>` live-head SHA recorded; **local git identity set** (below); baseline committed locally |
| 1 | **Triage / KILL gate** | 1.5 h | `TRIAGE.md` with six answers + GO/KILL + disclosure route |
| 2 | Build, test, surface map | 3 h | Builds; test result verbatim; ≥2 ranked targets with production call sites |
| 3 | Prior-art & upstream delta | 3 h | Every CVE resolved; live-head delta manifest captured and dated; **provenance check done** (below) |
| 4 | Fuzzing | 8 h | **Instrumentation gate PASS**; ≥2 harnesses to campaign or documented stop rule |
| 5 | ESBMC | 6 h | `run-esbmc.sh` clean or documented expected-fails; empty subdirs justified |
| 6 | TLA+ (conditional) | 6 h | Only if ≥3 entry criteria hold |
| 7 | Deliverables | 3 h | `BUGS.md` + `VERIFICATION.md`, every number traceable to a logged run; **`CONTRACT-DELTA` emitted or explicitly "none"** |
| 8 | Disclosure packaging (conditional) | 4 h | Both gates re-run and dated; **package self-verification passed** (below); package prepared, **never sent** |

### Phase 1 — the KILL gate (highest-leverage phase; spend 90 min instead of 3 days)

Answer with evidence, not impressions:
1. Where does attacker-controlled wire data first enter library code? (file, function, and the
   production call site `file.c:line`). No untrusted path ⇒ no target.
2. How large is the parse surface? SLOC of wire-facing decode; count variable-length fields,
   length-driven loops, length-driven `memcpy`.
3. Is it already continuously fuzzed? In-tree `fuzz/`, OSS-Fuzz entry, CI fuzzing. If yes, map
   existing harnesses onto (1) and identify what is **not** covered.
4. Already audited? Third-party report, CVE history showing a professional pass.
5. Liveness and disclosure route: `SECURITY.md`? private vulnerability reporting? commits in the
   last 90 days? → Route A (vendor private) / B (SECURITY.md contact) / C (dormant → CERT/CC +
   CISA) / D (none; document only).
6. Is this a fork/re-implementation of a codebase a sibling project already covered?

**KILL on**: K1 no untrusted input path · K2 trivial surface (<~500 SLOC, no length-driven loops
→ downgrade to an ESBMC-only micro-pass, not an outright kill) · K3 saturated existing fuzzing
covering every entry point · K4 published audit within ~18 months · K5 structural duplicate of a
sibling · K6 dormant **and** no downstream embedders.

K6's inverse matters: dormant *with* real downstream embedding is the highest-yield profile, which
produced two confirmed defects in the first hour. Dormancy alone is not a kill.

**A KILL is a successful outcome.** Report `STATUS: KILL`, rename the directory
`<name>-triage/`, stop. Do not pad a weak target into a full campaign.

### Phase 4 — instrumentation gate (blocking, non-negotiable)

```bash
nm build-fuzz/lib<name>.a | grep -c __sancov_gen                        # symbol check
objdump -h build-fuzz/lib<name>.a | grep -cE '__sancov_cntrs|__sancov_pcs'   # SECTION check
./build-fuzz/bin/<harness> -runs=0 2>&1 | grep "Loaded 1 modules"       # runtime counters
```

PASS requires: (`__sancov_gen` > 0 **or** sancov sections > 0), **and** instrumented/harness-only
counter ratio ≥ 10, **and** ≥ 200 counters (waive the absolute floor only for a genuinely tiny
library, keeping the ratio). Put every number in `VERIFICATION.md` verbatim.

**Why two symbol checks.** `nm | grep __sancov_gen` alone gives **false negatives**: clang emits
those named symbols only in some contexts (notably functions carrying switch value tables), so a
small or switch-free translation unit can be fully instrumented and still report zero. This was
hit for real on a tiny, switch-free TU whose `objdump` output showed genuine `__sancov_cntrs` /
`__sancov_pcs` sections plus the `.text.sancov.module_ctor_8bit_counters` registration
constructor. The section check and the runtime counter ratio are the authoritative signals; the
symbol count is corroboration only. Never fail a build on the symbol count alone, and never pass
one on it alone either.

**No coverage or campaign number may be reported, logged, or written down from a build that has
not passed this gate.** If you already ran one, strike its numbers and re-run from a clean
rebuild. This bug happened twice before and silently invalidated everything.

Campaign discipline: 120 s triage wave first. A harness earns a graded 1800 s slot only if it
clears **both** admission tests:

1. **Throughput** — sustains > 1000 exec/s. (A prior harness ran at 21 exec/s and consumed a full
   slot.)
2. **Coverage still growing** — `cov:` increased during the *second half* of its 120 s triage
   wave. A harness already flat at the end of triage has saturated its scope and a graded slot
   will buy nothing.

Test 2 exists because throughput alone is not enough: a harness scoped to a small closed decision
tree can run at 925 K exec/s, saturate by execution ~192, and then burn a full graded slot running
flat for 99.99999% of 1.67 **billion** executions. That is not a broken harness — a shallow
harness over a shallow entry point is legitimate and worth having — but it needed 2 minutes, not
30. Record its plateau from the triage wave and move the slot to a harness with depth left.

Stop a harness when a crash is found, or when `cov:` is flat for the final ≥50% of a run — and say
*why* the ceiling exists (scope genuinely exhausted vs. blocked by an unsatisfied precondition such
as a checksum or length field). Those two causes look identical in the numbers and demand opposite
responses: accept the first, fix the harness for the second. Prove which one it is by reading the
entry point's call graph, not by inferring from the coverage curve.

### Phase 3 — the bug-class sweep gives FALSE NEGATIVES on literal grep

Never report a bug class "absent" on the strength of a literal-pattern grep. A real case from
a prior audit: a Phase 3 sweep explicitly declared the integer-overflow class absent, and Phase 5's
ESBMC run then found exactly that class in the same codebase. The sweep had searched for literal
shapes (`<< 24`, `* 0x1000000`); the actual defect shifted by a **variable** amount —
`<< (n * k)`, where `k` came from a loop counter — which no literal pattern matches.

Sweep by the **operation and its operand provenance**, not by the constant: find every `<<`, `*`,
and `+=` whose operand derives from a wire byte, then read each hit. When you report a class as
absent, state what you searched and acknowledge that a variable shift/multiply amount can hide it.
"Not found by grep" and "not present" are different claims — only make the one you earned.

### Phases 3 & 8a — the re-diff gate (the expensive lesson)

Run at the **start of Phase 3** and again **immediately before handing over any package**:

```bash
git fetch upstream <default>
git diff <clone-commit>..upstream/<default> -- <affected-file>   # empty == byte-identical
git log <clone-commit>..upstream/<default> --oneline -- <affected-file>
git log upstream/<default> -S'<affected-symbol>' --oneline
```

Read commit messages for **internal ticket references** (`PROJ-1234`, `#1234` shapes). Vendors
fix silently under those with no public issue and no advisory — a tracker search structurally
cannot see it, and this cost a prior effort a fully-drafted report for a bug fixed 12 days
earlier. If already fixed upstream: **STOP, do not package**; downgrade the `BUGS.md` entry to
"already fixed upstream in `<commit>` (`<date>`)" and report `PASS-WITH-CAVEAT`.

Phase 8b repeats this against the issue tracker for the **specific function and file name**,
open *and* closed issues.

### Phase 3 — the provenance check: *is this file the original, and is it the only copy?*

The re-diff gate asks "has upstream changed?". This asks the two questions that come before it:
**where does this file actually come from, and where else does it live?** Both have bitten real
audits, in the same week.

**1. Is the file generated?** Look for a generator before you write a patch against the output.

```bash
# (a) banner scan -- BROAD on purpose, see the warning below
grep -rliE "generated|do not (edit|modify)|will be overwritten" <affected-dir>
ls .github/workflows/ | grep -i 'gen\|codegen'      # regeneration in CI
# (b) the authoritative check: does an org generator repo carry this filename as a template?
curl -sS "https://api.github.com/repos/<org>/<generator>/git/trees/main?recursive=1" \
  | jq -r '.tree[].path' | grep -i '<affected-basename>'
```

> **The banner scan is a hint, never a verdict** — and this gate fell into its own trap on first
> use. It was originally written as `grep -rl "DO NOT EDIT\|auto-generated\|@generated"` and
> returned **zero hits on the very file that motivated this section**, because that file says
> *"The Code is generated! Changes may be overwritten."* — wording no literal pattern anticipated.
> This is the Phase 3 literal-grep false negative, committed inside the fix for a different
> literal-grep false negative. The banner wording is arbitrary and may be absent entirely; step
> **(b)**, finding the generator, is what actually settles it. Treat a silent `grep` as *"no
> answer yet"*, never as *"hand-written"*. (Corrected 2026-10-01, same day it was introduced.)

A patch against generated output **is reverted at the next regeneration**. A real case: a report
was one hour from being sent recommending a fix to a decoder source file that turned out to be
rendered from a template in a separate generator repository. The proof it matters was in that
codebase's own history — two earlier findings had been fixed *in the generator* and swept
downstream by a regeneration commit that did not touch the file in question at all. The package
must name the template as the fix site and the generated file as the symptom.

**2. Is the code vendored, or duplicated in sibling ports?** The repo you cloned may not be what
ships, and the same defect often exists in the vendor's other-language implementations.

```bash
# does an active monorepo carry an in-tree copy? is it a submodule or a real directory?
curl -sS "https://api.github.com/repos/<org>/<monorepo>/contents/<vendored-path>" | jq 'type'
# how many copies of the affected file exist there?
curl -sS "https://api.github.com/repos/<org>/<monorepo>/git/trees/main?recursive=1" \
  | jq -r '.tree[].path' | grep '<affected-basename>'
# sibling ports of the same library
curl -sS "https://api.github.com/orgs/<org>/repos?per_page=100" \
  | jq -r '.[]|"\(.name)\t\(.language)\tpushed \(.pushed_at[0:10])\tarchived=\(.archived)"'
```

Audit **what ships**, not what is convenient to clone. Then check the siblings for the same
construct — this found a second affected implementation within an hour of the first. Two rules
when you report a sibling:

- **Language semantics change the verdict.** The same arithmetic is UB in C/C++ and well-defined
  in Java/C#/Python/Go. A C++ sibling taking `long` instead of `int32_t` is UB only where `long`
  is 32-bit (Windows, 32-bit embedded) and *not* on LP64. Say which, don't generalise.
- **Flag it, don't assert it.** If you have not built, run, and reachability-traced the sibling,
  the package says so in those words and presents it as something for the vendor to check. A
  source-inspection observation reported as a confirmed finding is a manufactured finding.

### Phase 6 — TLA+ entry criteria (write a model only if ≥3 hold)

State persists across messages · a sequence number / window / counter with wraparound · a
security-relevant accept/reject decision made from that state · two actors whose interleaving
matters · a spec stating the intended property. Otherwise record the **negative** decision in
`formal/esbmc/README.md` Tier 2 — "checked, not assumed" is the convention.

If you do model: the bridge harness's reference function is transcribed from the **C source, not
from the `.tla`**. That independence is the whole point — a prior model was internally consistent
and silently wrong, and only the independent bridge caught it. Also confirm vacuity (canary
invariants) and run a dedicated sweep at the **real** modulus, which the small grid cannot reach.

### Phase 8 — package self-verification (every item below is a mistake that actually shipped)

A disclosure package is an external artefact under your name. Verify it **mechanically**; do not
eyeball it. Each check exists because its absence produced a real defect in a real report.

**Extract the inlined patch and apply it.** When a patch is pasted into prose, the prose copy is
what the maintainer uses, and it can drift from the `fix.patch` that was tested.

```bash
awk '/^```diff$/{f=1;next} /^```$/{if(f){f=0}} f' report.md > /tmp/inlined.patch
git apply --check /tmp/inlined.patch          # MUST pass
diff /tmp/inlined.patch advisory/<slug>/fix.patch   # header-only differences are fine
```

This caught a hand-edited comment that changed a `+` line count and falsified the `@@` header —
the inlined patch would not have applied. Never hand-edit a patch body; re-generate it.

**Resolve every commit SHA you cite, in the repo you claim it is in.** A report went out the door
asserting a short SHA was "the latest main commit" — that SHA was from a *different* repository
and eleven months old.

```bash
curl -sS "https://api.github.com/repos/<org>/<repo>/commits/<sha>" | jq '.sha // .message'
curl -sS "https://api.github.com/repos/<org>/<repo>/commits/<branch>" | jq -r '.sha[0:7]'
```

Prefer pinning **the last commit that touched the affected file** over the branch head — it is
meaningful and does not go stale hours after you send.

**Verify asserted repo facts rather than recalling them.** `archived`, `has_issues`,
`pushed_at`, whether a `SECURITY.md` exists — all are one API call, and a stale belief about any
of them has already appeared as a false statement in an audit's own write-up.

```bash
curl -sS "https://api.github.com/repos/<org>/<repo>" \
  | jq '{archived,disabled,has_issues,pushed_at,default_branch}'
```

**Rebuild before claiming a reproducer no longer fires.** A stale static library made a genuine
finding report "no crash" and nearly caused a correct finding to be withdrawn. `make clean` (or
delete the build tree) before any negative reproduction result is believed.

**When a package adds evidence, update the `BUGS.md` entry in the same change.** `BUGS.md` is
what every later tally reads, and nobody re-derives it from the advisory directories. A finding
logged as "confirmed via source reading only — not dynamically reproduced" later got a `repro.c`
in its package that crashes under ASan. The package was filed, but the log entry was never
touched. Six weeks later, a series-wide count built from the logs listed that finding as
unreproduced, and a draft public write-up stated the wrong totals. Before closing Phase 8, check
that every package with a reproducer has a log entry that says so:

```bash
ls advisory/*/repro.c 2>/dev/null       # every package that ships a reproducer
grep -n -i -E "source reading only|not dynamically reproduced|not reproduced" BUGS.md
```

Any finding on both lists is stale. Update its **Status** and **Verification** with what the
reproducer shows and what it does not (for example, a standalone extraction rather than the real
build). Do the same when a package adds a patch, a model-checker result or a filing reference.

**Invent no contact address — but do look for a real one.** Where there is no `SECURITY.md`, the
project's own git history is a legitimate private route and is usually conclusive:

```bash
git log upstream/<default> -200 --format='%an <%ae>' | sort | uniq -c | sort -rn
```

A single dominant author address over the last 200 commits is the maintainer's own, taken from
the project rather than guessed — that turned a "no private channel exists, escalate to a
coordinator" assessment into an ordinary private email. State in the package how the address was
obtained, and never post unfixed pre-auth detail to a public forum or tracker.

## SEV-STOP — severe finding mid-campaign

Trigger: (remote-reachable ∧ pre-auth) ∧ (OOB write | UAF | double-free | type confusion | auth
bypass). An OOB read or NULL-deref DoS follows the normal Phase 7 path instead.

Within 15 minutes: freeze the campaign · confirm determinism (`-runs=100`) · minimize
(`-minimize_crash=1`) · then **before believing it**, run the harness-realism check — *could the
real production caller ever produce this `(buffer, length, state)` tuple?* Three of the first seven
projects hit exactly this and it was a harness bug, not a library defect; that goes in
`VERIFICATION.md`, not `BUGS.md`. Then run the re-diff and prior-art gates **now**, not at Phase
8. Report `STATUS: SEV-STOP` and stop on that finding; continue unrelated work while waiting.

## Report format — emit at every phase exit and on SEV-STOP

```
PHASE: <n> <name>
STATUS: PASS | PASS-WITH-CAVEAT | BLOCKED | KILL | SEV-STOP
TARGET: <name> @ <clone-commit> (upstream/<branch> @ <live-head>, fetched <date>)
ARTIFACTS: <paths written this phase>
FINDINGS-DELTA: <new BUGS.md candidates, or "none">
GATES: <gate> = PASS/FAIL (+ the number that proves it)
RESOURCE: peak RSS, wall-clock spent, vs budget
NEXT: <the single next phase>
NEEDS-HUMAN: <blank, or the exact decision requested>
CONTRACT-DELTA: <blank, or a block per "Maintaining this contract" below>
```

A phase without its gate number is not complete. Heartbeat if any phase exceeds 2× budget.

## Maintaining this contract — a required deliverable, not an optional courtesy

**This document is how lessons travel between projects. Writing to it is part of your job.**

Every gate above exists because some earlier audit paid for it — the re-diff gate cost a fully
drafted report on a bug fixed twelve days earlier; the provenance check was learned one hour
before a report would have recommended a fix that regeneration reverts; the instrumentation gate
silently invalidated two complete campaigns before it was written down. None of that knowledge
was in anyone's head when it was needed. It was in this file.

The reason this matters economically: the alternative mechanism for cross-project learning is one
long-running supervising conversation that remembers everything, and that was measured at roughly
**five times the cost of the audits it supervised** — 97% of it re-reading its own context. A
checked-in contract that every agent reads at Phase 0 propagates the same lessons for the price of
reading 400 lines. **Put the lesson in the file, not in the conversation.**

### When to write

Open a `CONTRACT-DELTA` block in your Phase 7 report whenever you hit any of:

- a gate that **passed but should not have** (a false negative — the most valuable kind)
- a gate that **failed spuriously** and cost real time
- a trap that is **not specific to your target**: a build-system foot-gun, a tooling default that
  silently produces wrong numbers, a vendor behaviour that defeats a standard check
- a technique that **unblocked something** another agent will hit (how you recovered a disclosure
  channel, how you proved a file was generated)
- a claim in this contract that is now **wrong or stale**

Target-specific findings go in your own `BUGS.md`/`VERIFICATION.md`. The test for belonging here
is simple: **would the next agent, auditing a completely different protocol, be worse off not
knowing this?**

### How to write it

```
CONTRACT-DELTA
SECTION:  <existing heading to amend, or "NEW: <proposed heading>">
LESSON:   <one sentence — what the next agent must do differently>
EVIDENCE: <the concrete case: what you ran, what it returned, what it cost>
PROPOSED: <the literal text to insert, written as an instruction>
```

Rules for the text itself, learned from this file's own history:

1. **Lead with the instruction, not the anecdote.** The agent reading at Phase 0 is skimming.
2. **Keep the evidence attached.** Gates stripped of the story they came from get argued away by
   the next agent under time pressure. Every section above names its real case for that reason.
3. **Make it executable.** A copy-pasteable command beats a paragraph of description.
4. **Correct in place, dated — never silently amend.** When a claim here turns out wrong, strike
   it and say so, the same way `VERIFICATION.md` corrections are handled. A contract that quietly
   rewrites its own history cannot be trusted about anything else.
5. **Do not edit this file directly mid-audit.** Concurrent agents share it. Emit the
   `CONTRACT-DELTA` block; the human or the orchestrating session merges it between waves. The one
   exception is a correction to something **actively dangerous or false**, which you may apply
   immediately — and must then flag in the same report.

## Never do these autonomously

- **Disclosure**: contact any maintainer, vendor, mailing list, or coordinator; file or comment
  on an issue or PR; request a CVE; submit to CERT/CC or CISA; publish a repro anywhere; send a
  prepared report. Preparation is the deliverable — sending is a human decision.
- **Any external write.** This workspace is **read-only to the outside world**: you may read
  anything (`git fetch`/`pull`/`clone`/`ls-remote`, `WebFetch`, `WebSearch`, plain GET/HEAD
  `curl`/`wget`) and write nothing. Forbidden: `git push`, adding or retargeting a push remote,
  `git send-email`, any `gh`/`glab` write, and any POST/PUT/PATCH/DELETE to any host — `curl -X`,
  `-d`, `--data*`, `-F`, `-T`, `wget --post-*`, or the equivalent from a script, hook, or MCP tool.
  The rule is about the effect, not the spelling: routing the write through a pipe, a subshell,
  `eval`, or a helper script is still the write. If a task seems to need one, stop and report it.
  Commit locally; the human pushes.
- **VCS, local**: `git config --global` anything (shared by all concurrently running agents) — use
  `--local`, or `git -c user.email=... commit` for a one-off.
- **Filesystem**: write outside your own fork; modify another fork, `esbmc/`, or
  `formal-tools/`; `sudo` or install packages (a privileged-port repro is an escalation).
- **Resources**: rebuild ESBMC (9.3 GB checkout, frozen artifact); `ulimit -v` / `prlimit --as`
  an ASan binary (it reserves ~20 TB of virtual address space and will abort at startup);
  bypass the fuzz/heavy slots.
- **Methodology**: pass `--no-unwinding-assertions`; report a number from a build that failed the
  instrumentation gate; claim novelty without both the live re-diff and the function-specific
  prior-art sweep; apply a fix to upstream source inside the fork (fixes live unapplied in
  `advisory/<slug>/fix.patch`); **manufacture or inflate a finding**.

"No findings" is the expected outcome for a well-maintained library. Four of the first seven projects
were clean and said so plainly, listing exactly what was checked and why the code held up. That
is a full, valuable result — padding it is a contract violation.

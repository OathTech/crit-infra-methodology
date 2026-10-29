# Finding Power-Grid Bugs for Tens of Dollars

*Lee Pike & Mike Dodds, Oath Technologies · October 2026*

The public conversation about AI and vulnerability discovery has settled on a story: finding real
security bugs takes a frontier model, a purpose-built scaffold, and a large compute budget. For example, Anthropic's Claude Mythos Preview found a 27-year-old flaw in OpenBSD's TCP stack,
but only after
[roughly 1,000 runs costing just under $20,000](https://www.sovereignmagazine.com/article/claude-mythos-27-year-bug-cost).
The same effort, Project Glasswing, has since
[reported more than 10,000 vulnerabilities](https://www.helpnetsecurity.com/2026/05/26/anthropic-project-glasswing-update/)
backed by $100 million in model credits.

Formal verification is following the same path. On October 22, Anthropic and Theorem
[reported](https://www.anthropic.com/research/formal-verification) that Claude had proven 239
entry points across 123 open-source libraries free of crashes for every input under 64 MB. The
proofs work on the compiled RISC-V machine code, are checked by the Rocq proof assistant, and rest
on formal models of the processor and of Linux. Together they run to about 180 million lines of
Rocq, and a single proof can take hundreds of millions of tokens to produce. Along the way, the
effort found hundreds of bugs.

These efforts are remarkable. Models like Fable and Mythos are extraordinary at finding deep, subtle
bugs that have survived decades of review, and a machine-checked proof that code cannot crash is
a far stronger guarantee than any list of bugs. But the story leaves out something important: many real, exploitable defects in critical software can be found and fixed today, for tens of dollars per codebase, without a frontier model. The tools that find them have existed for years. What has changed is that language-model agents can now do the tedious work of building software, running tools, and evaluating the results. We don't produce whole-program proofs. We use lightweight tools on the source code to find the bugs that are already there, which any team can afford to do today.

Recently, we put that claim to the test against open-source software that runs the power grid. This post describes what we did and what it cost, and it points you to resources for doing the same on your own codebases.

## What we audited

The software that runs the power grid has become a direct target, not just a theoretical worry. The [Industroyer malware](https://www.welivesecurity.com/2017/06/12/industroyer-biggest-threat-industrial-control-systems-since-stuxnet/) that blacked out part of Kyiv in 2016 spoke the grid's own protocols to operate substation breakers directly, and a [second variant](https://www.welivesecurity.com/2022/04/12/industroyer2-industroyer-reloaded/) was turned on Ukraine's grid again in 2022. More recently, U.S. and allied agencies have [warned](https://www.cisa.gov/news-events/cybersecurity-advisories/aa24-038a) that state-backed groups are quietly pre-positioning inside power, water, and communications networks rather than simply spying on them. Much of the code that actually parses these protocols is open source, written in C, and maintained by small teams, exactly the kind of software we set out to examine.

We audited ten open-source protocol stacks that run inside power-grid substations, RTUs, PLCs, smart meters,
EV chargers, and grid-facing industrial servers. Between them they cover SCADA telemetry and
control, substation automation, industrial machine-to-machine messaging, utility meter reading,
and communication between electric vehicles and chargers. Many are embedded in commercial
equipment whose operators may not even know it is there.

Nine of the stacks are written in **C** and one in **C++**. Several also ship bindings or sibling
ports in C#, Java, or Python. This is the classic profile for memory-safety bugs: hand-written
parsers for binary wire formats in a language with no bounds checking, often running on embedded
targets with few runtime defenses.

Several of these projects have vulnerability reports open with their maintainers, so we have anonymized the projects, labeling them **Project A through Project J**.

## What we found

| | |
|---|---|
| Confirmed defects | **29** |
| — of those: filed with vendors / held / needed no report | **6 / 12 / 11** |
| Found by fuzzing / bounded model checking / agent-led code review | **8 / 5 / 16** |
| Projects with findings / no findings | **6 / 4** |
| Fuzzer executions across all campaigns | **13.6 billion+** |
| ESBMC bounded-model-checking proofs attempted | **60** |
| TLA+ protocol models built and checked against the real code | **6** |
| Published CVEs and advisories re-audited against exact commits | **26** |
| Total model spend, all ten projects, at API list price | **about $1,050** |

The defects range from remotely reachable out-of-bounds reads and writes, through integer overflows
that are undefined behavior in C, to memory leaks, null dereferences, reachable assertions, and protocol-logic flaws in how a receiver tracks sequence state.

Finding a defect and confirming it are separate steps. However a defect was first spotted, we then
tried to confirm it independently. We reproduced 21 of the 29 defects under a sanitizer, or caught them with a model checker run against the real code. Every report we have filed includes a reproducer: concrete code that triggers the bug.

We filed disclosures for 6 bugs. Another 12 are confirmed but held, most queued behind a higher-severity report for the same project. The remaining 11 needed no report from us: fixed upstream before we could file, already filed publicly by other researchers, or otherwise already handled.

## The method: free tools that have existed for years

Three families of tools did the heavy lifting. Fuzzing discovered 8 of the 29 defects and bounded
model checking discovered 5. The other 16 came from agents reading code with a specific
question in mind, which we describe in the next section. Often that question came from a tool: a
fuzzer finds one signed-shift bug, and an agent then sweeps the codebase for others like it.
TLA+ discovered nothing new on its own. Its value was turning a suspected logic bug into a proven
one, and proving other code correct.

All of these tools are open source, and all of them run on a laptop or a modest workstation. Ours was an 8-core machine with under 8 GB of RAM, shared by
three concurrent audits. Running these tools costs nothing but electricity. **No tokens are spent
while a fuzzer or a model checker is working.** The 13.6 billion fuzz executions above cost us
nothing in model fees.

**Coverage-guided fuzzing.** A fuzzer such as [libFuzzer](https://llvm.org/docs/LibFuzzer.html)
feeds millions of mutated inputs into a parser per minute, steered toward inputs that reach new
code, while sanitizers watch for memory errors and undefined behavior. It is the fastest way to
find shallow-to-moderate memory bugs in wire-format decoders. One project had no tests, no CI, and
no fuzzing at all. A harness an agent wrote from scratch found a real memory bug
in its first minute of running. In another, an earlier source review had come up clean, and only
fuzzing afterwards found both of its defects. One of the two belonged to a class of
integer-overflow bug that the review had declared absent. The review had searched for the usual
literal patterns, such as `<< 24`, but the real code shifted by an amount computed at runtime.
Here is a generic illustration of the class:

```c
for (i = 0; i < n; i++)
    value |= buf[i] << (8 * i);   /* int promotion: at i == 3, a byte >= 0x80 overflows */
```

No search for a literal pattern finds that line, but a fuzzer running under UBSan finds it
quickly.

A fuzz harness is usually a few lines. The agent's real work is building the library so that
the fuzzer can actually see inside it (see the lessons below):

```c
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    decode_message(data, size);
    return 0;
}
```

Here is a typical find. UBSan flagged it about five seconds into a one-minute smoke run, on a
4-byte input:

```c
int32_t v = (buf[0] & 0x80) ? -1 : 0;   /* sign-extend a negative value */
for (i = 0; i < len; i++)
    v = (v << 8) | buf[i];             /* UB: left-shifting a negative value */
```

The fix is to accumulate in a `uint32_t` and convert once at the end. On today's compilers this
usually does what the author intended, which is why it can survive for years. But a compiler is still
allowed to miscompile it, and in a build that traps on overflow, it becomes a crash. Other fuzzing
finds in the same audits included a memory leak on a parse-error path, unbounded recursion on
deeply nested input, and a read past the end of a buffer in a shared bit-reader:

```c
bit = (data[byte_pos] >> bit_pos) & 1;   /* never checks byte_pos < len */
```

**Bounded model checking with [ESBMC](https://github.com/esbmc/esbmc).** A fuzzer samples inputs,
while a model checker reasons about *all* inputs up to a bound. Given a small harness around a
function, ESBMC either proves that no input within the bound causes an out-of-bounds access,
overflow, or null dereference, or it returns the exact input that does. The two techniques are
complements, not substitutes. In one codec, every fuzz harness crashed within a few dozen inputs
on the same low-level bug, which left the rest of the decoder unreachable for dynamic testing. ESBMC
reasons symbolically rather than by running inputs, so it was not blocked by that crash, and it
found a second, independent defect that fuzzing never reached.

Model checkers are good at edge cases that a byte-mutating fuzzer has no reason to try. Here is
one ESBMC found:

```c
bool negative = buf[0] & 0x80;   /* reads buf[0] even when len == 0 */
```

The harness says "any length from 0 to 9, any contents" and lets the checker do the rest:

```c
size_t len = nondet_size();
__ESBMC_assume(len <= 9);
uint8_t *buf = malloc(len);      /* contents are unconstrained */
__ESBMC_assume(buf != NULL);
decode_int(buf, len);
```

```sh
esbmc harness.c decode.c --overflow-check --ub-shift-check --unwind 10
```

ESBMC returned a counterexample with `len == 0`, a one-byte read past a zero-length allocation.
After a one-line guard, the same harness reports `VERIFICATION SUCCESSFUL`. That is a proof for
every size up to 9 and every possible byte value, not a sample of them. In the same audit, ESBMC
also found an unchecked `malloc()` result, because it explores allocation failure by default and
most fuzzers don't. Other ESBMC finds included a reachable `assert(0)` and a silent unsigned
wraparound in an integer decoder.

Proofs also make good regression tests. Where a bug is confirmed but not yet fixed upstream, we
check in an ESBMC proof that is *expected to fail*. It becomes a trip-wire that flips to passing on
the day the fix lands.

**Protocol modeling with [TLA+](https://lamport.azurewebsites.net/tla/tla.html).** Some of the most
important grid-protocol bugs aren't memory errors. They are logic errors in state that persists
across messages: sequence numbers, acknowledgment windows, counters that wrap around, and the
accept/reject decisions made from them. Nothing crashes when a stale or replayed message is
wrongly accepted, so fuzzing can never see these bugs. We wrote small TLA+ models of how a
receiver should track that state and let the TLC model checker explore every reachable state.

In one project, code review had flagged a receiver that looked too lenient about sequence numbers.
Here is the check, simplified. It has since been fixed upstream, and it had already been reported
publicly by another researcher:

```c
if (state == last_state && seq <= last_seq)
    return REJECT;   /* the only case that is ever rejected */
return ACCEPT;       /* any other state number, with any sequence number */
```

The protocol's rule fits in three lines of TLA+:

```tla
Valid(st, sq) ==
    \/ (st = lastState /\ sq > lastSeq)          \* same state: sequence must advance
    \/ (st > lastState /\ sq = 0)                \* new state: sequence restarts at 0
    \/ (lastState = Max /\ st = 0 /\ sq = 0)     \* the one legal wraparound
```

The bridge fed both the model and the real C function the same transitions. They disagreed on 87
of 144. The suspicion turned out to be too narrow: besides accepting a new state without a
sequence reset, the code accepted a state number that went *backwards*, which is a plain replay.
After the fix, all 153 transitions in the extended sweep agree. In another project, the bridge drove the real
sequence-window function across all 67 million of its possible inputs, with no mismatch against the model.
That is a positive result worth as much as a finding.

The key to TLA+ is a bridge: a separate harness that runs the real C function against the
model, transcribed independently from the source. Twice, a model passed every one of its own
checks while silently disagreeing with the code it described, and only the bridge caught it. We
use TLA+ selectively, only when a protocol meets a short list of entry criteria. When it doesn't,
we write down a "not modeled, and here's why" decision.

None of these tools is new. ESBMC, TLA+, and libFuzzer have each been mature for years. What kept
them out of most engineering teams was expertise and labor:
building the target with the right instrumentation, writing harnesses, stubbing out hardware,
choosing bounds, and reading the output. That is exactly the work language-model agents are now
good at. In one audit, ESBMC itself lacked support for two C++ library features the target
used, and the agent extended the checker rather than giving up on the target.

### Tools keep the agents honest

These tools also take most of the hallucination risk out of the results. When an agent says it
found a bug, a fuzzer or model checker gives you something you can check without trusting the
model: an input that crashes a sanitizer-instrumented build, or a counterexample you can replay.
When an agent says a piece of code is safe, ESBMC either reports `VERIFICATION SUCCESSFUL` or it
doesn't. A language model can invent a plausible-sounding bug, but it cannot make AddressSanitizer
fire on code that has no bug.

The risk doesn't vanish. It moves to the setup, where it is easier to check. An agent can write a
harness that feeds the library inputs no real caller could produce, and in three of our first
seven audits an apparent crash turned out to be exactly that. A TLA+ model can describe the
protocol wrongly, and an ESBMC harness can assume away the very inputs that would trigger a bug.
The gates in our methodology exist to catch these: a check that the production caller can really
produce the crashing input, the bridge between each TLA+ model and the real code, and a check that
the fuzzer is actually instrumented. Each turns "do you believe the agent?" into "does this check
pass?"

### Limitations

None of this is full formal verification, and none of it is exhaustive. We have not proven any
library functionally correct, meaning that it does what its protocol specification says it
should. Each ESBMC proof covers one function, a handful of properties, and inputs up to a small
bound. Each TLA+ model covers one piece of protocol state. Fuzzing only finds what its harnesses
reach. And we looked for particular classes of bug, mainly memory safety, undefined behavior and
sequence-number logic. We did not systematically look for cryptographic weaknesses,
authentication design flaws, timing side channels, or most other protocol-logic errors.

The defects in this post are low-hanging fruit: bugs that cheap, well-understood tools find once
someone does the work of setting them up. That is the point of the post. These bugs are still out
there in software that runs the grid, and finding them no longer requires a large budget. But a
clean result from this method means only that these tools, applied this way, found nothing. It
does not mean the code is secure.

## The method: let agents do the tedious work

We used Claude-based coding agents, mostly the mid-tier Sonnet 5 with Opus 5 for
orchestration. The agents did the parts of an audit that
are laborious rather than deep:

- **Building the library.** Old autotools builds, CMake projects with optional features, embedded
  configurations that only compile with the right defines. Agents work through build failures the
  way an engineer does, and then rebuild with sanitizer and coverage instrumentation.
- **Mapping the attack surface.** Agents find where attacker-controlled bytes first enter the
  library, list every length-driven loop and copy, and rank which entry points deserve a harness.
- **Setting up the tools.** Agents write libFuzzer harnesses and seed corpora, ESBMC harnesses with
  hardware stubs and loop bounds, and TLA+ models with the independent bridge to the real code.
- **Running campaigns and collecting results.** Agents run two-minute triage waves, promote only
  the harnesses that are still finding new coverage, and stop them when coverage flattens.
- **Triage.** Agents deduplicate crashes, minimize the triggering input, and check whether the
  real production caller could ever produce that input. This last check matters: an apparent crash
  can easily be a harness bug rather than a library bug.
- **Prior art.** Agents check each finding against published CVEs, against the live upstream
  branch, and against fixes a vendor made quietly under an internal ticket.
- **Writing the disclosure.** Each package includes a concrete, deterministic trigger, a root-cause
  analysis, a patch tested against that trigger, an honest statement of impact (including when
  it depends on build configuration), and an explicit note that AI assistance was used. Agents
  also find the right channel. For one project with no security policy, the agent recovered the maintainer's private address from the project's own commit
  history.

More than half of our findings came from agents reading code, but never open-ended "find bugs"
reading. Each pass started from a specific question. Does this published CVE's fix cover every
caller? Are there more instances of the bug the fuzzer just found? Do these two functions agree
on their limits? That last question found a heap overflow, now
fixed upstream:

```c
/* Sizing: how many bytes the caller allocates for the length field */
size = (len < 65536) ? 3 : 4;

/* Encoding: how many bytes actually get written */
if (len < 65535) write_3_bytes(len); else write_4_bytes(len);
```

At exactly `len == 65535`, the caller allocates three bytes and the encoder writes four. The fix
is one character, `65535` → `65536`. We found it by reading code. A short ESBMC harness that
checks the bytes written never exceed the bytes allocated would have found it too, and would now
prove the fix.

### Why reading code found more than the tools

We didn't expect review to find more defects than the tools, and we have no controlled experiment
that explains it. Looking back at where each finding came from, we suspect three reasons.

**The count flatters review.** Much of the review started from a tool or from a published
advisory. In one project, a fuzzer found a signed-arithmetic bug, and an agent then found four
more bugs of the same family by sweeping the code. The fuzzer gets credit for one and review for
four. Several other review finds began with the text of a published CVE.

**Review reaches code the tools didn't.** A fuzzer only exercises what its harness feeds it, for
as long as the campaign runs. Our ESBMC harnesses covered a few functions at small bounds. Review
found bugs in a network layer outside the parser we fuzzed, and in a code path compiled only under
one build configuration. It found one in an authentication branch reached only in the middle of a
session, and others in a decoder the fuzzer couldn't get past an earlier crash to reach. Review
also covers code that is unreachable today, which no dynamic tool will ever run.

**Some bugs don't crash.** Sanitizers flag memory errors and undefined behavior. They have nothing
to say about an operator-precedence mistake that sets the wrong bits, or a missing anti-replay
check. TLA+ can catch some logic errors like these, but only where someone has built a model.

None of this weakens the case for cheap AI. The same mid-tier model did the reviewing, inside the
same $20–$115 budget per audit, and it found real bugs, including the worst one in the series. The
tools and the review also worked best together. The tools gave review its questions and confirmed
its answers. Review covered the code that the harnesses and models never reached.

Agents prepare disclosures, and humans send them. Our agents work under a hard rule that nothing
leaves the machine: no pushes, no issue filings, no emails to maintainers. Every package is
reviewed by a person who decides whether, when, and how to send it.

## What it cost

We reconstructed every token from our session logs and priced it at published API list rates.
This is model spend only. The fuzzing, model checking, and TLA+ runs ran on our own hardware and
added nothing.

| Project | Result | Model spend |
|---|---|---|
| A | Clean | ~$20 |
| B | 3 defects | ~$25 |
| C | 2 defects | ~$30 |
| D | Clean | ~$30 |
| E | 2 defects | ~$35 |
| F | Clean | ~$35 |
| G | 2 defects | ~$45 |
| H | 7 defects | ~$65 |
| I | Clean | ~$85 |
| J | 13 defects | ~$115 |
| **All ten audits** | **29 defects** | **~$500** |
| Orchestrating session | | ~$550 |
| **Total** | | **~$1,050** |

A full audit of one grid protocol stack cost between about $20 and $115, roughly $35 at the
median. The two most expensive were the first two, which established the methodology everyone
else followed. Our first-wave numbers are attributed from shared sessions, so treat them as ±20%.
The second wave ran one agent per phase per project, so those figures are direct measurements.
For comparison, the frontier-model campaign cited above cost just under $20,000. Our entire
ten-project series, orchestration included, cost about a twentieth of that. It is also orders of
magnitude below a traditional manual audit.

### Where the money actually went, and how to do it for $10–$20

More than half of the total isn't the audits. It's the orchestrating session: one long conversation
that planned the second wave, supervised the agents, and prepared and re-verified every
disclosure. That work was real, but its price wasn't: 97% of that session's tokens were the
model re-reading its own ever-growing conversation history, and it ran on a model about two
and a half times the price of the audit agents. Across everything we spent, about 72% went to re-reading
context. Very little of the bill was the model actually thinking. That means most of it can be cut:

1. **Replace the supervisor with a file.** Lessons from one audit go into a short, checked-in
   methodology document that every new agent reads at the start. Reading 400 lines costs cents.
   We made this switch partway through, and it is the single biggest saving.
2. **Use short sessions, one per phase.** Each phase (build, fuzz, model-check, write up) starts
   fresh and hands off through files on disk, not through a growing conversation. Our second-wave
   audits, which worked this way, cost $25–$65 each.
3. **Keep the model out of the waiting.** A 30-minute fuzzing campaign needs no model watching it.
   A shell script waits, and the agent resumes when the campaign exits with a result.
4. **Use a smaller model for mechanical phases.** Builds, harness boilerplate, re-running gates, and
   refreshing documents don't need a strong model. Claude Haiku 4.5 costs half as much as Sonnet 5
   per token. Save the stronger model for triage and disclosure judgment.

Applied together, we estimate that a full audit of one library costs $10–$20.

## The methodology, open to everyone

> **[PLACEHOLDER: public release announcement and link to the methodology repository.]**

We're releasing the methodology we used so that others can run these audits themselves. The
repository contains:

- **An agent contract.** This phase-by-phase playbook takes an agent from cloning a library to a
  disclosure package. It defines an exit gate for each phase and a time budget for each step, and
  includes a "kill gate" that rejects a weak target in 90 minutes instead of three days. It names
  no project and no finding. It contains only the method and the traps above, each with the
  command that catches it.
- **Standing instructions.** Your coding agent loads these automatically. They include the
  read-only-to-the-outside-world rule and permission settings that enforce it, so an agent can
  prepare a disclosure but cannot send one.
- **Build and verification templates.** These include a sanitizer-and-coverage build script for
  fuzzing and an ESBMC driver that runs a library's harnesses in tiers.
- **Orchestration scripts.** These let several audits share one ordinary machine without starving
  each other of CPU or memory.

The aim is that **a utility engineer, a grid operator's software team, or a vendor's own developers
can run a credible audit of the protocol libraries they depend on, without expertise in
security research or formal methods.** The agent sets up the fuzzer, writes the model-checking
harness, and drafts the TLA+ model. The contract tells it, and you, what counts as a real result.
You review the findings and decide what to send.

## The takeaway

Frontier models are moving the ceiling of what automated vulnerability research can find, and
that matters. But the floor has moved too, and it has moved further for most of the software that
runs critical infrastructure. Fuzzers, bounded model checkers, and specification languages have
been powerful for years. Agents have now made them nearly push-button to use. Ten audits of grid
protocol stacks produced 29 confirmed defects for about $500 of audit work. Better session
hygiene could cut most of that bill again.

You don't need to wait for access to the most capable model to find and fix these bugs, and
neither do the people who depend on this software.

---

*AI disclosure: AI assisted in writing this post and the work described within it.*

*Oath Technologies is a focused research organization working on AI oversight through formal methods. If you maintain or
depend on an open-source grid protocol library and want to talk about auditing it, contact us at
[oath.tech](https://oath.tech/).*

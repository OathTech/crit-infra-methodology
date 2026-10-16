# Contributing

The most valuable contribution is a **lesson**: something an audit taught you that would have
helped an audit of a *different* target. That is exactly what the contract's `CONTRACT-DELTA`
block captures, so send it as a pull request.

## Contract changes

1. Start from the `CONTRACT-DELTA` your agent emitted at Phase 7, or write one by hand:

   ```
   CONTRACT-DELTA
   SECTION:  <existing heading to amend, or "NEW: <proposed heading>">
   LESSON:   <one sentence — what the next agent must do differently>
   EVIDENCE: <the concrete case: what you ran, what it returned, what it cost>
   PROPOSED: <the literal text to insert, written as an instruction>
   ```

2. Apply `PROPOSED` to `.orchestrator/AGENT_CONTRACT.md` and put the rest in the PR description.
3. Follow the contract's own rules for its text: lead with the instruction, keep the evidence,
   make it executable, and correct in place with a date rather than silently rewriting.

The test for belonging: **would the next agent, auditing a completely different protocol, be
worse off not knowing this?**

## The one hard rule: no findings

Pull requests, issues, and commit messages here must not identify a defect in any third-party
project — no project names, file or function names, commit SHAs, issue numbers, CVE IDs, or
reproducers tied to a specific target. State the cost of a lesson without the identifier:
*"this cost a fully drafted report for a bug fixed upstream twelve days earlier"*, not the
library's name. An unpatched defect can be located from surprisingly little, so a PR that names
one will be closed and you will be asked to resubmit it scrubbed. See [SECURITY.md](SECURITY.md).

## Scripts

- Keep them plain Bash; they must pass `bash -n` and, ideally, `shellcheck`.
- Keep the defaults working on the reference 8-core machine, and keep new knobs configurable
  through environment variables.
- Explain *why* in comments, the way the existing scripts do. Most of those comments are a bug
  that already happened.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

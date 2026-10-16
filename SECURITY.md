# Security policy

## Vulnerabilities in this repository

If you find a security problem in this repository itself — for example, a way for the slot
scripts to be abused on a shared machine, or a gap in the `deny` rules that lets an agent perform
an external write — please report it privately through GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository, or contact
Oath Technologies via [oath.tech](https://oath.tech/). Please do not open a public issue.

## Vulnerabilities you find with this methodology

This repository is for **coordinated disclosure**. Defects found in a third-party library belong
to that library's maintainers:

- Report them privately, through the route identified in the contract's Phase 1 (vendor private
  reporting, the project's `SECURITY.md`, a maintainer address from the project's own history,
  or a coordinator such as CERT/CC or CISA for dormant projects).
- **Never** put details of a third-party finding — project, file, function, reproducer, or
  patch — in an issue, pull request, or discussion here. Methodology lessons are welcome (see
  [CONTRIBUTING.md](CONTRIBUTING.md)); findings are not.
- Sending a report is always a human decision. The standing instructions and `deny` rules keep
  agents from sending anything; please don't work around them.

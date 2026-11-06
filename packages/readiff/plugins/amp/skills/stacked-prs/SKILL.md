---
name: stacked-prs
description: Plans, prepares, and publishes stacked PRs on GitHub using gh stack. Use for stacked PR or stacked PRs requests, branch splitting, and follow-up publication of existing branches or PRs.
---

# Stacked PRs on GitHub

When preparing or publishing stacked PRs on GitHub, use `gh stack` to create or
update the GitHub stack. This includes branches or PRs that already exist. Keep
planning requests read-only and obtain any required publication approval before
changing remote state.

## Publication

Inspect `gh stack --help` and the relevant subcommand help before use. After
pushing the branches to the GitHub remote, complete the remote stacking with
`gh stack`.

- For a locally tracked stack, `gh stack submit` pushes the branches before
  creating or updating the GitHub stack.
- For already-pushed branches or existing PRs, use `gh stack link` with the
  branches or PRs in bottom-to-top dependency order.

Verify the remote stack membership and PR bases before reporting publication
complete. Pushed branches or chained PR bases alone are not a completed GitHub
stack. If `gh stack` is unavailable, report the blocker rather than substituting
a manual GitHub PR workflow.

## PR descriptions

PR descriptions must explain that PR's purpose, approach, and validation. They
may describe the overarching goal and how this PR contributes to it, while
distinguishing what this PR delivers from future work.

For stacked PRs, never say that a PR is stacked or reference the stack, its size
or order, or other PRs as predecessors or successors. This applies to generated
descriptions as well as descriptions you write. Let `gh stack` supply the
relationships in GitHub's stack UI. Read existing descriptions before editing
them and preserve others' unrelated edits.

---
name: macbeth-code-review
description: Project-specific correctness and regression guidance for Macbeth reviews
triggers:
  - /codereview
---

# Macbeth code review guidance

Review the complete pull request against its base branch. Use the changed-file
manifest as the source of truth, then inspect full files, callers, tests, and
related protocol definitions in the checked-out repository whenever that
context could change a finding.

## Follow-up reviews

Every submitted review body from this reviewer must begin with this exact
hidden marker so a later run can identify it in the review history:

`<!-- macbeth-openhands-review -->`

When a previous completed review containing that marker exists, treat the most
recent one as the review checkpoint while still examining the complete current
PR:

1. Re-check every actionable finding from that review and its associated
   threads against the current HEAD.
2. Classify each as **resolved**, **still present**, or **obsolete** because the
   affected code no longer exists. Do not infer resolution merely from a
   resolved or outdated GitHub thread; verify the current code.
3. Check whether any attempted correction introduced a regression or incomplete
   fix. Treat that as a new finding and explain its relationship to the earlier
   one.
4. Find genuinely new issues in all current PR changes, including interactions
   between new commits and older changes in the same PR.

After the hidden marker, begin the top-level review body with a concise
`Previous review follow-up` section. List resolved, still-present, and obsolete
findings, or state that the previous review had no actionable findings. Follow
it with a `New findings` section. If this is the first marked review, say so
briefly and omit the classification.

Do not post a duplicate inline comment for an unchanged, still-present finding;
reference it in the follow-up summary instead. Post inline comments for new
findings, materially changed failure modes, or incomplete fixes that need new
evidence. Read other reviewers' comments too, and do not duplicate their
still-relevant findings.

Prioritize actionable defects over style preferences:

- Cross-check the TypeScript client, Swift daemon, and any shared wire protocol
  whenever one side changes. Look for incompatible payloads, defaults, error
  handling, or lifecycle assumptions.
- Treat macOS Accessibility, ScreenCaptureKit, focus, permissions, and process
  ownership as security and correctness boundaries. Flag behavior that can
  capture, inspect, or control a different target than the user intended.
- Trace cancellation, timeout, retry, and cleanup paths. Pay particular
  attention to half-finished operations, stale state, duplicate callbacks,
  leaked tasks or processes, and races between UI and daemon state.
- Check changed behavior against tests and identify important untested failure
  modes. Run focused read-only tests or builds when they can validate a
  suspected problem.
- Check packaging and GitHub Actions changes for secret exposure, untrusted-code
  execution, mutable dependencies, incorrect event context, and fork behavior.

Only report findings that are caused by the pull request and that the author can
act on. Include concrete evidence: the affected path and line, the execution
path or scenario that triggers the bug, and the user-visible consequence. Do
not modify the repository; this is a review-only task.

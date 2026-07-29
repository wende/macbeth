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
context could change a finding. Read prior reviews and threads so you do not
repeat resolved or already-reported findings.

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

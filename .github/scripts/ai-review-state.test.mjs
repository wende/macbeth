import test from "node:test";
import assert from "node:assert/strict";

import {
  extractReviewHead,
  latestCompletedReview,
  pullReviewDisposition,
  reviewHeadMarker,
  selectDiffRange,
} from "./ai-review-state.mjs";

const marker = "<!-- ai-review:MiniMax -->";
const sha = (char) => char.repeat(40);

test("an explicit checkpoint marker wins over GitHub's legacy commit_id", () => {
  const review = {
    body: `${marker}\n${reviewHeadMarker(sha("b"))}`,
    commit_id: sha("a"),
  };
  assert.equal(extractReviewHead(review), sha("b"));
});

test("legacy reviews use GitHub's commit_id as their checkpoint", () => {
  assert.equal(
    extractReviewHead({ body: marker, commit_id: sha("c") }),
    sha("c")
  );
});

test("the newest submitted MiniMax review is the checkpoint", () => {
  const reviews = [
    {
      id: 1,
      body: marker,
      state: "COMMENTED",
      submitted_at: "2026-07-20T10:00:00Z",
      commit_id: sha("a"),
    },
    {
      id: 2,
      body: "human review",
      state: "APPROVED",
      submitted_at: "2026-07-22T10:00:00Z",
      commit_id: sha("b"),
    },
    {
      id: 3,
      body: marker,
      state: "COMMENTED",
      submitted_at: "2026-07-21T10:00:00Z",
      commit_id: sha("c"),
    },
  ];
  assert.equal(
    extractReviewHead(latestCompletedReview(reviews, marker)),
    sha("c")
  );
});

test("pending reviews and runs that posted no review cannot advance the checkpoint", () => {
  const completed = {
    id: 1,
    body: marker,
    state: "COMMENTED",
    submitted_at: "2026-07-20T10:00:00Z",
    commit_id: sha("a"),
  };
  const pending = {
    id: 2,
    body: `${marker}\n${reviewHeadMarker(sha("b"))}`,
    state: "PENDING",
    submitted_at: "2026-07-21T10:00:00Z",
    commit_id: sha("b"),
  };
  assert.equal(
    extractReviewHead(latestCompletedReview([completed, pending], marker)),
    sha("a")
  );
});

test("live pull state skips drafts and closed PRs but reviews ready PRs", () => {
  assert.deepEqual(pullReviewDisposition({ state: "open", draft: true }), {
    review: false,
    reason: "PR is currently a draft",
  });
  assert.deepEqual(pullReviewDisposition({ state: "closed", draft: false }), {
    review: false,
    reason: "PR is closed",
  });
  assert.deepEqual(pullReviewDisposition({ state: "open", draft: false }), {
    review: true,
    reason: "",
  });
});

test("structured reviews cover every commit since the last completed review", () => {
  const result = selectDiffRange({
    structured: true,
    baseSha: sha("0"),
    checkpointSha: sha("a"),
    // This represents a later push after an intermediate run was cancelled.
    beforeSha: sha("b"),
    headSha: sha("c"),
    action: "synchronize",
    isAncestor: (ancestor, head) => ancestor === sha("a") && head === sha("c"),
  });
  assert.deepEqual(result, {
    incremental: true,
    rangeBase: sha("a"),
    rangeSep: "..",
    checkpointSha: sha("a"),
    rejectedCheckpoint: false,
  });
});

test("a rebased-away checkpoint falls back to the full PR diff", () => {
  const result = selectDiffRange({
    structured: true,
    baseSha: sha("0"),
    checkpointSha: sha("a"),
    headSha: sha("c"),
    isAncestor: () => false,
  });
  assert.deepEqual(result, {
    incremental: false,
    rangeBase: sha("0"),
    rangeSep: "...",
    checkpointSha: "",
    rejectedCheckpoint: true,
  });
});

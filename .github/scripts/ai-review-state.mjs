const FULL_SHA = /^[0-9a-f]{40}$/;
const REVIEW_HEAD_MARKER = /<!-- ai-review-head:([0-9a-f]{40}) -->/;

export function reviewHeadMarker(sha) {
  if (!FULL_SHA.test(sha)) {
    throw new Error(`Invalid review head SHA: ${sha}`);
  }
  return `<!-- ai-review-head:${sha} -->`;
}

export function extractReviewHead(review) {
  const body = typeof review?.body === "string" ? review.body : "";
  const marked = body.match(REVIEW_HEAD_MARKER)?.[1];
  if (marked) return marked;
  return FULL_SHA.test(review?.commit_id || "") ? review.commit_id : null;
}

export function latestCompletedReview(reviews, reviewerMarker) {
  return (Array.isArray(reviews) ? reviews : [])
    .filter(
      (review) =>
        review?.state !== "PENDING" &&
        typeof review?.submitted_at === "string" &&
        typeof review?.body === "string" &&
        review.body.includes(reviewerMarker) &&
        extractReviewHead(review)
    )
    .sort((a, b) => {
      const byTime = a.submitted_at.localeCompare(b.submitted_at);
      return byTime || Number(a.id || 0) - Number(b.id || 0);
    })
    .at(-1) || null;
}

export function pullReviewDisposition(pull) {
  if (!pull || typeof pull !== "object") {
    return { review: false, reason: "PR state could not be loaded" };
  }
  if (pull.state !== "open") {
    return { review: false, reason: `PR is ${pull.state || "not open"}` };
  }
  if (pull.draft) {
    return { review: false, reason: "PR is currently a draft" };
  }
  return { review: true, reason: "" };
}

export function selectDiffRange({
  structured,
  baseSha,
  headSha,
  checkpointSha = "",
  action = "",
  beforeSha = "",
  isAncestor,
}) {
  const full = {
    incremental: false,
    rangeBase: baseSha,
    rangeSep: "...",
    checkpointSha: "",
    rejectedCheckpoint: false,
  };

  if (structured) {
    if (!FULL_SHA.test(checkpointSha)) return full;
    if (!isAncestor(checkpointSha, headSha)) {
      return { ...full, rejectedCheckpoint: true };
    }
    return {
      incremental: true,
      rangeBase: checkpointSha,
      rangeSep: "..",
      checkpointSha,
      rejectedCheckpoint: false,
    };
  }

  if (
    action === "synchronize" &&
    FULL_SHA.test(beforeSha) &&
    !/^0+$/.test(beforeSha) &&
    isAncestor(beforeSha, headSha)
  ) {
    return {
      incremental: true,
      rangeBase: beforeSha,
      rangeSep: "..",
      checkpointSha: "",
      rejectedCheckpoint: false,
    };
  }
  return full;
}

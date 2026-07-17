#!/usr/bin/env node
// Generic OpenAI-compatible PR reviewer.
// Reads config from env, sends the PR diff to a chat-completions endpoint,
// and posts the response back as a PR comment. Used by ai-pr-review.yml for
// both Kimi (Moonshot) and GLM (z.ai), which both expose OpenAI-compatible APIs.
//
// Scope: on the first run (PR opened/reopened) it reviews the full base..head
// diff. On later pushes (synchronize) it reviews only the new commits
// (before..head) and lets the model reply "No notable changes" for trivial
// updates, appending each incremental review as a dated section to the comment.
// Force-pushes/rebases (before not an ancestor of head) fall back to a full review.
//
// Resolved points: on an incremental run with an existing comment ("revise
// mode"), the model is handed its prior base review and returns only (1) a short
// list of the earlier points the new commits now address and (2) a review of the
// new commits. The script itself strikes the matching lines in the stored base
// (~~...~~ — ✅ addressed in <sha>), so prior text stays byte-exact and a bad
// response can never wipe existing content. Prior dated ### Update sections are
// left untouched (append-only).
//
// Structured mode (STRUCTURED_OUTPUT=true, used by MiniMax): the model returns a
// JSON {verdict, summary, comments[]} contract instead of markdown. Rather than
// dumping that JSON into a comment, the script submits an actual GitHub PR review
// — mapping the verdict to APPROVE / REQUEST_CHANGES / COMMENT, using the summary
// as the review body, and posting each comment inline on its file/line. This path
// is self-contained and does not use the revise/strike machinery above.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const {
  PROVIDER_NAME = "AI",
  API_BASE,
  API_KEY,
  MODEL,
  SYSTEM_PROMPT = "You are an experienced code reviewer. Review the pull request diff for bugs, security issues, and correctness problems. Be concise; skip style nitpicks. Use markdown.",
  SYSTEM_PROMPT_FILE = "",
  GITHUB_TOKEN,
  GITHUB_REPOSITORY,
  PR_NUMBER,
  BASE_SHA,
  HEAD_SHA,
  ACTION = "", // pull_request action: opened | synchronize | reopened | ...
  BEFORE_SHA = "", // prior head SHA (present on synchronize)
  MAX_DIFF_CHARS = "60000",
  MAX_TOKENS = "2000",
  TEMPERATURE = "", // omit unless set; some models (e.g. kimi-for-coding) only accept 1
  REASONING_SPLIT = "false",
  STRUCTURED_OUTPUT = "false",
} = process.env;

function fail(msg) {
  console.error(`[${PROVIDER_NAME}] ${msg}`);
  process.exit(1);
}

// Extract and validate JSON when a reviewer prompt declares a machine-readable
// contract. Some providers wrap otherwise valid JSON in a think tag or fence.
// Returns the parsed object so the caller can act on the verdict/comments —
// submitting a real PR review — rather than dumping the raw JSON into a comment.
function parseStructuredReview(raw) {
  const withoutReasoning = raw.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
  const start = withoutReasoning.indexOf("{");
  const end = withoutReasoning.lastIndexOf("}");
  if (start === -1 || end < start) fail("Structured review did not contain a JSON object.");

  let parsed;
  try {
    parsed = JSON.parse(withoutReasoning.slice(start, end + 1));
  } catch {
    fail("Structured review contained invalid JSON.");
  }

  const validVerdicts = new Set(["approve", "request_changes", "comment"]);
  if (!validVerdicts.has(parsed?.verdict) || typeof parsed?.summary !== "string" || !Array.isArray(parsed?.comments)) {
    fail("Structured review did not match the required verdict, summary, and comments schema.");
  }
  if (parsed.comments.length > 10) fail("Structured review exceeded the 10-comment limit.");
  return parsed;
}

// Severity → emoji for rendering findings that can't be anchored inline.
const SEVERITY_EMOJI = {
  blocker: "🔴",
  high: "🟠",
  suggestion: "🟡",
  nit: "⚪",
};

// Map the model's verdict to a GitHub review event and a human-readable label.
const VERDICT_MAP = {
  approve: { event: "APPROVE", label: "✅ Approve" },
  request_changes: { event: "REQUEST_CHANGES", label: "🛑 Request changes" },
  comment: { event: "COMMENT", label: "💬 Comment" },
};

// Render one structured comment as a markdown block. Used both for the body of
// a fallback review (when a finding can't be anchored to a diff line) and as the
// body of an inline review comment.
function renderComment(c, { withLocation = false } = {}) {
  const emoji = SEVERITY_EMOJI[c.severity] || "•";
  const sev = c.severity ? `**${c.severity}**` : "";
  const cat = c.category ? ` · _${c.category}_` : "";
  const loc =
    withLocation && c.file
      ? ` · \`${c.file}${Number.isInteger(c.line) ? `:${c.line}` : ""}\``
      : "";
  const issue = typeof c.issue === "string" ? c.issue : "";
  const fix =
    typeof c.fix === "string" && c.fix.trim() ? `\n\n${c.fix.trim()}` : "";
  return `${emoji} ${sev}${cat}${loc}\n\n${issue}${fix}`.trim();
}

let systemPrompt = SYSTEM_PROMPT;
if (SYSTEM_PROMPT_FILE) {
  try {
    systemPrompt = readFileSync(SYSTEM_PROMPT_FILE, "utf8").trim();
  } catch (e) {
    fail(`Could not read SYSTEM_PROMPT_FILE "${SYSTEM_PROMPT_FILE}": ${e.message}`);
  }
  if (!systemPrompt) fail(`SYSTEM_PROMPT_FILE "${SYSTEM_PROMPT_FILE}" is empty.`);
}

// Parse and validate a numeric env var; fall back to the default if invalid.
function parseIntSafe(raw, fallback, label) {
  const n = parseInt(raw, 10);
  if (!Number.isFinite(n) || n <= 0) {
    console.warn(`[${PROVIDER_NAME}] Invalid ${label} "${raw}", using default ${fallback}.`);
    return fallback;
  }
  return n;
}

// Secrets are unavailable on fork PRs — skip cleanly instead of failing the run.
if (!API_KEY) {
  console.log(`[${PROVIDER_NAME}] No API key present (fork PR?); skipping review.`);
  process.exit(0);
}
if (!API_BASE || !MODEL) fail("API_BASE and MODEL are required.");
if (!GITHUB_TOKEN || !GITHUB_REPOSITORY || !PR_NUMBER) fail("Missing GitHub context env vars.");
if (!BASE_SHA || !HEAD_SHA) fail("Missing BASE_SHA or HEAD_SHA env vars.");

// Validate numeric env vars up front to avoid NaN propagating to the API.
const maxDiffChars = parseIntSafe(MAX_DIFF_CHARS, 60000, "MAX_DIFF_CHARS");
const maxTokens = parseIntSafe(MAX_TOKENS, 2000, "MAX_TOKENS");
const temperature =
  TEMPERATURE !== "" && Number.isFinite(parseFloat(TEMPERATURE))
    ? parseFloat(TEMPERATURE)
    : undefined;

// Build the diff, excluding lockfiles and generated bundles.
// Narrowed to specific lockfile names rather than a blanket *.lock glob so
// that non-dependency lock files are still reviewed.
const excludes = [
  ":(exclude)**/pnpm-lock.yaml",
  ":(exclude)**/package-lock.json",
  ":(exclude)**/yarn.lock",
  ":(exclude)**/dist/**",
  ":(exclude)**/*.min.*",
  ":(exclude)**/_generated_*",
];

// Decide scope: incremental (only new commits) on synchronize when BEFORE_SHA
// is a real ancestor of HEAD; otherwise a full base..head review.
let incremental = false;
let rangeBase = BASE_SHA;
if (
  ACTION === "synchronize" &&
  /^[0-9a-f]{40}$/.test(BEFORE_SHA) &&
  !/^0+$/.test(BEFORE_SHA)
) {
  try {
    // Non-zero exit (rebase/force-push, or object missing) throws → full review.
    execFileSync("git", ["merge-base", "--is-ancestor", BEFORE_SHA, HEAD_SHA], {
      stdio: "ignore",
    });
    rangeBase = BEFORE_SHA;
    incremental = true;
  } catch {
    incremental = false;
  }
}

let diff;
try {
  diff = execFileSync(
    "git",
    // Double-dot (BEFORE_SHA..HEAD_SHA) makes the incremental intent explicit;
    // triple-dot would rely on merge-base semantics that could change if the
    // ancestry check above ever changes.
    ["diff", `${rangeBase}..${HEAD_SHA}`, "--", ".", ...excludes],
    { encoding: "utf8", maxBuffer: 1024 * 1024 * 50 }
  );
} catch (e) {
  fail(`git diff failed: ${e.message}`);
}

if (!diff.trim()) {
  console.log(`[${PROVIDER_NAME}] Empty diff after exclusions; nothing to review.`);
  process.exit(0);
}

let truncated = false;
let diffStat = "";
if (diff.length > maxDiffChars) {
  // Truncate at the last newline within the limit so we never split a line
  // mid-character or mid-hunk, which would produce a malformed diff.
  let sliced = diff.slice(0, maxDiffChars);
  const lastNewline = sliced.lastIndexOf("\n");
  if (lastNewline > 0) sliced = sliced.slice(0, lastNewline);
  diff = sliced;
  truncated = true;
  // Include a file-level summary so the model knows what was omitted.
  try {
    diffStat = execFileSync(
      "git",
      ["diff", `${rangeBase}..${HEAD_SHA}`, "--stat", "--", ".", ...excludes],
      { encoding: "utf8", maxBuffer: 1024 * 1024 * 5 }
    );
  } catch {
    diffStat = "";
  }
}

const truncationNote = truncated
  ? ` (Diff was truncated to fit the context limit. Below is a summary of all changed files for context, followed by the truncated diff.)\n\n**Changed files:**\n\`\`\`\n${diffStat.trim()}\n\`\`\``
  : "";

// --- Fetch helpers -------------------------------------------------------

const FETCH_TIMEOUT_MS = 90_000;
const MAX_RETRIES = 2;

// Wrap fetch with a timeout and retry-on-transient-failure logic.
async function fetchWithRetry(url, options, retries = MAX_RETRIES) {
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const res = await fetch(url, {
        ...options,
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      });
      // Retry on rate-limit (429) or server errors (5xx).
      if ((res.status === 429 || res.status >= 500) && attempt < retries) {
        const wait = 2000 * (attempt + 1) + Math.random() * 1000; // jitter
        console.warn(
          `[${PROVIDER_NAME}] ${res.status} from ${url}, retrying in ${Math.round(wait)}ms (attempt ${attempt + 1}/${retries})…`
        );
        await new Promise((r) => setTimeout(r, wait));
        continue;
      }
      return res;
    } catch (e) {
      if (attempt < retries) {
        const wait = 2000 * (attempt + 1) + Math.random() * 1000;
        console.warn(
          `[${PROVIDER_NAME}] Fetch error from ${url}, retrying in ${Math.round(wait)}ms (attempt ${attempt + 1}/${retries}): ${e.message}`
        );
        await new Promise((r) => setTimeout(r, wait));
        continue;
      }
      throw e;
    }
  }
}

// --- GitHub context ------------------------------------------------------

const [owner, repo] = GITHUB_REPOSITORY.split("/");
const marker = `<!-- ai-review:${PROVIDER_NAME} -->`;
const header = `${marker}\n## 🤖 ${PROVIDER_NAME} review — \`${MODEL}\``;
const truncNote = truncated
  ? "\n\n> ⚠️ The diff was truncated; some changes were not reviewed."
  : "";

// Unique HTML-comment sentinel separating the base review from each dated
// update section, so model-generated "### Update " text can't corrupt splits.
const SECTION_SENTINEL = "\n<!-- ai-review-section -->\n";

const apiBase = "https://api.github.com";
const ghHeaders = {
  Authorization: `Bearer ${GITHUB_TOKEN}`,
  Accept: "application/vnd.github+json",
  "Content-Type": "application/json",
};

// Find an existing comment from this reviewer, paginating through all pages
// so the marker is found even on PRs with >100 comments.
async function findExistingComment() {
  let page = 1;
  while (true) {
    const listRes = await fetchWithRetry(
      `${apiBase}/repos/${owner}/${repo}/issues/${PR_NUMBER}/comments?per_page=100&page=${page}`,
      { headers: ghHeaders }
    );
    if (!listRes.ok) {
      // Log the status so permission/rate-limit issues are discoverable, but
      // don't fail — fall through to creating a new comment.
      console.error(
        `[${PROVIDER_NAME}] Failed to list PR comments (page ${page}): ` +
        `${listRes.status} ${listRes.statusText}. Will create a new comment.`
      );
      return null;
    }
    const comments = await listRes.json();
    if (!Array.isArray(comments) || comments.length === 0) return null;
    const found = comments.find(
      (c) => typeof c.body === "string" && c.body.includes(marker)
    );
    if (found) return found;
    if (comments.length < 100) return null; // last page
    page++;
  }
}

// Strip the leading marker + "## 🤖 …" header line from a stored comment body,
// leaving just the review content (base review + any update sections).
function stripHeader(fullBody) {
  const lines = fullBody.split("\n");
  let i = 0;
  if (lines[i] !== undefined && lines[i].trim() === marker) i++;
  if (lines[i] !== undefined && lines[i].startsWith("## ")) i++;
  while (i < lines.length && lines[i].trim() === "") i++;
  return lines.slice(i).join("\n");
}

// Keep the comment under GitHub's 65536-char cap by dropping the oldest
// update sections first (the base review and newest updates are kept).
function trimToLimit(text, limit = 62000) {
  if (text.length <= limit) return text;

  // Split on the sentinel; if there are no sections, hard-slice the base.
  const parts = text.split(SECTION_SENTINEL);
  if (parts.length <= 1) return text.slice(0, limit);

  const head = parts[0];
  const kept = parts.slice(1); // each is an update section
  let dropped = 0;

  const trimmedNotice =
    "\n\n> _Older review updates were trimmed to fit GitHub's comment size limit._";

  // Drop oldest sections until we fit or only one section remains.
  while (
    kept.length > 1 &&
    (head + trimmedNotice + SECTION_SENTINEL + kept.join(SECTION_SENTINEL)).length > limit
  ) {
    kept.shift();
    dropped++;
  }

  let result =
    dropped === 0
      ? head + kept.map((s) => SECTION_SENTINEL + s).join("")
      : head + trimmedNotice + kept.map((s) => SECTION_SENTINEL + s).join("");

  // If the base review itself is oversized (even with all sections dropped),
  // or if we still exceed the limit, hard-slice as a last resort.
  if (result.length > limit) result = result.slice(0, limit);

  return result;
}

// Normalize text for fuzzy line matching (case- and whitespace-insensitive).
const normalize = (s) => s.toLowerCase().replace(/\s+/g, " ").trim();

// Appended to a struck point; also used to detect our own prior strikes. This
// is more precise than looking for "~~", which can appear legitimately in a base
// line (e.g. inside a code snippet) and would otherwise make it unstrikeable.
const STRIKE_MARK = "✅ addressed in";

// Wrap a line's content in strikethrough, preserving any list marker/indent.
function wrapStrike(line) {
  const listMatch = line.match(/^(\s*(?:[-*+]|\d+\.)\s+)(.*)$/);
  if (listMatch) return `${listMatch[1]}~~${listMatch[2]}~~`;
  const indentMatch = line.match(/^(\s*)(.*)$/);
  return `${indentMatch[1]}~~${indentMatch[2]}~~`;
}

// Given the first line of a matched point, return the index of its last line,
// extending across continuation/sub-lines (wrapped text, sub-bullets, code) but
// stopping at a blank line, a heading, or a sibling/parent list item.
function pointExtent(lines, i) {
  const startIndent = lines[i].match(/^\s*/)[0].length;
  let j = i;
  while (j + 1 < lines.length) {
    const next = lines[j + 1];
    if (next.trim() === "") break; // blank line ends the point
    if (/^\s*#{1,6}\s/.test(next)) break; // heading
    const nextIndent = next.match(/^\s*/)[0].length;
    const nextIsItem = /^\s*(?:[-*+]|\d+\.)\s/.test(next);
    if (nextIsItem && nextIndent <= startIndent) break; // sibling/parent item
    j++;
  }
  return j;
}

// Strike each base point matched by a model-supplied resolved-point snippet.
// Each snippet strikes at most one not-yet-struck point (which may span several
// lines); short/ambiguous snippets are skipped to avoid false positives.
function applyStrikes(base, snippets, sha) {
  const lines = base.split("\n");
  const used = new Set();
  let count = 0;
  for (const raw of snippets) {
    const snip = raw
      .replace(/^[-*+]\s+/, "") // drop a leading list marker
      .replace(/^["'`]+|["'`]+$/g, "") // drop wrapping quotes/backticks
      .trim();
    const needle = normalize(snip);
    if (needle.length < 12) continue; // too short to match safely
    for (let i = 0; i < lines.length; i++) {
      if (used.has(i) || lines[i].includes(STRIKE_MARK)) continue; // already resolved
      if (!normalize(lines[i]).includes(needle)) continue;
      const end = pointExtent(lines, i);
      for (let k = i; k <= end; k++) {
        if (lines[k].trim() !== "" && !lines[k].includes(STRIKE_MARK)) {
          lines[k] = wrapStrike(lines[k]);
        }
        used.add(k);
      }
      lines[end] += ` — ${STRIKE_MARK} ${sha}`;
      count++;
      break;
    }
  }
  return { base: lines.join("\n"), count };
}

const structuredOutput = STRUCTURED_OUTPUT === "true";

// Structured reviews are posted as real PR reviews (not issue comments), so the
// existing-comment lookup and revise machinery below are irrelevant to them.
const existing = structuredOutput ? null : await findExistingComment();

// Revise mode: we have a prior comment and only new commits to review, so the
// model reproduces its prior base review with resolved points struck through,
// then reviews the new commits separately. The two parts are split by a line
// containing exactly REVISE_SEPARATOR.
const REVISE_SEPARATOR = "---NEW-REVIEW---";
const reviseMode = incremental && !!existing && !structuredOutput;

let priorBase = "";
let priorUpdates = "";
if (reviseMode) {
  const content = stripHeader(existing.body);
  const parts = content.split(SECTION_SENTINEL);
  priorBase = parts[0];
  priorUpdates =
    parts.length > 1 ? SECTION_SENTINEL + parts.slice(1).join(SECTION_SENTINEL) : "";
}

// --- Build the prompt ----------------------------------------------------

const shortSha = HEAD_SHA.slice(0, 7);
const newCommitsNote =
  "If the new commits are trivial (docs, comments, formatting, minor tweaks) and " +
  "introduce no issues, output exactly: No notable changes. Otherwise review them " +
  "concisely, and note if a change appears to affect other parts of the PR.";

let userContent;
if (reviseMode) {
  userContent =
    "You previously reviewed this pull request. Two inputs follow: (A) the base " +
    "review you posted, and (B) the diff of the NEW commits pushed since then.\n\n" +
    `Respond with two parts separated by a line containing exactly \`${REVISE_SEPARATOR}\`:\n\n` +
    "PART 1 — List each earlier actionable point from (A) that the NEW commits now " +
    "FULLY address. Put each on its own line, quoting enough of that point's original " +
    "wording copied VERBATIM from (A) to identify it uniquely (do not paraphrase). " +
    "If none are addressed, write exactly: NONE\n\n" +
    `PART 2 — Review ONLY the new commits in (B). ${newCommitsNote}\n\n` +
    "=== (A) BASE REVIEW ===\n" +
    priorBase +
    `\n\n=== (B) NEW COMMITS DIFF ===${truncationNote}\n\n` +
    "```diff\n" +
    diff +
    "\n```";
} else {
  const scopeNote = incremental
    ? "This is an UPDATE to a pull request you have already reviewed. Below is only " +
      "the diff of the new commits pushed since your last review. Focus on these " +
      `changes. ${newCommitsNote}`
    : "Review this pull request diff.";
  userContent =
    `${scopeNote}${truncationNote}\n\n` + "```diff\n" + diff + "\n```";
}

// --- Call the OpenAI-compatible chat-completions endpoint -----------------

const endpoint = `${API_BASE.replace(/\/$/, "")}/chat/completions`;
let review;
let structuredReview = null;
try {
  const res = await fetchWithRetry(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${API_KEY}`,
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: maxTokens,
      ...(temperature !== undefined ? { temperature } : {}),
      // MiniMax can return its reasoning separately from the final answer.
      // This keeps a JSON-only reviewer prompt parseable in the comment body.
      ...(REASONING_SPLIT === "true" ? { reasoning_split: true } : {}),
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userContent },
      ],
    }),
  });

  if (!res.ok) {
    // Only log the status, not the body — some providers echo the request
    // (including the diff) on validation errors, which would leak into logs.
    fail(`API request to ${endpoint} failed with status ${res.status} (${res.statusText}).`);
  }

  let data;
  try {
    data = await res.json();
  } catch (e) {
    fail(
      `API response JSON parse error from provider "${PROVIDER_NAME}" at ${endpoint}: ` +
      `${e.name || "Error"}: ${e.message}`
    );
  }

  const choice = data?.choices?.[0];
  review = choice?.message?.content?.trim();
  if (!review) {
    // Reasoning models spend tokens on reasoning_content; if they hit the cap
    // first, content comes back empty. Skip cleanly with actionable guidance.
    // Some providers return finish_reason "stop" with empty content when
    // reasoning_content absorbs all output — treat that the same way.
    if (choice?.finish_reason === "length" || choice?.finish_reason === "stop") {
      console.log(
        `[${PROVIDER_NAME}] No review content produced (finish_reason: ${choice?.finish_reason}). ` +
        `If this persists, raise MAX_TOKENS. Skipping.`
      );
      process.exit(0);
    }
    fail(`Empty response from API: ${JSON.stringify(data).slice(0, 500)}`);
  }
  if (structuredOutput) structuredReview = parseStructuredReview(review);
} catch (e) {
  fail(
    `API call error (likely during fetch) from provider "${PROVIDER_NAME}" at ${endpoint}: ` +
    `${e.name || "Error"}: ${e.message}`
  );
}

// --- Structured mode: submit a real PR review ----------------------------

// Submit a review to the pulls API. Returns the fetch Response so the caller
// can degrade the payload on failure. fetchWithRetry only retries transient
// 429/5xx, so a 422 (bad line position, self-approval) returns immediately.
async function submitReview(event, reviewBody, comments) {
  return fetchWithRetry(
    `${apiBase}/repos/${owner}/${repo}/pulls/${PR_NUMBER}/reviews`,
    {
      method: "POST",
      headers: ghHeaders,
      body: JSON.stringify({
        event,
        body: reviewBody,
        ...(comments.length ? { comments } : {}),
      }),
    }
  );
}

if (structuredOutput) {
  const { verdict, summary, comments } = structuredReview;
  const { event, label } = VERDICT_MAP[verdict] || VERDICT_MAP.comment;

  // Anchor each finding to a diff line as an inline review comment. The reviews
  // API only accepts lines that fall inside the diff; anything else 422s the
  // whole review, so we fall back to folding findings into the body below.
  const inline = comments
    .filter((c) => c && c.file && Number.isInteger(c.line) && c.line > 0)
    .map((c) => ({
      path: c.file,
      line: c.line,
      side: "RIGHT",
      body: renderComment(c),
    }));

  const scopeNote = incremental ? " · _incremental review of new commits_" : "";
  const bodyBase = `${header}\n\n**Verdict:** ${label}${scopeNote}\n\n${summary}${truncNote}`;
  const findingsList = comments.length
    ? "\n\n### Findings\n\n" +
      comments.map((c) => `- ${renderComment(c, { withLocation: true })}`).join("\n\n")
    : "";
  const bodyWithFindings = bodyBase + findingsList;

  // Cascade: (1) verdict event + inline comments; (2) same event with findings
  // folded into the body (handles hallucinated/out-of-diff line numbers);
  // (3) downgrade to COMMENT (handles "can't approve/request-changes your own PR").
  let res = await submitReview(event, bodyBase, inline);
  if (!res.ok && inline.length) {
    console.warn(
      `[${PROVIDER_NAME}] Review with inline comments failed (${res.status}); ` +
      `retrying with findings in the body.`
    );
    res = await submitReview(event, bodyWithFindings, []);
  }
  if (!res.ok && event !== "COMMENT") {
    console.warn(
      `[${PROVIDER_NAME}] "${event}" review failed (${res.status}); ` +
      `downgrading to a COMMENT review.`
    );
    res = await submitReview("COMMENT", bodyWithFindings, []);
  }
  if (!res.ok) {
    fail(`Failed to submit review: ${res.status} ${res.statusText}`);
  }

  console.log(
    `[${PROVIDER_NAME}] Submitted ${event} review on PR #${PR_NUMBER} ` +
    `with ${inline.length} inline comment(s) (${incremental ? "incremental" : "full"}).`
  );
  process.exit(0);
}

// --- Assemble and post the comment body ----------------------------------

let body;
if (reviseMode) {
  // Split the response: PART 1 = resolved-point snippets, PART 2 = new review.
  const idx = review.indexOf(REVISE_SEPARATOR);
  let resolvedPart = "";
  let newReview = review;
  if (idx !== -1) {
    resolvedPart = review.slice(0, idx);
    newReview = review.slice(idx + REVISE_SEPARATOR.length).trim();
  }
  const snippets = resolvedPart
    .split("\n")
    .map((s) => s.trim())
    .filter((s) => s && s.toUpperCase() !== "NONE" && !/^part\b/i.test(s));

  // Strike the resolved points in the stored base (byte-exact; only matched
  // lines change), then append this push's review as a new dated section.
  const { base: struckBase, count } = applyStrikes(priorBase, snippets, shortSha);
  if (!newReview) newReview = "No notable changes.";
  const date = new Date().toISOString().slice(0, 16).replace("T", " ");
  const newSection = `${SECTION_SENTINEL}### Update ${shortSha} — ${date} UTC\n\n${newReview}${truncNote}`;
  body = trimToLimit(`${header}\n\n${struckBase}${priorUpdates}${newSection}`);
  console.log(`[${PROVIDER_NAME}] Struck ${count} resolved point(s) from the base review.`);
} else {
  // First run (or incremental with no prior comment): a full review sets the base.
  const opener = incremental
    ? `\n\n> _Base review unavailable; showing this push only._\n\n${review}${truncNote}`
    : `\n\n${review}${truncNote}`;
  body = `${header}${opener}`;
}

const target = existing
  ? `${apiBase}/repos/${owner}/${repo}/issues/comments/${existing.id}`
  : `${apiBase}/repos/${owner}/${repo}/issues/${PR_NUMBER}/comments`;

const postRes = await fetchWithRetry(target, {
  method: existing ? "PATCH" : "POST",
  headers: ghHeaders,
  body: JSON.stringify({ body }),
});

if (!postRes.ok) {
  fail(`Failed to post comment: ${postRes.status} ${postRes.statusText}`);
}

const verb = existing ? (reviseMode ? "revised + appended update to" : "reset") : "posted";
console.log(
  `[${PROVIDER_NAME}] Review ${verb} on PR #${PR_NUMBER} (${incremental ? "incremental" : "full"}).`
);

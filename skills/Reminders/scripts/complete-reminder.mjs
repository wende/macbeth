// @name complete-reminder
// @description Complete a reminder by id (or resolve by title) via EventKit bridge
// @usage node skills/Reminders/scripts/complete-reminder.mjs --id "<reminder-id>" [--title "Pay rent"] [--list "Personal"]
// @usage node skills/Reminders/scripts/complete-reminder.mjs --title "Pay rent" [--list "Personal"]

import { runNativeBridge } from "../../_shared/lib/native-bridge.mjs";

const args = process.argv.slice(2);
const id = getArg(args, "id");
const title = getArg(args, "title");
const list = getArg(args, "list");

if (!id && !title) {
  const items = listOpenReminders(list);
  fail("Missing --id or --title", {
    hint: 'Use --id "<reminder-id>" or --title "<reminder-title>"',
    candidates: items.slice(0, 10).map(toCandidate),
  });
}

let finalOut = null;

if (id) {
  finalOut = runNativeBridge(["reminders-complete", "--id", id]);
  if (finalOut?.ok) {
    console.log(JSON.stringify(finalOut, null, 2));
    process.exit(0);
  }
}

const items = listOpenReminders(list);
const match = resolveReminder(items, { id, title });

if (!match) {
  fail("Could not resolve reminder to complete", {
    requested: { id, title, list },
    candidates: items.slice(0, 10).map(toCandidate),
  });
}

finalOut = runNativeBridge(["reminders-complete", "--id", match.id]);
if (!finalOut?.ok) {
  console.log(JSON.stringify(finalOut, null, 2));
  process.exit(1);
}

console.log(
  JSON.stringify(
    {
      ...finalOut,
      resolvedBy: match.reason,
      resolvedReminder: toCandidate(match),
    },
    null,
    2,
  ),
);

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}

function listOpenReminders(listName) {
  const bridgeArgs = ["reminders-list"];
  if (listName) bridgeArgs.push("--list", listName);
  const out = runNativeBridge(bridgeArgs);
  if (!out?.ok || !Array.isArray(out.items)) return [];
  return out.items.filter((item) => !item.completed);
}

function resolveReminder(items, requested) {
  if (!Array.isArray(items) || items.length === 0) return null;
  const byId = requested.id
    ? items.find((item) => item.id === requested.id)
    : null;
  if (byId) return { ...byId, reason: "id" };

  if (!requested.title) return null;

  const query = normalize(requested.title);
  const exact = items.find((item) => normalize(item.title) === query);
  if (exact) return { ...exact, reason: "title-exact" };

  const contains = items.find((item) => normalize(item.title).includes(query));
  if (contains) return { ...contains, reason: "title-contains" };

  return null;
}

function normalize(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ");
}

function toCandidate(item) {
  return {
    id: item.id,
    title: item.title,
    list: item.list,
    due: item.due ?? null,
  };
}

function fail(error, extra = {}) {
  console.log(JSON.stringify({ ok: false, error, ...extra }, null, 2));
  process.exit(1);
}

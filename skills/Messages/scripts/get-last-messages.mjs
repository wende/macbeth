// @name get-last-messages
// @description Get recent conversations and optionally their messages from Messages.app
// @usage node scripts/get-last-messages.mjs [--since "2 days ago"] [--mode people|messages] [--limit 5]

import { connect } from "macbeth";

// --- Parse args ---

const args = process.argv.slice(2);

function getArg(name, fallback) {
  const i = args.indexOf(`--${name}`);
  return i !== -1 && i + 1 < args.length ? args[i + 1] : fallback;
}

const sinceStr = getArg("since", "7 days ago");
const mode = getArg("mode", "messages"); // "people" or "messages"
const limit = parseInt(getArg("limit", "5"), 10);

const sinceDate = parseSince(sinceStr);

function parseSince(str) {
  const direct = new Date(str);
  if (!isNaN(direct.getTime()) && str.includes("-")) return direct;

  const m = str.match(/^(\d+)\s+(minute|hour|day|week|month)s?\s+ago$/i);
  if (m) {
    const n = parseInt(m[1], 10);
    const unit = m[2].toLowerCase();
    const ms = {
      minute: 60_000,
      hour: 3_600_000,
      day: 86_400_000,
      week: 604_800_000,
      month: 2_592_000_000,
    };
    return new Date(Date.now() - n * ms[unit]);
  }

  const parsed = new Date(str);
  if (!isNaN(parsed.getTime())) return parsed;

  console.error(`Cannot parse since date: "${str}". Using 7 days ago.`);
  return new Date(Date.now() - 7 * 86_400_000);
}

function parseConversationDate(label) {
  const parts = label.split(", ");
  if (parts.length < 2) return null;

  const datePart = parts[parts.length - 1].trim();
  if (!datePart || datePart === "Pinned") return null;

  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());

  if (datePart === "Yesterday") return new Date(today.getTime() - 86_400_000);

  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const dayIdx = days.indexOf(datePart);
  if (dayIdx !== -1) {
    let diff = today.getDay() - dayIdx;
    if (diff <= 0) diff += 7;
    return new Date(today.getTime() - diff * 86_400_000);
  }

  const dmyMatch = datePart.match(/^(\d{2})\.(\d{2})\.(\d{4})$/);
  if (dmyMatch) {
    return new Date(parseInt(dmyMatch[3]), parseInt(dmyMatch[2]) - 1, parseInt(dmyMatch[1]));
  }

  const parsed = new Date(datePart);
  return isNaN(parsed.getTime()) ? null : parsed;
}

// --- Main ---

const app = await connect("Messages");
const win = app.locator({ role: "window" });
const convList = win.locator({ role: "group", identifier: "ConversationList" });
const searchField = win
  .locator({ role: "group", identifier: "CKConversationListCollectionView" })
  .locator({ role: "text_field" });
const transcript = win.locator({ role: "group", identifier: "TranscriptCollectionView" });

const results = [];

// Phase 1: Enumerate conversations from the sidebar
for (let i = 0; ; i++) {
  let info;
  try {
    info = await convList.locator({ role: "text", index: i }).getInfo();
  } catch {
    break;
  }

  const label = info.label ?? "";

  if (label.endsWith(", Pinned")) {
    const weekAgo = new Date(Date.now() - 7 * 86_400_000);
    if (sinceDate > weekAgo) continue;
    results.push({ name: label.replace(", Pinned", ""), pinned: true, date: null, messages: [] });
    continue;
  }

  const convDate = parseConversationDate(label);
  if (convDate && convDate < sinceDate) break;

  const name = label.split(", ")[0];
  results.push({ name, pinned: false, date: convDate, messages: [] });
}

// Phase 2: For each conversation, navigate via search and read messages
if (mode === "messages") {
  for (const conv of results) {
    try {
      // Navigate: type name in search, click first result, then clear search
      await searchField.fill(conv.name);
      await new Promise((r) => setTimeout(r, 400));

      // Click the first search result
      try {
        await convList.locator({ role: "text", index: 0 }).click({ timeout: 3000 });
      } catch {
        // If click on text doesn't work, try pressing Return to select
        await app.pressKey("return");
      }
      await new Promise((r) => setTimeout(r, 300));

      // Clear search by pressing Escape
      await app.pressKey("escape");
      await new Promise((r) => setTimeout(r, 200));

      // Verify we're in the right conversation by checking the title
      let titleInfo;
      try {
        titleInfo = await win.locator({ role: "button", identifier: "ConversationTitle" }).getInfo();
      } catch {
        console.error(`Could not verify conversation: ${conv.name}`);
        continue;
      }

      // Wait for transcript to load
      let loaded = false;
      for (let attempt = 0; attempt < 8; attempt++) {
        try {
          await transcript.locator({ role: "group", identifier: "Sticker", index: 0 }).getInfo();
          loaded = true;
          break;
        } catch {
          await new Promise((r) => setTimeout(r, 250));
        }
      }

      if (!loaded) {
        console.error(`Transcript did not load for: ${conv.name}`);
        continue;
      }

      // Binary search for total message count
      let lo = 0, hi = 200;
      while (true) {
        try {
          await transcript.locator({ role: "group", identifier: "Sticker", index: hi - 1 }).getInfo();
          hi *= 2;
        } catch {
          break;
        }
      }
      while (lo < hi) {
        const mid = Math.floor((lo + hi) / 2);
        try {
          await transcript.locator({ role: "group", identifier: "Sticker", index: mid }).getInfo();
          lo = mid + 1;
        } catch {
          hi = mid;
        }
      }
      const total = lo;

      // Read last `limit` messages
      const startIdx = Math.max(0, total - limit);
      for (let j = startIdx; j < total; j++) {
        try {
          const sticker = transcript.locator({ role: "group", identifier: "Sticker", index: j });
          const stickerInfo = await sticker.getInfo();
          const stickerLabel = stickerInfo.label ?? "";

          let text;
          try {
            const balloon = await sticker
              .locator({ role: "text_area", identifier: "CKBalloonTextView" })
              .getInfo();
            text = balloon.value;
          } catch {
            text = null;
          }

          const isMe = stickerLabel.startsWith("Your ");
          conv.messages.push({ from: isMe ? "me" : conv.name, text });
        } catch {
          break;
        }
      }
    } catch (err) {
      console.error(`Error reading ${conv.name}: ${err.message}`);
    }
  }
}

// --- Output ---

const output = results.map((conv) => {
  const entry = {
    name: conv.name,
    ...(conv.pinned && { pinned: true }),
    ...(conv.date && { date: conv.date.toISOString().split("T")[0] }),
  };
  if (mode === "messages" && conv.messages.length > 0) {
    entry.messages = conv.messages.map((m) => ({
      from: m.from,
      text: m.text ?? "(attachment or non-text)",
    }));
  }
  return entry;
});

console.log(JSON.stringify(output, null, 2));

process.exit(0);

// @name search-contacts
// @description Search contacts using CNContactStore bridge
// @usage node skills/Contacts/scripts/search-contacts.mjs [--query "john"] [--limit 20]

import { runNativeBridge } from "macbeth";

const args = process.argv.slice(2);
const query = getArg(args, "query") ?? "";
const limit = getArg(args, "limit") ?? "20";

let out;
try {
  out = runNativeBridge([
    "contacts-search",
    "--query", query,
    "--limit", limit,
  ]);
} catch (err) {
  out = { ok: false, error: err.message };
}

// The native bridge returns its own JSON error document on failure, so a
// permission denial normally reaches this point without throwing.  Normalize
// both bridge and process errors into the same actionable result.
if (out?.ok === false && /permission denied/i.test(String(out.error ?? ""))) {
  out.hint = "Grant access in System Settings > Privacy & Security > Contacts, then retry.";
}

console.log(JSON.stringify(out, null, 2));
if (out?.ok === false) process.exit(1);

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}

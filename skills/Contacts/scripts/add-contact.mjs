// @name add-contact
// @description Create a contact via CNContactStore bridge
// @usage node skills/Contacts/scripts/add-contact.mjs --given "Ada" [--family "Lovelace"] [--email "ada@example.com"] [--phone "+48123123123"]

import { runNativeBridge } from "../../_shared/lib/native-bridge.mjs";

const args = process.argv.slice(2);
const given = getArg(args, "given");
if (!given) {
  console.error("Missing required --given");
  process.exit(1);
}

const bridgeArgs = ["contacts-add", "--given", given];
const family = getArg(args, "family");
const email = getArg(args, "email");
const phone = getArg(args, "phone");

if (family) bridgeArgs.push("--family", family);
if (email) bridgeArgs.push("--email", email);
if (phone) bridgeArgs.push("--phone", phone);

let out;
try {
  out = runNativeBridge(bridgeArgs);
} catch (err) {
  out = { ok: false, error: err.message };
  if (/permission denied/i.test(err.message)) {
    out.hint = "Grant access in System Settings > Privacy & Security > Contacts, then retry.";
  }
}

console.log(JSON.stringify(out, null, 2));
if (out?.ok === false) process.exit(1);

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}

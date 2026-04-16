// @name transport
// @description Control Logic Pro transport (play, stop, record, metronome, cycle)
// @usage node skills/LogicPro/scripts/transport.mjs --action play|stop|record|metronome|cycle|count-in

import { connect } from "macbeth";

const args = process.argv.slice(2);
const action = getArg(args, "action");
if (!action) {
  console.error("Missing required --action (play|stop|record|metronome|cycle|count-in)");
  process.exit(1);
}

const app = await connect("Logic Pro");

const actions = {
  play: () => app.checkbox("Play").click(),
  stop: () => app.button("Stop").click(),
  record: () => app.checkbox("Record").click(),
  metronome: () => app.checkbox("Metronome Click").click(),
  cycle: () => app.checkbox("Cycle").click(),
  "count-in": () => app.checkbox("Count In").click(),
};

const fn = actions[action];
if (!fn) {
  console.error(`Unknown action: ${action}. Use: ${Object.keys(actions).join(", ")}`);
  process.exit(1);
}

await fn();

// Read back state for toggleable controls
if (action !== "stop") {
  const el = await app.locator({
    role: action === "stop" ? "button" : "checkbox",
    title: {
      play: "Play",
      record: "Record",
      metronome: "Metronome Click",
      cycle: "Cycle",
      "count-in": "Count In",
    }[action],
  }).getInfo();
  console.log(JSON.stringify({ ok: true, action, value: el.value }, null, 2));
} else {
  console.log(JSON.stringify({ ok: true, action: "stop" }, null, 2));
}

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}

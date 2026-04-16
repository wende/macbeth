// @name set-tempo
// @description Set Logic Pro project tempo
// @usage node skills/LogicPro/scripts/set-tempo.mjs --bpm 140

import { connect } from "macbeth";

const args = process.argv.slice(2);
const bpm = getArg(args, "bpm");
if (!bpm) {
  console.error("Missing required --bpm");
  process.exit(1);
}

const bpmNum = Math.round(parseFloat(bpm));
if (!Number.isFinite(bpmNum) || bpmNum < 5 || bpmNum > 990) {
  console.error("BPM must be an integer between 5 and 990");
  process.exit(1);
}

const app = await connect("Logic Pro");

// The tempo is the first slider found in the window (label: "Tempo")
const tempoSlider = app.locator({ role: "window" }).locator({ role: "slider", index: 0 });

await tempoSlider.fill(String(bpmNum));

const info = await tempoSlider.getInfo();
console.log(JSON.stringify({ ok: true, bpm: parseInt(info.value, 10) }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}

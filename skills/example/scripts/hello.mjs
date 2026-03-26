// @name hello
// @description Opens TextEdit and types a greeting
// @usage node scripts/hello.mjs [name]

import { connect } from "macbeth";

const name = process.argv[2] ?? "World";

const app = await connect("TextEdit");
await app.window("Untitled").textField().fill(`Hello, ${name}!`);

console.log(`Typed greeting for ${name}`);

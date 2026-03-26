---
name: example
description: Example skill showing the SKILL.md format
---

# Example Skill

This is a template showing the expected SKILL.md format.

## How to use

A skill file provides instructions that get loaded into the conversation context when `load_skill` is called. Write your skill as a set of instructions for automating a specific app or workflow.

## Structure

```
skills/
  my-skill/
    SKILL.md          # Required — the skill instructions
    scripts/          # Optional — runnable .mjs scripts
      do-thing.mjs
      another.mjs
```

## SKILL.md Format

- **Frontmatter** (`---` block): Must include `name` and `description` fields. The description is shown by `list_skills`.
- **Body**: Free-form markdown with instructions, query examples, step-by-step workflows, etc.

## Script Format

Scripts are `.mjs` files in the `scripts/` directory. Add metadata with comment tags at the top:

```js
// @name create-note
// @description Creates a new note with the given title and body
// @usage node scripts/create-note.mjs "Title" "Body text"

import { connect } from "macbeth";

const [title, body] = process.argv.slice(2);
const app = await connect("Notes");
// ... automation steps
```

- `@name` — display name (defaults to filename without extension)
- `@description` — what the script does
- `@usage` — how to run it with arguments

Scripts are listed by `list_skills` and `load_skill`, and can be executed via `run_skill_script`.

## Example: Automating Notes.app

```markdown
---
name: notes
description: Create, search, and edit notes in Apple Notes
---

# Notes.app Automation

## Connect
Always connect with: `connect_app({ name: "Notes" })`

## Common Queries
- New note button: `[{ role: "button", title: "New Note" }]`
- Note editor: `[{ role: "text_field", identifier: "note-body" }]`

## Workflow: Create a Note
1. connect_app "Notes"
2. click the "New Note" button
3. fill the editor with content
```

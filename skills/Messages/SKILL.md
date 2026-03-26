---
name: messages
description: Browse conversations, read messages, and send texts in Apple Messages
---

# Messages.app Automation

## Connect

```
connect_app({ name: "Messages" })
```

## Layout

Messages has a two-pane layout: conversation list (left) and transcript (right).

- **Window title** reflects the currently open conversation's contact name.
- The window identifier is always `SceneWindow`.

## Key Elements

### Toolbar

| Query | Label | Action |
|---|---|---|
| `[{role:"window"}, {role:"toolbar"}, {role:"button"}]` | Compose | Start new conversation |
| `[{role:"window"}, {role:"toolbar"}, {role:"menu_button", index:0}]` | filter | Filter: Messages / Spam / Recently Deleted |
| `[{role:"window"}, {role:"toolbar"}, {role:"menu_button", index:1}]` | Start FaceTime | Call menu |

### Search

```json
[{"role":"window"}, {"role":"group", "identifier":"CKConversationListCollectionView"}, {"role":"text_field"}]
```
Label: "Search". Use `fill` to type a search query.

### Conversation List

Container:
```json
[{"role":"window"}, {"role":"group", "identifier":"ConversationList"}]
```

Each conversation is a `text` element. Iterate with `index`:

```json
[{"role":"window"}, {"role":"group", "identifier":"ConversationList"}, {"role":"text", "index": N}]
```

- **Pinned contacts** come first (indices 0, 1, 2, ...). Label format: `"Name, Pinned"`
- **Regular conversations** follow. Label format: `"Name, Preview text, Date"`

The `label` field contains all info — contact name, last message preview, and timestamp are comma-separated.

To open a conversation, `click` the text element at the desired index.

### Conversation Title

```json
[{"role":"window"}, {"role":"button", "identifier":"ConversationTitle"}]
```

Shows the currently open contact's name in `label`. Click to view contact details.

### Message Transcript

Container:
```json
[{"role":"window"}, {"role":"group", "identifier":"TranscriptCollectionView"}]
```

Two types of children:

**Date/time separators** — `text` elements. Iterate with `index`:
```json
[..., {"role":"text", "index": N}]
```
Label examples: `"Nov 6, 2022 at 16:30"`, `"Sun, Mar 1 at 00:50"`

**Message bubbles** — `group` elements with `identifier: "Sticker"`. Iterate with `index`:
```json
[..., {"role":"group", "identifier":"Sticker", "index": N}]
```

- The group's `label` contains a summary: `"Your iMessage, message text, time"` or `"Contact name, message text, time"`. Use this to determine sender and direction.
- For the full message text, go one level deeper:
  ```json
  [..., {"role":"group", "identifier":"Sticker", "index": N}, {"role":"text_area", "identifier":"CKBalloonTextView"}]
  ```
  The `value` field has the complete message content.

### Message Input

Container:
```json
[{"role":"window"}, {"role":"group", "identifier":"MessageEntryView"}]
```

| Query (from MessageEntryView) | Label | Purpose |
|---|---|---|
| `{"role":"text_field", "identifier":"messageBodyField"}` | Message / iMessage | Text input |
| `{"role":"button", "index":0}` | add | Attachment picker (+) |
| `{"role":"button", "index":1}` | Record audio | Voice message |
| `{"role":"button", "index":2}` | Emoji picker | Emoji keyboard |

### Useful Menu Items

| Path | Action |
|---|---|
| `File > New Message` (id: `new_message`) | Cmd+N — new conversation |
| `Edit > Send Message` (id: `keyCommandSend:`) | Send the composed message |
| `Conversation > Delete Conversation…` (id: `keyCommandDeleteConversation:`) | Delete current conversation |
| `Conversation > Mark as Unread` (id: `keyCommandToggleUnreadState:`) | Toggle unread state |
| `View > Show Times` (id: `keyCommandToggleTimeStamp:`) | Show/hide timestamps |

## Workflows

### List all conversations

```
for index 0..N:
  get_element [window, {group id:"ConversationList"}, {text, index}]
  → read label
  stop when error (no more items)
```

### Open a conversation by name

```
# Option A: iterate and match
for index 0..N:
  get_element [window, {group id:"ConversationList"}, {text, index}]
  if label starts with "TargetName," → click it

# Option B: use search
fill [window, {group id:"CKConversationListCollectionView"}, {text_field}] with "TargetName"
wait_for [window, {group id:"ConversationList"}, {text}]
click [window, {group id:"ConversationList"}, {text, index:0}]
```

### Read message history

```
for index 0..N:
  get_element [window, {group id:"TranscriptCollectionView"}, {group id:"Sticker", index}]
  → label gives sender + preview + time
  optionally read full text from child text_area id:"CKBalloonTextView"
```

### Send a message

```
fill [window, {group id:"MessageEntryView"}, {text_field id:"messageBodyField"}] with "Hello!"
press_key "return"
```

### Start a new conversation

```
click [window, toolbar, button]  # Compose
# A "To:" field appears — type the recipient
# Then fill the message body and press Return
```

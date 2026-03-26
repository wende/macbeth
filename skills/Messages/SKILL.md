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

To open a conversation, the user must click it manually — see Gotchas below.

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
- **SMS messages** may not have a `CKBalloonTextView` child. In that case, extract the text from the Sticker group's `label` — the format is `"Sender, message text, time"`, so strip the first and last comma-separated segments.

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

## Gotchas

### Clicking conversation items causes multi-select

Messages uses a SwiftUI list for the conversation sidebar. Synthesized CGEvent clicks (coordinate-based) are always interpreted as Cmd+click, causing multi-select instead of switching conversations. This is a macOS-level behavior — physical hardware clicks work, synthesized ones don't. **No workaround exists at the CGEvent level.**

**Consequence:** You cannot programmatically switch between conversations. You can only read from the **currently open** conversation.

**What to do:** Ask the user to manually open the conversation you need, then read its messages. Or use the search field + keyboard navigation as a partial workaround (fill search, press Down, press Return — results vary).

### SMS bubbles lack CKBalloonTextView

iMessage bubbles have a `text_area id:"CKBalloonTextView"` child with the full text in `value`. SMS bubbles may not. Fall back to parsing the Sticker group's `label` field: format is `"Sender, message text, time"` — strip the first and last comma-separated segments to get the message body.

### press_key activates the target app first

`press_key` still posts keyboard events through the system-wide HID event tap, but Macbeth now activates the requested app first. In practice the keypress should land in Messages, though macOS can still misroute it if the system steals focus between activation and delivery.

### Pinned contacts have no date in label

Pinned conversation items have label format `"Name, Pinned"` with no date or preview text. You cannot determine when the last message was sent without opening the conversation.

### Search results appear in a popover

When you `fill` the search field, results appear in a `popover > scroll_area > table > row` structure — **not** inside the ConversationList. The popover rows don't support AXPress. Use keyboard navigation (Down arrow + Return) to select a search result — but note this depends on the app being frontmost.

## Workflows

### List all conversations

```
for index 0..N:
  get_element [window, {group id:"ConversationList"}, {text, index}]
  → read label (name, preview, date are comma-separated)
  stop when error (no more items)
```

### Read messages from the currently open conversation

```
# Check which conversation is open
get_element [window, {button id:"ConversationTitle"}]
→ label contains the contact name

# Read messages (oldest-first, iterate with index)
for index 0..N:
  get_element [window, {group id:"TranscriptCollectionView"}, {group id:"Sticker", index}]
  → label gives sender + text + time
  # For full text (iMessage):
  get_element [..., {text_area id:"CKBalloonTextView"}] → value
  # For SMS (no CKBalloonTextView): parse label instead
```

### Send a message (in the currently open conversation)

```
fill [window, {group id:"MessageEntryView"}, {text_field id:"messageBodyField"}] with "Hello!"
press_key "return"
```

### Start a new conversation

```
click [window, toolbar, button]  # Compose (AXPress works on buttons)
# A "To:" field appears — fill with the recipient name/number
# Then fill the message body and press Return
```

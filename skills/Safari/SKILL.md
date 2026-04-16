---
name: safari
description: Navigate, search, click links, read content, and manage tabs in Safari
---

# Safari Automation

## Connect

Always connect with: `connect_app({ name: "Safari" })`

## Key Concepts

Safari's AX tree has two main areas:

1. **Chrome** (toolbar, tabs, menus) — native macOS UI elements
2. **Web content** — a `web_area` element containing the page's DOM-like accessibility tree (headings, links, groups, text, lists, tables, etc.)


## Navigation

**Navigate to a URL** — `fill` on the address bar sets the AX value but does NOT trigger navigation. Use `open` via shell instead:

```bash
open -a Safari "https://example.com"
```

Or with the macbeth SDK:
```js
import { execSync } from "node:child_process";
execSync('open -a Safari "https://example.com"');
```

**Read current URL:**
```json
{ "query": [
    { "role": "window" },
    { "role": "toolbar" },
    { "role": "text_field", "identifier": "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" }
]}
```
The `value` field contains the current URL.

**Back / Forward:** Click the toolbar buttons:
```json
{ "query": [{ "role": "window" }, { "role": "toolbar" }, { "role": "button", "identifier": "BackButton" }] }
{ "query": [{ "role": "window" }, { "role": "toolbar" }, { "role": "button", "identifier": "ForwardButton" }] }
```

**Reload:** `select_menu_item({ app: "Safari", menuPath: ["View", "Reload Page"] })` or click `ReloadButton`

## Common Queries

### Toolbar Buttons
| Element | Query |
|---|---|
| Address bar | `[{ "role": "window" }, { "role": "toolbar" }, { "role": "text_field", "identifier": "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" }]` |
| Back | `[{ "role": "window" }, { "role": "toolbar" }, { "role": "button", "identifier": "BackButton" }]` |
| Forward | `[{ "role": "window" }, { "role": "toolbar" }, { "role": "button", "identifier": "ForwardButton" }]` |
| Reload | `[{ "role": "window" }, { "role": "toolbar" }, { "role": "button", "identifier": "ReloadButton" }]` |
| New Tab | `[{ "role": "window" }, { "role": "toolbar" }, { "role": "button", "identifier": "NewTabButton" }]` |
| Share | `[{ "role": "window" }, { "role": "toolbar" }, { "role": "button", "identifier": "ShareButton" }]` |
| Sidebar | `[{ "role": "window" }, { "role": "toolbar" }, { "role": "button", "identifier": "SidebarButton" }]` |
| Tab Overview | `[{ "role": "window" }, { "role": "toolbar" }, { "role": "button", "identifier": "TabOverviewButton" }]` |

### Web Content
Queries use recursive descent — you don't need to specify every intermediate container. Just scope to `web_area` and target the element directly:

- **Click a link:** `[{ "role": "window" }, { "role": "web_area" }, { "role": "link", "title": "Sign in" }]`
- **Click a link by pattern:** `[{ "role": "window" }, { "role": "web_area" }, { "role": "link", "titlePattern": "Learn.*more" }]`
- **Read a heading:** `[{ "role": "window" }, { "role": "web_area" }, { "role": "heading", "title": "Example Domain" }]`
- **Find a text field:** `[{ "role": "window" }, { "role": "web_area" }, { "role": "text_field" }]`
- **Find a button:** `[{ "role": "window" }, { "role": "web_area" }, { "role": "button", "title": "Submit" }]`

Use `index` to disambiguate when multiple elements match:
```json
[{ "role": "window" }, { "role": "web_area" }, { "role": "link", "titlePattern": "comments", "index": 2 }]
```

### Tabs
Tabs are `radio` elements inside an `opaqueprovidergroup` (TabBar):
```json
[{ "role": "window" }, { "role": "opaqueprovidergroup" }, { "role": "radio", "title": "Example Domain" }]
```
- Active tab has `value: "1"`, inactive tabs have `value: "0"`
- Each tab has a close button child

## Menu Actions

Use `select_menu_item` instead of `press_key` — it doesn't steal focus.

| Action | Menu path |
|---|---|
| New tab | `["File", "New Tab"]` |
| Close tab | `["File", "Close Tab"]` |
| New window | `["File", "New Window"]` |
| New private window | `["File", "New Private Window"]` |
| Find on page | `["Edit", "Find", "Find…"]` |
| Back | `["History", "Back"]` |
| Forward | `["History", "Forward"]` |
| Reopen closed tab | `["History", "Reopen Last Closed Tab"]` |
| Show all history | `["History", "Show All History"]` |
| Reload | `["View", "Reload Page"]` |
| Zoom in | `["View", "Zoom In"]` |
| Zoom out | `["View", "Zoom Out"]` |
| Actual size | `["View", "Actual Size"]` |
| Next tab | `["Window", "Show Next Tab"]` |
| Previous tab | `["Window", "Show Previous Tab"]` |

## Gotchas

1. **Address bar click fails** — Safari's address bar does not support `AXPress`. Use `fill` to set its value, or `open -a Safari <url>` to navigate.
2. **fill on address bar doesn't navigate** — It sets the AX value but Safari ignores it for navigation. Use `open -a Safari <url>` instead.
3. **query_tree on web pages can be huge** — Use `maxDepth: 4-5` to keep output manageable. For the web content area specifically, the DOM adds several levels of nesting.
5. **Page load timing** — After navigation, use `wait_for` on a known page element to confirm the page has loaded before interacting.

## Workflows

### Navigate and Read Page Content
1. `open -a Safari "https://example.com"` (shell)
2. `wait_for` a known element on the target page
3. `query_tree` with `maxDepth: 6-8` to see the page structure
4. Use `get_element` to read specific text values

### Fill and Submit a Form
1. Navigate to the page
2. `query_tree` to find form fields
3. `fill` each text field (web form fields DO support fill, unlike the address bar)
4. `click` the submit button

### Switch Tabs
1. Click a tab by title: `[{ "role": "window" }, { "role": "opaqueprovidergroup" }, { "role": "radio", "title": "Tab Title" }]`
2. Or via menu: `select_menu_item({ app: "Safari", menuPath: ["Window", "Show Next Tab"] })`

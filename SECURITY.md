# Security

Macbeth can observe application interfaces and perform actions with the authority of the user who runs it. Treat access to the Macbeth MCP server as access to your Mac session.

## Security model

The MCP server communicates with its client over stdio. It starts `macbethd`, a local Swift daemon that listens on a Unix-domain socket at the configured path (by default, a per-user name in the macOS temporary directory). Macbeth does not open a TCP listener or include a remote-control service.

The Unix socket does not authenticate individual requests. A local process that can connect to it can call daemon methods, so Macbeth should not be treated as an isolation boundary on a shared or already-compromised Mac.

The published npm package includes signed and notarized universal daemon binaries. No login item is installed. Clients start or reuse the daemon when needed; `MacbethClient.close()` shuts down a daemon process started by that client, while a reused daemon may remain warm.

## Permissions

| Permission | Enables | Required when |
|---|---|---|
| Accessibility | Inspect UI trees; click, fill, wait, and send keyboard input | Using UI inspection or interaction |
| Screen Recording | Capture application windows for screenshots and OCR | Calling screenshot or window-OCR tools |
| Application-specific permissions | Data access used by AppleScript, Shortcuts, or skill scripts | A selected integration requests it |

macOS permissions apply to the responsible binary or host application. Grant only the permissions required for the workflow you intend to run.

## Data handling

- Accessibility trees, OCR results, form values, and script output are returned to the MCP client that requested them. The connected agent or model may handle that data according to its own product and privacy policy.
- Window OCR uses Apple's Vision framework on the Mac. Window capture uses ScreenCaptureKit.
- The MCP `screenshot` tool writes PNG files under a `macbeth-screenshots` directory in the current macOS temporary directory. Macbeth does not automatically remove those files.
- Macbeth does not implement product analytics or telemetry. The explicit `macbeth update` command contacts the GitHub Releases API and may invoke npm to install a release.
- Verbose daemon logging can include JSON-RPC request and response data. Do not enable it around sensitive content unless you also protect the logs.

These statements cover Macbeth itself. They do not cover an MCP client, agent provider, model host, Apple Shortcut, AppleScript target, third-party application, or user-contributed skill.

## Consequential actions

The following interfaces can change data or trigger external effects:

- clicks, text entry, keyboard shortcuts, and menu selection;
- AppleScript and JXA;
- Apple Shortcuts;
- runnable scripts bundled with application skills.

The interaction glow indicates many Macbeth-driven interactions on screen. It improves visibility but does not authorize an action, guarantee that every side effect is visible, or provide a durable audit log.

Recommended operating practices:

1. Connect Macbeth only to MCP clients and agents you trust.
2. Require confirmation before deleting, sending, publishing, purchasing, changing security settings, or exposing private information.
3. Prefer read-only inspection before mutation, and ask the agent to verify the resulting state.
4. Review skill instructions and runnable scripts before adding or executing third-party skills.
5. Do not expose or forward the daemon socket to other machines.
6. Avoid verbose logs and retained screenshots when working with sensitive applications.

## Revoke access

1. Remove Macbeth from the MCP client's configuration and quit that client.
2. Stop any remaining `macbethd` process.
3. In **System Settings → Privacy & Security**, remove Macbeth, its daemon, or the relevant terminal/client from **Accessibility** and **Screen & System Audio Recording**.
4. Delete Macbeth screenshot files from the `macbeth-screenshots` directory in your macOS temporary folder if they contain sensitive content.
5. Revoke any application-specific permissions granted to Shortcuts, AppleScript targets, Calendar, Contacts, or other integrations used by a skill.

## Report a vulnerability

Do not publish exploit details in a public issue before the maintainer has had a reasonable opportunity to investigate. Use GitHub private vulnerability reporting when it is available for this repository; otherwise contact the maintainer privately through the repository owner profile. Include the affected version, macOS version, reproduction steps, impact, and any suggested mitigation.

Use normal [GitHub issues](https://github.com/wende/macbeth/issues) for non-sensitive bugs and hardening suggestions.

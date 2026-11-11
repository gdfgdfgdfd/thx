# TermAI

An AI agent for iPhone that works on your servers. Point it at any OpenAI-compatible endpoint (base URL, API key, model IDs) and give it a task. The agent can run commands on your servers over SSH, read and write files in an on-device workspace, and fetch URLs.

## Install

Every push builds an unsigned IPA on GitHub Actions.

1. Open the latest **Build** run under the repository's *Actions* tab.
2. Download the `TermAI-unsigned-ipa` artifact and unzip it.
3. Sign and install `TermAI-unsigned.ipa` with your sideloading tool (AltStore, Sideloadly, TrollStore, or your own certificate).

The same run uploads a `screenshots` artifact with every screen of the app.

## Use

First launch: tap **Add a connection** and fill in the gateway's base URL, API key and models (or type `/setup` to be asked for them one by one). SSH hosts are added in Settings.

**The chat.** Type a task in the message box. The round button sends, and stops the run while the agent is working.

- Tool calls fold into a list with one line per step; tap a step for its output. A list of more than five steps shows the newest three until you tap **Show all**.
- Code blocks and tool output have a **Copy** button. The agent is told to put anything you may want to copy in a code block.
- **Edit and resend**: the pencil under your last message, or touch and hold any message. Sending replaces that message and the replies after it. The ↻ under the last answer resends the message unchanged.
- **+** attaches files, either from the device or from the workspace. Text files up to 48 KB are sent with the message; larger ones the agent reads on demand; binary files are only saved.
- The model name opens the model picker. Any model ID can be typed in there.
- Below the message box: the SSH host the agent works on, and whether it asks before acting (**Manual**) or not (**Auto**).

**The sidebar** (top left button):

- **New session**, and **Recents** to switch between saved sessions. Touch and hold a session to rename or delete it.
- **Search** finds a session by its title or by anything said in it.
- **Files** is the workspace: files the agent wrote and files you imported. Tap files to select them and **Done** adds them to your message; the chevron previews a file.
- **Terminal** is a plain SSH terminal on the selected host. What you run there stays out of the chat.
- At the bottom: the active connection, and Settings.

**Connections** (Settings) have a name, base URL, API key, auth scheme (`Authorization: Bearer` or an `x-api-key` header), custom headers, and a list of model IDs that can be fetched from the endpoint. **Test connection** checks what is typed in before you save.

On iOS 26 the bars, the message box and the approval card are Liquid Glass; earlier versions get a blurred card instead.

### Commands

Typing `/` in the message box lists these.

| Input | What it does |
| --- | --- |
| `!uptime` | run a command on the selected SSH host yourself, and show the agent the result |
| `/model [id]` | list or switch models |
| `/profile [name]` | list or switch connections |
| `/host [name\|off]` | list or switch SSH hosts |
| `/approve [ask\|auto]` | whether tool calls need your OK |
| `/theme [id]` | `dark`, `light`, `crt-green`, `crt-amber` |
| `/system [text\|reset]` | custom system prompt |
| `/new`, `/sessions [n]`, `/retry` | session control |
| `/copy`, `/export`, `/clear` | copy the last answer, share as Markdown, clear the screen |
| `/setup`, `/config` | add a connection step by step, open Settings |

A key row appears with the keyboard: `esc`, `/`, `!`, history `↑ ↓`, `tab` (complete a command) and `paste`.

## Safety model

- **Approval.** In the default Manual mode every SSH command, file write and web request waits for **Allow**, **Deny** or **Always allow** (for the rest of the session). Reading workspace files does not ask.
- **Secrets.** API keys, custom headers, passwords and private keys are stored in the iOS Keychain (this device only). They are never written to the JSON settings files.
- **Host keys.** The first connection to a host records its key (the fingerprint is shown); later connections are refused if the key changes.
- **Workspace.** File tools are confined to the app's Documents folder, visible in Files › On My iPhone › TermAI.
- **Network.** The app talks only to the endpoints and hosts you configure. Plain-`http` endpoints are allowed for LAN servers such as Ollama; the app warns when an API key would be sent over one.

SSH private keys must be Ed25519 or RSA in OpenSSH format.

## Development

```
TermKit/            Swift package
  Sources/TermCore  models, streaming client, agent loop, tools, workspace and session logic (no UI, builds on Linux)
  Sources/TermSSH   SSH connection on top of Citadel
App/                SwiftUI app
UITests/            UI tests that drive the app in demo mode
project.yml         XcodeGen project definition
```

```sh
swift test --package-path TermKit      # unit tests (macOS or Linux)
xcodegen generate && open TermAI.xcodeproj
```

Launching the app with `-demo` gives it sample content, a scripted model and a canned SSH host, with nothing read from or written to real storage or the network. The CI screenshots and the UI tests use it (`-demoSidebar`, `-demoFiles` and so on open a particular screen):

```sh
xcodebuild test -project TermAI.xcodeproj -scheme TermAI -destination 'platform=iOS Simulator,name=iPhone 17'
```

Two unit tests talk to real services and are skipped unless configured:

```sh
python3 TermKit/Tests/mock_server.py 8765 &
TERMAI_TEST_BASEURL=http://127.0.0.1:8765/v1 \
TERMAI_SSH_HOST=127.0.0.1 TERMAI_SSH_USER=me TERMAI_SSH_PASSWORD=… \
swift test --package-path TermKit
```

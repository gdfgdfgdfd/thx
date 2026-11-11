# TermAI

A terminal-style AI agent for iPhone. Point it at any OpenAI-compatible endpoint (base URL, API key, model IDs) and use it like a CLI. The agent can run commands on your servers over SSH, read and write files in an on-device workspace, and fetch URLs.

## Install

Every push builds an unsigned IPA on GitHub Actions.

1. Open the latest **Build** run under the repository's *Actions* tab.
2. Download the `TermAI-unsigned-ipa` artifact and unzip it.
3. Sign and install `TermAI-unsigned.ipa` with your sideloading tool (AltStore, Sideloadly, TrollStore, or your own certificate).

The same run uploads a `screenshots` artifact with the app in each theme.

## Use

First launch: type `/setup` and answer the prompts (profile name, base URL, API key, default model), or open `/config` for the settings screen. Add SSH hosts in `/config`.

| Input | What it does |
| --- | --- |
| plain text | send a prompt to the agent |
| `!uptime` | run a command on the selected SSH host yourself |
| `/model [id]` | list or switch models |
| `/profile [name]` | list or switch API profiles |
| `/host [name\|off]` | list or switch SSH hosts |
| `/approve [ask\|auto]` | whether tool calls need your OK |
| `/theme [id]` | `dark`, `crt-green`, `crt-amber`, `light` |
| `/system [text\|reset]` | custom system prompt |
| `/new`, `/sessions [n]`, `/retry` | session control |
| `/copy`, `/export`, `/clear` | copy the last answer, share as Markdown, clear the screen |

The key row appears with the keyboard and has `esc`, `/`, `!`, history `↑ ↓`, `tab` (complete a command), `^C` (stop the current run) and `paste`. The round button in the input sends, or stops the run when nothing is typed.

The rest is on screen:

- **Sessions** (stack icon, top left): switch to a saved session, start a new one, swipe to delete.
- **Files** (paperclip): attach files from the Files app to the next message. They are copied to `uploads/` in the workspace. Text files up to 48 KB are sent with the message; larger ones the agent reads on demand; binary files are only saved.
- **Edit and resend**: the pencil under your last message, or touch and hold any message. Sending replaces that message and the replies after it. The ↻ under the last answer resends it unchanged.
- **Tool calls** fold into a list with one line per call; tap a line for its output. Code blocks and tool output have a copy button.

On iOS 26 the bars and the input are Liquid Glass; earlier versions get a blurred card instead.

## Safety model

- **Approval.** In the default `ask` mode every SSH command, file write and web request waits for `y` / `n` / `a` (always, for this session). Reading workspace files does not ask.
- **Secrets.** API keys, passwords and private keys are stored in the iOS Keychain (this device only). They are never written to the JSON settings files.
- **Host keys.** The first connection to a host records its key (the fingerprint is printed); later connections are refused if the key changes.
- **Workspace.** File tools are confined to the app's Documents folder, visible in Files › On My iPhone › TermAI.
- **Network.** The app talks only to the endpoints and hosts you configure. Plain-`http` endpoints are allowed for LAN servers such as Ollama; the app warns when an API key would be sent over one.

SSH private keys must be Ed25519 or RSA in OpenSSH format.

## Development

```
TermKit/            Swift package
  Sources/TermCore  models, streaming client, agent loop, tools (no UI, builds on Linux)
  Sources/TermSSH   SSH connection on top of Citadel
App/                SwiftUI app
project.yml         XcodeGen project definition
```

```sh
swift test --package-path TermKit      # unit tests (macOS or Linux)
xcodegen generate && open TermAI.xcodeproj
```

Two tests talk to real services and are skipped unless configured:

```sh
python3 TermKit/Tests/mock_server.py 8765 &
TERMAI_TEST_BASEURL=http://127.0.0.1:8765/v1 \
TERMAI_SSH_HOST=127.0.0.1 TERMAI_SSH_USER=me TERMAI_SSH_PASSWORD=… \
swift test --package-path TermKit
```

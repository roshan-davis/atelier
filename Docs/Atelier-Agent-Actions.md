# MCP and Atelier Agent Actions

**Design proposal, November 11, 2026; revised November 12 after comparing VectorCraft and other apps.** Not yet approved and not yet in the PRD. Backlog item: [AT-050](../BACKLOG.md#at-050--mcp-server-agent-actions-for-chat-clients). Published page with the same content: [Atelier Agent Actions](https://claude.ai/artifact/1zAwwGsuc14v3yZbxBfrB2) (private to Rosh).

This proposal lets Claude, Codex or a local Ollama model run Atelier's commands from a chat, through an MCP server that lives inside the app.

## Recommendation

Build it, and make every command reachable, as VectorCraft does. Rosh's idea is quickly becoming the standard for creative apps. VectorCraft, from the LightCraft and ArtCraft team, hands every menu item, tool, panel and dialog to an agent over MCP. Blender, Photoshop, GIMP and Lightroom Classic have community MCP bridges, and Figma ships an official one. Comparing them changed one of the three choices below and added several details worth copying. The PRD already plans an MCP server for agents (AI row, "Later").

- **One command table.** Unchanged. Menus, keys, the right-click menu and MCP all read the same list of actions. VectorCraft works the same way: its menus, shortcuts and MCP catalog come from one table, and its CI fails if they drift apart.
- **Every command reachable, in two layers.** Changed. The first draft offered only about 20 hand-made tools. VectorCraft shows the better pattern. A short set of typed tools (`set_metadata`, `adjust`, `export`…) is the front door, and `command_list` / `command_run` reach every command in the registry. Gemma and Qwen do well with the front door, and Claude can reach everything.
- **Atelier owns the safety.** Unchanged, and stricter than VectorCraft. VectorCraft lets the agent answer its dialogs. Atelier can't, because it touches originals, the Trash, the NAS and the shop license gate. Reads run freely and edits are undoable. Export, AI jobs and Edit In ask in Atelier's own window. Deletes can't be called.

## How other apps do it

Most of these are community bridges: a plug-in inside the app opens a local socket, and a separate MCP server talks to it. VectorCraft and Figma build the server into the product themselves, which is what Atelier would do.

| App | Built by | How the agent reaches the app | Tools | Safety |
| --- | --- | --- | --- | --- |
| **VectorCraft** | The app's own developers, open source (app still "in development") | `vectorcraft-cli mcp` (stdio) relays to the app's control port on 127.0.0.1:7979, opened by launching with `--control`; or a headless engine with no window | About 30 tools. `command_list`, `command_run` and `command_batch` reach roughly 450 menu commands plus engine commands. Typed `draw_path`, `export` and `render_preview`. UI driving: `invoke_menu`, `answer_dialog`, clicks, keys, screenshots | Read and write folder roots. Hints on every tool. Batches undo as one step. Plug-in installs need a person, and the agent can't confirm them. The control port has no authentication. |
| **Blender** | Community (blender-mcp), not the Blender Foundation | Add-on runs a socket server on localhost:9876; a Python MCP server relays | A few scene tools plus `execute_blender_code`, which runs any Python | "Anyone who can reach that port can run Python inside Blender." Optional safe mode |
| **Figma** | Figma, official | The desktop app serves HTTP at 127.0.0.1:3845/mcp; also a remote server at mcp.figma.com | Read tools (design context, screenshot, variables). Writing to the canvas only through the remote server, in beta | Paid seat. The desktop server is read-only |
| **Photoshop, Premiere** | Community (adb-mcp, "not endorsed by Adobe", proof of concept) | MCP server, then a Node proxy on ws://localhost:3001, then a UXP plug-in (UXP can't listen on a socket) | Lower-level typed tools per app | No direct file access by default |
| **Lightroom Classic** | Community (lightroom-mcp, lightroom-classic-mcp) | A Lua plug-in opens localhost sockets | Mostly catalog reads, some collection tools | Read-mostly |
| **GIMP** | Community (gimp-mcp) | GIMP plug-in | Script-Fu | — |

### What to adopt from VectorCraft

- **The catalog tools, by the same names.** Use `command_list` (filter, menu path, enabled only), `command_run` (id, params) and `command_batch` (steps, `atomic`, `label`). VectorCraft says these names follow a convention it shares with FilmCraft, so prompts and habits carry over between apps.
- **A batch as one undo step.** With `atomic: true`, a batch becomes one named undo step, which fits the one-edit-one-step rule.
- **A catalog that can't drift.** VectorCraft generates its MCP list from the menu table and checks it in CI. Atelier can go one step further: menus are built *from* the registry, so there's nothing to mirror.
- **Ids instead of the selection, never mixed.** Explicit ids replace the selection. A bad id is refused under the command's name, never quietly replaced by the selection. This design already did that, and VectorCraft confirms it.
- **"Did you mean" errors.** An unknown parameter is an error that names the nearest real key ("unknown parameter `widht`; did you mean `width`?"), instead of running with a default. This matters a lot for small local models.
- **Folder roots.** Their `--automation-read-root` and `--automation-write-root` map well to Atelier. Export and Edit In write only into folders Rosh allows (the export presets' folders by default), and the agent never names a path outside them.
- **Long calls.** Progress notifications, cancellation, and a "busy" error after two seconds instead of a silent queue.
- **Prompts.** VectorCraft ships eight ready workflows (poster, recolor, export set…). Atelier's would be "Cull this import", "Export the picks for the website" and "Match these to a reference".
- **Approval only a person can give.** VectorCraft's plug-in install dialog ignores the agent's `answer_dialog` and injected input, and OK only works after the question has been on screen for half a second. Atelier's Allow sheets should use the same hardening.

### Where Atelier differs, on purpose

- **No driving the window.** No clicks, keys or `answer_dialog`. Atelier's commands mean something on their own (rate these, export those), and driving the window is the computer-use pattern Rosh has ruled out. An agent that can answer dialogs could also click Allow on its own export.
- **Stricter safety tiers.** VectorCraft relies on undo and folder roots, which suits a vector document. Atelier also guards originals, the Trash, the NAS and the license gate, so it keeps "Asks first" and "Never".
- **Private socket, not an open port.** VectorCraft opens an unauthenticated TCP port, and only when launched with `--control`. Atelier listens on a Unix socket that only Rosh's user account can open, so a web page or another account on the Mac can't reach it. It's turned on with a switch in Settings, not a launch flag.
- **No headless mode at first.** VectorCraft can run its engine without the window. Atelier's catalog has one writer, so the helper launches Atelier instead. A read-only headless search could come later.
- **No "run any code" tool.** Blender's `execute_blender_code` shows why: it bypasses every tier.

![Two layers: Gemma and Qwen (profile Organize) use the ~20 typed front-door tools; Claude and Codex (profile Edit or Everything) also get command_list, command_run and command_batch. Both layers reach the action registry and the same guard, so command_run on Export still asks first and delete commands stay out of the list.](images/agent-actions/two-layers.png)

*Both layers land on the same registry and the same guard. A profile decides which layer a client sees: Look and Organize get only typed tools, while Edit and Everything also get `command_run`, limited to commands within that profile's tiers.*

## How it fits together

The MCP server runs inside Atelier.app, because the app already holds the catalog, the selection, Develop state and undo. Local chat clients start a tiny helper, `atelier-mcp`, shipped inside the app bundle. The helper only passes messages to the running app over a private Unix socket. It never opens the catalog itself, so there's still exactly one writer.

![Architecture: chat clients connect through the atelier-mcp stdio helper (or an optional HTTP listener) to the MCP endpoint inside Atelier. The endpoint, menus, keys, the photo menu and Shortcuts all feed one action registry; actions pass a guard, then LibraryModel, DevelopController and Export, then the catalog and Processor host.](images/agent-actions/architecture.png)

*Solid lines ship first. Dashed amber parts (HTTP, other devices, Shortcuts) are optional later steps. The agent reaches the same handlers as a click, so undo, history and render coalescing work the same.*

### Why the app hosts the server, not a separate process

- **One writer.** A second process opening the catalog would race the app on GRDB writes and miss the app's undo stack and live Develop state.
- **Selection and "this photo".** Only the app knows what you're looking at. "Warm this one up a bit" needs that.
- **The helper keeps clients simple.** Claude Desktop, Claude Code, Codex and ollmcp all know how to launch a stdio server. The helper starts Atelier if it isn't running and waits for the catalog to open.

Config for any of them is one entry pointing at the helper. Settings would offer a Copy button for each client:

```json
{
  "mcpServers": {
    "atelier": {
      "command": "/Applications/Atelier.app/Contents/Helpers/atelier-mcp",
      "args": ["--profile", "edit"]
    }
  }
}
```

### Which clients can connect

- **Claude Desktop and Claude Code:** add Atelier as a local MCP server in their config.
- **Codex:** its config takes MCP servers too, both local and HTTP ones.
- **Ollama:** Ollama only runs the model, so a chat app in front of it has to speak MCP, such as `ollmcp` (mcp-client-for-ollama) in Terminal or Open WebUI. Gemma 4 and Qwen 3.6 can call tools but are less reliable than Claude at choosing among many, which is why the default tool lists are short and the risky steps are confirmed in Atelier.

## MCP points in, Processors point out

This does not add a second integration path. The Processor contract is how Atelier calls *out* to tools (ComfyUI, Core ML, Edit In apps, plugins). MCP is how an agent calls *in* to Atelier. When an agent runs an AI recipe, the tool calls the Processor host like the AI panel does, so provenance, licenses and the license gate stay the same.

![Chat agent calls Atelier through MCP; Atelier calls ComfyUI, Core ML and Edit In apps through the Processor contract.](images/agent-actions/direction.png)

## The action registry

Today commands live in three places. There are SwiftUI menus in `AtelierApp.swift`, 31 `KeyAction` cases in `KeyBindings.swift`, and the right-click menu in `PhotoMenu.swift`. Each calls `LibraryModel` on the current selection (for example `setRating` uses `pairTargetIDs`). The registry would make each action a value with:

- **id and title**, such as `library.setRating`, "Rate 3 stars". Menus and Settings > Keyboard show the title.
- **input schema**, the typed parameters (JSON Schema for MCP).
- **target**, which photos it applies to: `selection`, `current`, explicit ids, or a search. Handlers take resolved ids instead of reading the selection themselves. That is the main refactor.
- **risk tier** (below), which the guard reads.
- **handler**, the existing `LibraryModel` or `DevelopController` call.

`KeyBindings` stays as it is. A key is still bound to a command, and the command maps to a registry action. Some keys are view toggles (Show Before, Clipping, Mask Overlay). They become actions too, but they're left out of the default MCP profiles because an agent gains little by flipping them.

Apple was reported in 2025 to be testing MCP support through App Intents in macOS 26.1 betas. Built on a registry, Atelier could later publish the same actions as App Intents (Shortcuts, Spotlight) at little cost. Don't count on Apple's MCP bridge until it ships and is documented.

## Tool catalog

About 20 typed tools grouped by task, plus the three catalog tools that reach every command. Each takes a `photos` target and returns what it changed. The client picks a profile, which decides how many tools the model sees:

- **Look:** read only.
- **Organize:** adds library and cull.
- **Edit:** adds Develop, presets, masks, Match Look and `command_run`.
- **Everything:** adds export, Edit In and AI.

For Gemma or Qwen, start with Organize or Edit.

| Area | Tool | What it does | Tier |
| --- | --- | --- | --- |
| Context | `get_context` | Mode, photo on screen, selection count, active filter, import or collection | Reads |
| | `search_photos` | Filter by rating, flag, label, keyword, date, camera, lens, import, collection, folder, edited or not | Reads |
| | `get_photo` | Metadata, shooting info, develop summary, stack and virtual copies (location left out unless allowed) | Reads |
| | `get_preview` | A rendered JPEG up to 1024 px, so a vision model can look at the photo (off by default) | Reads |
| | `list_items` | Imports, collections, presets, export presets, editors, AI recipes, built-in Match Look studies | Reads |
| Library | `show` | Select photos and switch to Grid, Loupe or Develop | Undoable |
| | `set_metadata` | Rating, flag, label, keywords, title, caption | Undoable |
| | `organize` | Add to a collection or new collection, stack, create a virtual copy | Undoable |
| Cull | `cull_groups` | Bursts and near-duplicates in an import, with Atelier's suggested keeper (sharpness, face quality) | Reads |
| Develop | `get_develop` | Current settings as named values (Exposure, Temp, Highlights…) | Reads |
| | `adjust` | Set or nudge named settings: `{"exposure": "+0.3", "temp": 5600}` | Undoable |
| | `auto` | Auto Tone or Auto White Balance | Undoable |
| | `apply_preset`, `sync`, `reset` | Apply a preset, copy settings from one photo to others (chosen groups), reset all or a group | Undoable |
| | `crop` | Aspect ratio, straighten angle, rotate | Undoable |
| Masks | `add_mask` | Select Subject, Sky, People (with parts), Linear or Radial, plus its adjustments. Brush stays manual. | Undoable |
| Match Look | `match_look` | Match to a catalog photo or built-in study, with Protect Skin Tones | Undoable |
| AI | `run_recipe` | Upscale or Replace Background as a background job with progress. Remove Object needs painting, so it opens the tool instead. | Asks first |
| Export | `export` | Export with a preset to a folder; license gate applies | Asks first |
| Edit In | `edit_in` | Open in an editor from Settings > Edit In | Asks first |
| Safety | `undo_change`, `job_status` | Undo one of the agent's own changes by id; check or cancel a running job | Undoable |
| Every command | `command_list` | Commands in the registry: id, title, menu path, key, parameters, tier, and whether it's enabled now | Reads |
| | `command_run`, `command_batch` | Run any listed command, or several as one named undo step. Each command keeps its own tier. | Its own tier |
| Not exposed | — | Remove or delete photos, delete imports or collections, change Settings or keys. A request opens Atelier's own Remove sheet for Rosh to click. | Never |

### What a conversation looks like

> **Rosh:** In yesterday's Zf import, pick the best of each burst, give them 3 stars, then warm them a touch.

```text
search_photos({"import": "latest", "camera": "Nikon Z f"})
  → 212 photos in "Zf · Point Reyes"
cull_groups({"import": 41})
  → 37 groups, suggested keepers: [8812, 8820, …]
set_metadata({"photos": {"ids": [8812, 8820, …]}, "rating": 3, "flag": "pick"})
  → change c-17 · 37 photos · in Atelier: "Claude rated 37 photos ★★★ · Undo"
adjust({"photos": {"ids": [8812, …]}, "set": {"temp": "+300"}})
  → change c-18 · one history step per photo: "Temp +300 (Claude)"
```

## Safety: Atelier decides, not the chat client

Chat clients handle approval differently. Some ask before each tool call, and some let you approve everything at once. MCP has tool hints (`readOnlyHint`, `destructiveHint`) that Atelier sets, but clients only treat them as advice. The 2026-07-28 spec also changed how a server asks the user a question mid-call, and support for that varies between clients. So the guard inside Atelier enforces the rules, and confirmations appear in Atelier's own window.

| Tier | Behavior | Applies to |
| --- | --- | --- |
| **Reads** | Runs freely | Search, metadata, settings, cull groups. Previews only if turned on. |
| **Undoable** | Runs, then tells you | One undo step per call, named with the client: "Rate 3 stars (Claude)". A toast in the window offers Undo. More than 50 photos asks first (the number can be changed). |
| **Asks first** | Confirm in Atelier | Export, AI jobs, Edit In and XMP writes make files or launch apps. Atelier shows a sheet with what, how many and where, plus Allow and Cancel. |
| **Never** | Not a tool | Remove, Trash, delete import. If asked, Atelier opens its Remove sheet, and only Rosh's click deletes (with `DeleteFeedback`). |

![Sequence: Rosh asks the chat to export the picks; the model calls search_photos, then export; Atelier's guard shows a confirmation sheet in the Atelier window; Rosh clicks Allow; the export runs as a job with progress and returns the folder path.](images/agent-actions/export-sequence.png)

*If Rosh clicks Cancel, or nobody answers within two minutes, the tool returns "declined by the user" and nothing is written. Long jobs report progress and can be cancelled, as in the AI panel.*

### Undo and history

- Each tool call is one undoable step, following the AGENTS.md rule that one edit is one history step. A call that rates 37 photos is one Undo, the same as a menu command on a selection.
- Develop history names carry the client: "Temp +300 (Claude)". The history panel shows the agent's changes alongside Rosh's own.
- Each result returns a `change` id. `undo_change` undoes only the agent's own changes, so the model can fix a mistake without undoing Rosh's.
- During a slider drag, an agent change to that photo waits until the drag ends, so it never fights the hand.

### Selection and targets

- Every write names its photos. `{"selection": true}` and `{"current": true}` are resolved when the call runs, and the result echoes the count and ids, so a selection changed mid-chat is never a silent surprise.
- Ids are catalog ids. Virtual copies have their own ids, and RAW+JPEG pairs follow the pair rule the menus already use.

## Privacy and reach

- **Local by default.** The stdio helper and Unix socket never touch the network. Atelier makes no outgoing calls for this.
- **The model decides where data goes.** With Ollama, nothing leaves the Mac. With Claude Desktop or Codex, whatever a tool returns goes to that provider as part of the chat, under Rosh's own subscription. That's not a paid API Atelier calls, but it does leave the Mac. So previews and GPS are off by default, and Settings shows which clients are connected.
- **From other devices (later, opt-in).** Atelier also serves Streamable HTTP. It listens on 127.0.0.1, or on the Tailscale address when remote access is turned on, and requires a token. The Mac must be awake with Atelier open.
- **claude.ai connectors** connect from Anthropic's servers, so they'd need a public HTTPS address with OAuth sign-in (for example Tailscale Funnel). Leave that out unless Rosh asks for it.

A new pane, Atelier > Settings… > Agents (under Editors & AI), would hold these switches and an activity log:

![Mock of Settings > Agents: Allow chat agents to use Atelier (on); Default profile Look / Organize / Edit / Everything; Ask before changing more than 50 photos; Let agents see photo previews (off); Include location in metadata (off); Remote access over Tailscale (off); Connect a client with Copy config; an activity log with Undo buttons.](images/agent-actions/settings-agents-mock.png)

## Building it

Protocol: the official Swift SDK (`modelcontextprotocol/swift-sdk`) if it supports the 2026-07-28 spec by the time work starts. Otherwise a small JSON-RPC layer in AtelierCore, since a server with tools, a few resources and prompts doesn't need much. That spec drops the old initialize handshake and session ids, which helps for a stateless local server. The server code goes in Core with tests, and the app only adds the socket and the sheets.

| Phase | Scope |
| --- | --- |
| **A0. Action registry** | Move the menu, key and right-click commands onto one registry, with handlers that take resolved ids. Menus are built from it, and a test fails if a menu command is missing from it. No visible change. Tests in AtelierCoreTests. |
| **A1. Read-only MCP** | Helper, socket, the Look tools and `command_list`. Settings > Agents with on/off, Copy config and the activity log. Lets Rosh try Claude, Codex and Ollama safely. |
| **A2. Organize** | Ratings, flags, labels, keywords, collections, cull groups. Guard, toast and named undo steps, "did you mean" errors. |
| **A3. Edit** | Develop adjust, auto, presets, sync, crop, masks, Match Look. `command_run` and atomic `command_batch`. Wait for an active drag. |
| **A4. Everything** | Export, Edit In and AI recipes with the hardened confirmation sheet, folder roots, background jobs, progress and Cancel. |
| **A5. Optional** | HTTP listener with Tailscale and a token, App Intents for Shortcuts, MCP prompts such as "Cull this import". |

Each phase is one PR, updating the PRD, Help (a new Agents page) and BACKLOG.md. A1 is the cheapest real test of whether this gets used day to day.

## The same approach in Easel

Rosh wants Easel to work the same way once this is implemented, so one chat setup and the same habits work in both apps. VectorCraft does this across the Craft apps: the same tool names and flags, so one client config fits the suite.

- **Shared plumbing, app-specific actions.** The parts that don't know about photos go in one app-neutral Swift module: the action and risk-tier types, the MCP server, `command_list` / `command_run` / `command_batch`, the guard and its Allow sheet, the socket, the helper, the activity log and the Settings > Agents pane. Each app supplies its own actions, typed tools and targets (photos in Atelier; documents, layers and selections in Easel) and assigns their tiers.
- **Same names everywhere.** Same tool names, profiles (Look, Organize, Edit, Everything), error style, tiers and config shape. Each app has its own helper (`atelier-mcp`, `easel-mcp`) and its own private socket.
- **Build once, extract when Easel starts.** Build the module inside Atelier as its own target that imports nothing from Atelier, so A0 and A1 aren't slowed by a second repo. Move it into its own package, which both apps depend on, when Easel's work begins. A test that the module builds without Atelier keeps that move cheap.

## PRD check

Nothing here contradicts the PRD, but these points need a PRD change once approved:

- **Scope and timing.** The PRD puts "MCP server for agents" under Later, with search, develop and recipe tools. This proposal brings it forward and widens it to library, cull, masks, Match Look, export and Edit In.
- **Privacy row.** "No network calls except NAS, user-configured backends and update checks." The stdio and socket path is fine. The optional HTTP listener and remote access would need a line added: off by default, loopback or tailnet only, token required.
- **Sandboxing row.** When the app is sandboxed, the helper and app share an App Group container for the socket. The HTTP listener needs the network-server entitlement.
- **One Processor contract.** Not affected, since MCP calls in and doesn't plug in tools. If Atelier ever *uses* MCP tools (for example a denoiser behind an MCP server), that goes through the Processor contract, not a new path.
- **UX principle 8, "every command is in a menu."** The registry makes this enforceable: a command without a menu entry would fail a test.

## Open decisions for Rosh

- Approve the direction, and whether A0 + A1 are the first bounded item.
- Remote access: leave it for later (recommended), or Tailscale in A1.
- Previews for cloud-hosted models (Claude, Codex): off by default with a switch (recommended), or never.
- Easel: shared module built inside Atelier and extracted when Easel starts (recommended), or a separate package from day one.

## Sources

**Primary**

- MCP specification, latest (2026-07-28): https://modelcontextprotocol.io/specification/latest
- MCP 2026-07-28 changelog: https://modelcontextprotocol.io/specification/2026-07-28/changelog
- MCP blog, 2026-07-28 release post: https://blog.modelcontextprotocol.io/posts/2026-07-28/
- MCP transports (draft): https://modelcontextprotocol.net/specification/draft/basic/transports
- Official Swift SDK: https://swiftpackageregistry.com/modelcontextprotocol/swift-sdk
- mcp-client-for-ollama (ollmcp): https://pypi.org/project/mcp-client-for-ollama/0.24.1/
- VectorCraft MCP docs, `docs/mcp.md` and `docs/control-protocol.md` at `f7a03f7`: https://github.com/storytold/vectorcraft
- VectorCraft product page: https://getartcraft.com/apps/vectorcraft
- Blender MCP: https://github.com/ahujasid/blender-mcp
- Figma MCP server: https://developers.figma.com/docs/figma-mcp-server/ and https://developers.figma.com/docs/figma-mcp-server/local-server-installation
- adb-mcp (Photoshop, Premiere): https://github.com/mikechambers/adb-mcp
- Atelier source at `8436d93`: `Requirements/Atelier-PRD.md`, `Sources/AtelierApp/KeyBindings.swift`, `AtelierApp.swift`, `PhotoMenu.swift`, `LibraryModel.swift`, `Sources/AtelierCore/Processors`

**Secondary**

- Photography MCP servers (Lightroom, GIMP) review: https://dev.to/grove_chatforest/photography-mcp-servers-lightroom-photoshop-gimp-stock-photos-image-optimization-camera-13ih
- 9to5Mac, macOS Tahoe 26.1 beta and MCP in App Intents (Sept 2025): https://9to5mac.com/2025/09/22/macos-tahoe-26-1-beta-1-mcp-integration/
- Using MCP servers with Ollama and local LLMs: https://dev.to/hola_gus/how-to-use-mcp-servers-with-ollama-and-local-llms-f3
- Best local models for tool calling, 2026: https://www.promptquorum.com/power-local-llm/best-local-models-tool-calling-2026

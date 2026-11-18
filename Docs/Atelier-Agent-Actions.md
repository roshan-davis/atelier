# MCP and Atelier Agent Actions

**Design proposal, November 11, 2026; revised November 12 after comparing VectorCraft and other apps, and November 13 after Codex's review.** Direction approved by Rosh on November 13, 2026; not yet in the PRD (AT-050b adds it). Backlog: [AT-050](../BACKLOG.md#at-050--agent-actions-mcp-server-for-chat-clients-atelier-and-easel), with one work item per phase: AT-050a (A0) to AT-050f (A5), and AT-050g for Easel. Published page with the same content: [Atelier Agent Actions](https://claude.ai/artifact/1zAwwGsuc14v3yZbxBfrB2) (private to Rosh).

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

*Both layers land on the same registry and the same guard. A profile is a ceiling. Every profile gets both layers, but the list and the commands it can run stop at that profile's level (see the matrix under "Rules added after the Codex review").*

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
      "command": "/Applications/Atelier.app/Contents/MacOS/atelier-mcp",
      "args": ["--profile", "edit"]
    }
  }
}
```

The profile in the config is only a request. Atelier decides what each client may do (see "Who may connect" below).

### Which clients can connect

Any chat app that can run a local MCP server works. Atelier ships the helper `atelier-mcp` inside the app. A client starts that helper, and the helper talks to the running Atelier window, so **Atelier has to be open**. Setup steps for each client are under [Connect a chat app](#connect-a-chat-app).

Ollama only runs the model; it doesn't connect to MCP servers itself (nothing on its blog or GitHub through Oct 2026). Use an Ollama model from a chat app that does, such as OpenCode, Cherry Studio, LM Studio, `ollmcp` or Open WebUI. Gemma 4 and Qwen 3.6 can call tools but are less reliable than Claude at choosing among many. That's why the default tool lists are short and the risky steps are confirmed in Atelier.

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

### Always in sync: new commands need no porting

Rosh's rule (Nov 13, 2026): adding or removing a menu command must update everything agents see, with nothing to port by hand and nothing that breaks to be fixed later. New features are available to agents by default under the same rules. The same holds in Easel.

- **One source.** A menu item, key command or right-click item can only be made from a registry action, never from a bare button that calls the model. A new feature that shows up in a menu is in the MCP catalog in the same commit, and a removed one leaves both. There's no second list to keep up to date.
- **Exposed by default, safely.** Every action must say what it does (its kind): reads, changes the catalog or Develop settings (undoable), writes files or starts a job, opens another app, or deletes. The code won't compile without a kind. The tier follows from the kind by fixed rules: edits run with one undo step, file writes and jobs ask first in Atelier's window, and deletes are never exposed. A new feature is usable by agents at once under those rules. An action opts out only with a stated reason (for example Show Before, which means nothing to an agent).
- **Parameters come from the code.** Each action's parameters are a Swift type, and the schema `command_list` shows is generated from it. A new or renamed parameter appears without hand edits.
- **Typed tools can't go stale.** Typed tools call registry actions by their Swift ids, so removing or renaming an action they use is a build error, not a broken tool discovered later.
- **Checks.** Tests fail if a menu item has no action, an action has no kind, or two actions share an id. A script writes the agent catalog to `Docs/agent-actions-catalog.json`, and `check_pr.py` fails if that file is out of date, so every PR's diff shows which agent commands it added, removed or changed. This is VectorCraft's `ui-commands --check`, except the menus come from the registry, so nothing has to be mirrored.
- **The same in Easel.** The shared module provides the action type, the kind-to-tier rules, the menu builders and the catalog check, so Easel gets the same behavior by adopting it.

## Tool catalog

About 20 typed tools grouped by task, plus the three catalog tools that reach every command. Each takes a `photos` target and returns what it changed. Atelier grants each client a profile (the client can ask for one), which decides how many tools the model sees:

- **Look:** read only.
- **Organize:** adds library and cull.
- **Edit:** adds Develop, presets, masks and Match Look.
- **Everything:** adds export, Edit In and AI.

For Gemma or Qwen, start with Organize or Edit.

| Area | Tool | What it does | Tier |
| --- | --- | --- | --- |
| Context | `get_context` | Mode, photo on screen and its file name, selection (the first few with file names), active filter, import or collection, whether photo previews are on | Reads |
| | `search_photos` | Filter by rating, flag, label, keyword, date, camera, lens, import, collection, folder, edited or not | Reads |
| | `get_photo` | Metadata, shooting info, develop summary, stack and virtual copies (location left out unless allowed) | Reads |
| | `get_preview` | A rendered JPEG up to 1024 px with its file name: the model sees it, and chat apps that show images (Docent) show it to the person; the server's instructions point "show it here in the chat" at it (off by default; turning it on or off sends `notifications/tools/list_changed`) | Reads |
| | `list_items` | Imports, collections, presets, export presets, editors, AI recipes, built-in Match Look studies | Reads |
| Library | `show` | Select photos and switch to Grid, Loupe or Develop, in Atelier's own window only (not in the chat) | Undoable |
| | `set_metadata` | Rating, flag, label, keywords, title, caption | Undoable |
| | `organize` | Add to a collection or new collection, stack, create a virtual copy | Undoable |
| Cull | `cull_groups` | Bursts and near-duplicates in an import, with Atelier's suggested keeper (sharpness, face quality) | Reads |
| Develop | `get_develop` | Current settings as named values (Exposure, Temp, Highlights…) | Reads |
| | `adjust` | Set or nudge named settings: `{"exposure": "+0.3", "temp": 5600}` | Undoable |
| | `auto` | Auto Tone or Auto White Balance | Undoable |
| | `apply_preset`, `sync`, `reset` | Apply a preset, copy settings from one photo to others (chosen groups), reset all or a group | Undoable |
| | `crop` | Aspect ratio, straighten angle, rotate | Undoable |
| Masks | `add_mask` | Select Subject, Background, Object, People (with parts), Linear, Radial or Luminance Range, plus its adjustments. Brush stays manual. | Undoable |
| Match Look | `match_look` | Match to a catalog photo or built-in study, with Protect Skin Tones | Undoable |
| AI | `run_recipe` | Upscale or Replace Background as a background job with progress. Remove Object needs painting, so it opens the tool instead. | Asks first |
| Export | `export` | Export with a preset to a folder; license gate applies | Asks first |
| Edit In | `edit_in` | Open in an editor from Settings > Edit In | Asks first |
| Safety | `undo_change`, `job_status` | Undo one of the agent's own changes by id; check or cancel a running job | Undoable |
| Skills | `get_skill` | One of the person's skills (Settings > Agents > Skills, SL-002c) as prepared text, or one of its other files with `file`; only skills that are on. The skills also come as MCP prompts (`prompts/list`, `prompts/get`) and in the server's instructions | Reads |
| Every command | `command_list` | Commands in the registry: id, title, menu path, key, parameters, tier, and whether it's enabled now | Reads |
| | `command_run`, `command_batch` | Run any listed command, or several as one named undo step. Each command keeps its own tier. | Its own tier |
| Not exposed | — | Remove or delete photos, delete imports or collections, change Settings or keys. Not listed and can't be run in any way; the agent points Rosh to Photo > Remove Photo… | Never |

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
| **Never** | Not a tool | Remove, Trash, delete import. Not listed and can't be run by id or in a batch. Only Rosh deletes, from the menus (with `DeleteFeedback`). |

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

## Rules added after the Codex review

Codex reviewed this design on November 13, 2026 ([review on PR #115](https://github.com/roshan-davis/atelier/pull/115#issuecomment-6842233533)). It agreed with the architecture and the A0 + read-only A1 start, and asked for these rules before the affected phases. They are part of the design now.

### Who may connect (A1)

- **Atelier decides, not the helper.** `--profile` in a client config is only a request. The first time a client connects, Atelier asks in its own window ("Claude Desktop wants to use Atelier. Requested: Edit." with Allow as Look, Allow as Edit and Don't Allow). The grant is stored per client and shown in Settings > Agents, where Rosh can change or revoke it.
- **A name Atelier checks.** Atelier reads the helper's process from the socket and the code signature of the app that launched it (Claude, Codex, or Terminal for ollmcp). Grants and the activity log use that checked name, not the name the client gives itself. For clients started from Terminal (Claude Code, ollmcp) the check can only say "Terminal", so those grants are per launcher, not per model.
- **Checked on every request.** Listing, running, job status, cancel and undo all go through the grant. Turning access off, or revoking a grant, closes that client's open connections at once.
- **Threat model.** The socket accepts only Rosh's user account. Any program running as Rosh can still ask to connect, which is why the first connection needs Rosh's click. Malware already running as Rosh is out of scope, since it could edit the catalog file directly.
- **Tests.** Changing the helper's arguments can't raise a grant. Turning access off drops existing connections.

### Which commands an agent can see (A0, A1)

- **Exposed by default, by rule.** Codex suggested hiding new actions until someone reviews them. Rosh chose the opposite: new actions are exposed by default, and safety comes from each action's required kind, which sets its tier (see "Always in sync" under The action registry).
- **Profiles are ceilings, and both layers obey them.** The typed tools and `command_run` go through the same check, so they always agree:

|  | Look | Organize | Edit | Everything |
| --- | --- | --- | --- | --- |
| Typed read tools, `command_list` | Yes | Yes | Yes | Yes |
| Typed library and cull tools | — | Yes | Yes | Yes |
| Typed Develop, mask and Match Look tools | — | — | Yes | Yes |
| Typed export, Edit In and AI tools | — | — | — | Yes |
| `command_run`, `command_batch` | Read commands | Plus exposed library and cull commands | Plus exposed Develop commands | Plus exposed "asks first" commands |
| Never actions | No | No | No | No |

- **The list matches the grant.** `command_list` shows only what this client may run, so a small model on Organize sees a short list.
- **Never means never.** Never actions aren't listed and can't run by id, in a batch or through another command. This replaces the earlier idea of opening the Remove sheet: the agent tells Rosh to use Photo > Remove Photo… instead.
- **Enabled is not allowed.** Whether a menu item is usable right now is separate from whether the agent may use it. Both are checked again against the resolved photos when the command runs.
- **Tests.** The two layers agree on every action. Actions that aren't exposed still work from the menus.

### Targets, waiting and undo (A2, A3)

- **Ids belong to a catalog.** Replies name the open catalog, and a call made for another catalog is refused. `selection` and `current` are resolved once, at the start, and echoed back.
- **Check again after waiting.** After a wait (for a slider drag to end, or for Allow), Atelier checks the photos again. If one is gone or the fields the call changes were edited meanwhile, the call returns "target changed" and does nothing.
- **Undo doesn't overwrite later work.** `undo_change` works only while the agent's change is still the latest change on those photos. Otherwise it refuses and says which edit is in the way. Develop history saves whole settings snapshots, so this is simpler than checking field by field, and just as safe.
- **Atomic only where it can roll back.** `atomic: true` is allowed only for catalog and Develop setting changes that run in one database transaction and roll back fully. File writes, AI jobs and Edit In can't be in an atomic batch. A non-atomic batch returns a result for each step.
- **Limits count the whole batch.** "Ask before more than 50 photos" applies to the batch total.
- **Retries (later, with A5).** Local stdio clients don't retry calls on their own. When the HTTP path arrives, calls get a request key, and repeating the key returns the first result, so a retried "Exposure +0.3" or "New collection" can't run twice.
- **Tests.** Multi-photo edits in Atelier and document or layer edits in Easel, including a photo removed mid-call and a manual edit after an agent edit.

### Approving an export, AI job or Edit In (A4)

- **One Allow, one exact operation.** An Allow covers the client, the resolved photos, the preset or recipe, the destination and the options. Any change needs a new Allow.
- **Checked again at run time.** Atelier rechecks the resolved destination (inside the allowed folders), overwrite behavior (never overwrite unless the preset says so) and the license gate.
- **Cancel reports what was written.** Cancel stops at the next file, and the reply lists the files already written.
- **The delay isn't proof.** The half-second delay on Allow only prevents accidental clicks. What protects the sheet is that no agent tool can click or type in Atelier's window.

### The shared module (A0, A1)

- **Shared versus per app.** The module shares protocol handling, grants and profile checks, the command envelope, errors and activity events. Each app supplies target resolution, availability, the change and its undo, policy details and how its confirmations look.
- **Versioned.** Command ids and argument schemas carry a version.
- **Shared ceilings.** Profile names are shared. Each app decides which of its actions fit under each one.
- **A small test host shaped like Easel.** A tiny in-memory host with a few open documents and layers checks that the module assumes neither photo ids nor a single catalog.
- **Tested protocol, not assumed.** Build on the 2025-06-18 protocol that today's clients speak, and add the 2026-07-28 response shapes for clients that ask for them, as VectorCraft does. A1 records the version actually tested with Claude, Codex and an Ollama client. Check the Swift SDK against this before choosing it.

## Connect a chat app

*Works from AT-050b, the read-only server, onward. The same steps are in Atelier Help (Connect a chat app; Settings > Agents). Atelier > Settings… > Agents > Connect an App copies each app's setup with the real helper path.*

Every app below starts the same command, with no arguments:

```
/Applications/Atelier.app/Contents/MacOS/atelier-mcp
```

If Atelier runs from Xcode instead of /Applications, build the helper once (Product > Scheme > atelier-mcp, then Product > Build, ⌘B, then switch back to AtelierApp). Settings > Agents then shows its path with **Copy**, and **Copy Setup** gives each app's setup with that path. The first time an app connects, Atelier asks whether to allow it and which profile it gets (Look, Organize, Edit or Everything). You can change that later in Settings > Agents.

### OpenCode (free models)

1. Add the server to `~/.config/opencode/opencode.json` (Settings > Agents > Copy Setup for OpenCode gives a Terminal command that does this, keeping what's already in the file). `opencode mcp add atelier --global -- …` saved nothing when Rosh tried it (Nov 12, 2026), so use the file:
   ```json
   {
     "$schema": "https://opencode.ai/config.json",
     "mcp": {
       "atelier": {
         "type": "local",
         "command": ["/Applications/Atelier.app/Contents/MacOS/atelier-mcp"],
         "enabled": true
       }
     }
   }
   ```
   Check it with `opencode mcp list`. `"enabled": false` turns it off without deleting it.
2. Pick a free model. In OpenCode, run `/connect`, choose the OpenCode provider and sign in, then use `/models` to pick one marked free (for example `opencode/big-pickle` or `opencode/glm-5.3-flash-free`). OpenCode says free models are free for a limited time and change often. Your Ollama models work here too.
3. Ask, for example: "How many photos did I pick from the last import?"

### Cherry Studio

1. Settings > MCP Server > Add server.
2. Name `Atelier`, Type **STDIO**, Command `/Applications/Atelier.app/Contents/MacOS/atelier-mcp`, Arguments left empty. Save.
3. In a chat, turn on MCP in the chat box and select Atelier. Pick a model that can call tools: Cherry can use your Ollama models (Gemma 4, Qwen 3.6) or a hosted one.

### Ollama, with ollmcp (Terminal)

Ollama doesn't connect to MCP servers itself, so `ollmcp` (mcp-client-for-ollama) sits in between. It needs Python 3.11 or later and Ollama running.

```
uv tool install --upgrade ollmcp        # or: pip install --upgrade ollmcp
ollmcp mcp add atelier --scope user -- /Applications/Atelier.app/Contents/MacOS/atelier-mcp
ollmcp mcp list
ollmcp                                  # then pick qwen3.6 or gemma4 and chat
```

`--scope user` writes `~/.config/ollmcp/mcp.json`. Without it, the server goes into `~/.config/ollmcp/mcp.local.json`.

### LM Studio

1. Right sidebar > Program > Install > Edit mcp.json.
2. Inside `"mcpServers": { … }`, add:
   ```json
   "atelier": {
     "command": "/Applications/Atelier.app/Contents/MacOS/atelier-mcp",
     "args": []
   }
   ```
3. Load a model that supports tool use, and turn on the Atelier tools in the chat.

### Open WebUI

Open WebUI connects only to MCP servers over HTTP (Streamable HTTP, v0.6.31 and later), not to a local command. Two ways:

- **Now:** run the helper behind `mcpo`, which serves its tools as an OpenAPI server: `uvx mcpo --port 8000 --api-key "pick-a-secret" -- /Applications/Atelier.app/Contents/MacOS/atelier-mcp`. Then add `http://localhost:8000` in Open WebUI as an **OpenAPI** tool server (not as an MCP server), with the same key.
- **Not through the phone listener:** AT-050f's HTTP listener takes only paired phones (a QR pairing code, the tailnet only), so Open WebUI stays on `mcpo`.

### Claude Desktop, Claude Code and Codex

- **Claude Desktop:** Claude > Settings… > Developer > Edit Config opens `~/Library/Application Support/Claude/claude_desktop_config.json`. Add the entry below, then quit and reopen Claude. Logs are in `~/Library/Logs/Claude/mcp*.log`.
  ```json
  { "mcpServers": { "atelier": { "command": "/Applications/Atelier.app/Contents/MacOS/atelier-mcp", "args": [] } } }
  ```
- **Claude Code:** `claude mcp add --transport stdio --scope user atelier -- /Applications/Atelier.app/Contents/MacOS/atelier-mcp`, then `/mcp` in Claude Code to check it.
- **Codex CLI:** add the server to `~/.codex/config.toml` (Codex documents local stdio servers only through this file; `codex mcp add` is documented for URL servers. `enabled = false` turns one off):
  ```toml
  [mcp_servers.atelier]
  command = "/Applications/Atelier.app/Contents/MacOS/atelier-mcp"
  args = []
  ```

### If it doesn't work

- **Atelier isn't open.** The helper answers with "Atelier isn't running" (AT-050b), and the client shows that as an error. Open Atelier and ask again.
- **The app isn't allowed.** Settings > Agents lists every app that connected. Allow it, or raise its profile.
- **The model never calls a tool.** Small free or local models often answer without calling tools. Ask directly ("use the Atelier tools to list my collections"), or pick a model marked for tool use.

## Docking beside a chat app

Docent (Rosh's own MCP chat app) docks the app it's working with on its right (AT-050h; Docent's side is DO-007 in the Docent repo). The protocol lives in the shared module (`Sources/AgentMCP/Docking.swift`), so Easel adopts it unchanged with AT-050g. This is the reference for both sides, **version 1**.

- **Advertised.** A server with docking returns `capabilities.experimental.docking` in `initialize`: `{"version": 1, "requests": [...], "notifications": [...]}`. Docent docks only servers that advertise it.
- **Client-only, never a tool.** The methods below are JSON-RPC requests outside `tools/list`. They are not registry actions and never appear in `command_list` or the catalog, so no model can call them (`tools/call` with their names is "Unknown tool"). Only Docent's window code sends them.
- **Grant.** Each request passes the same grant check as every other request. Any profile may dock, Look included. Revoking or changing the grant closes the connection, and a closed connection lets go of its window where it is.
- **Frames** are in points, in AppKit's global screen coordinates (origin at the bottom-left of the main screen, y up), exactly as `NSWindow.frame` reads: `{"x", "y", "width", "height"}`, with width and height above 0.

| Request | Params | Result |
| --- | --- | --- |
| `docking/dock` | `frame`; `window` (`"front"`, the default, or a document id in Easel); `screen` (the display's `NSScreenNumber`, informational) | `{"window", "frame", "minWidth"}`: the frame the window actually took (it may be shortened to fit the screen) |
| `docking/update` | the same, while Docent moves or resizes. Docent coalesces: one in flight plus one follow-up | the same |
| `docking/undock` | `window`; `restore` (false by default: the window stays where it is; true puts back the size and place it had before docking) | `{}` |

| Error | Code | When |
| --- | --- | --- |
| Too narrow | -32010 | the frame is narrower than the window's layout works at; `error.data.minWidth` says how wide |
| Unavailable | -32011 | no such window, or it can't dock now (full screen); the message says why |
| Not docked | -32012 | `docking/update` from a client that doesn't hold the window (never docked it, or lost it) |
| Bad params | -32602 | no frame, or a zero or negative size |

| Notification (app to Docent) | Params | When |
| --- | --- | --- |
| `docking/moved` | `window`, `reason`: `user` or `anotherClient` | the person dragged or resized the window away, or another chat app docked it. Docent undocks |
| `docking/closed` | `window`, `reason`: `windowClosed` or `quit` | the window closed, or the app is quitting |
| `docking/minWidth` | `window`, `minWidth` | the layout's narrowest width changed |

- **One holder per window.** The newest `docking/dock` wins; the previous holder gets `docking/moved` (`anotherClient`) first, and its updates are refused from then on.
- **Atelier's side** (`Sources/AtelierApp/Agents/AgentDocking.swift`, layout rule `DockLayout` in AtelierCore): `front` is the main window. Atelier docks at 520 points or more (the photo keeps 480); narrower, the left panel collapses first, then the right one, and they come back as soon as they fit, including after undocking where the window stays narrow. Only a drag or resize by hand counts as moved; Atelier's own layout passes don't. Settings > Agents shows the docked app with Undock (sent as `moved`, `user`). Atelier never sends `docking/minWidth` today: its minimum is the same in every mode.
- **Left out:** docking apps that don't speak the protocol (Docent's own later item, through Accessibility), and full screen.

## From a phone

Docent on iPhone reaches the Atelier open on the Mac directly (AT-050f, Nov 18, 2026, from Docent's handoff "Phone access for Atelier and Easel", Docent's DO-017). The contract is shared with Easel and lives in the shared module, so Easel adopts it unchanged; change it only by agreement across Docent, Atelier and Easel.

| Piece | Where | What it does |
| --- | --- | --- |
| `MCPHTTPEndpoint` | `Sources/AgentMCP/MCPHTTPEndpoint.swift` | Streamable HTTP at `/mcp`: bearer token, pairing, `Mcp-Session-Id` sessions (4 per device, closed after an hour idle), one JSON reply per POST, 202 for notifications, DELETE ends a session, 405 for GET (no server-sent stream: nothing needs to reach the phone unasked), 403 for any `Origin` header. Socket-free, so all of it is tested without a network. |
| `MCPHTTPServer` | `Sources/AgentMCP/MCPHTTPServer.swift` | One listening socket per allowed address, refused before binding for anything but 127.0.0.1 and tailnet addresses; one short thread per request, `Connection: close`, 16 at once, 30 s read timeout, 16 KB headers and 4 MB bodies at most. |
| `TailnetAddresses` | `Sources/AgentMCP/TailnetAddresses.swift` | 100.64.0.0/10 and fd7a:115c:a1e0::/48; the bind list (none without a tailnet address); the MagicDNS name by reverse lookup. |
| `PhoneDeviceStore`, `PairingCode`, `TokenHash` | `Sources/AgentMCP/PhonePairing.swift`, `TokenHash.swift` | Paired devices as SHA-256 hashes (constant-time compare), the one pairing code on screen (memory only, 5 minutes), the last 50 revoked hashes so their phones hear `revoked`. |
| `AgentPhone`, Settings > Agents > Phone | `Sources/AtelierApp/Agents/AgentPhone.swift`, `Views/PhoneSettings.swift` | Turning it on, the port (47801), following the tailnet address (path monitor plus a 30 s check), Pair a Phone… with the QR code and countdown, the paired phones with profile, Asks you itself and Revoke. |

- **Pairing.** The QR payload is `{"v":1,"app":"Atelier","url":"http://<magicdns-name>:47801/mcp","token":"<base64url, 32 random bytes>","expires":"<ISO 8601>"}`. The first `initialize` bearing the token before `expires` records the device, named from `clientInfo.name`; the token is that device's credential from then on. The same name paired again replaces the token and keeps the grant. An unused code expires.
- **Errors.** No, unknown or expired token: `401`, no body. Revoked: `401` with the JSON-RPC error message `revoked`. No `Mcp-Session-Id` on a call other than `initialize`: `400`, JSON-RPC message `Missing Mcp-Session-Id: send initialize first`. A session that ended (idle, revoked, Atelier restarted): `404` with JSON-RPC error `-32001` `Session not found`, and the phone sends `initialize` again. These bodies are word for word Easel's, so one phone client reads both apps alike.
- **Approvals.** A phone runs as an `AgentClient` with `isRemote`; Atelier never shows its first-connection sheet or "Let … change N photos?" for one (both refuse remote clients themselves, as a second guard). Each phone has its own profile and **Asks you itself**: on, the phone's own Allow is the only approval for a change that would ask at the Mac; off, that change fails at once with a message saying where to turn it on. It is on for a newly paired phone, as in Easel: Docent shows its own Allow card, and nobody may be at the Mac. AT-050e's export, Edit In and AI Allows follow the same rule when they arrive.
- **Images.** `get_preview` (1024 px at most) and `get_thumbnails` (320 px) already return `data:` images, inside the contract's caps (512 and 2048 px).
- **Check it from the Mac:** with the listener on and a code on screen, `curl -s -X POST http://<magicdns-name>:47801/mcp -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl test","version":"0"}}}'` pairs "curl test"; without the token it's `401`; against the Wi-Fi address the connection is refused.
- **Left out:** request keys for retried calls (a retried change runs twice; Docent sends each approved call once), App Intents and MCP prompts (the rest of AT-050f).

## Privacy and reach

- **Local by default.** The stdio helper and Unix socket never touch the network. Atelier makes no outgoing calls for this.
- **The model decides where data goes.** With Ollama, nothing leaves the Mac. With Claude Desktop or Codex, whatever a tool returns goes to that provider as part of the chat, under Rosh's own subscription. That's not a paid API Atelier calls, but it does leave the Mac. So previews and GPS are off by default, and Settings shows which clients are connected.
- **From a paired phone (AT-050f, opt-in).** Atelier also serves Streamable HTTP, off by default, on 127.0.0.1 and the Tailscale address only, with a per-device token from a QR pairing code. See [From a phone](#from-a-phone). The Mac must be awake with Atelier open.
- **claude.ai connectors** connect from Anthropic's servers, so they'd need a public HTTPS address with OAuth sign-in (for example Tailscale Funnel). Leave that out unless Rosh asks for it.

A new pane, Atelier > Settings… > Agents (under Editors & AI), would hold these switches and an activity log:

![Mock of Settings > Agents: Allow chat agents to use Atelier (on); Default profile Look / Organize / Edit / Everything; Ask before changing more than 50 photos; Let agents see photo previews (off); Include location in metadata (off); Remote access over Tailscale (off); Connect a client with Copy config; an activity log with Undo buttons.](images/agent-actions/settings-agents-mock.png)

## Building it

Protocol: build on 2025-06-18 with the 2026-07-28 response shapes added (see the shared module rules). Use the official Swift SDK (`modelcontextprotocol/swift-sdk`) if it fits that. Otherwise a small JSON-RPC layer in AtelierCore, since a server with tools, a few resources and prompts doesn't need much. That spec drops the old initialize handshake and session ids, which helps for a stateless local server. The server code goes in Core with tests, and the app only adds the socket and the sheets.

| Phase | Scope |
| --- | --- |
| **A0. Action registry** | Move the menu, key and right-click commands onto one registry, with handlers that take resolved ids. Menus are built from it. Required kind per action, generated parameter schemas, the catalog file and its check in `check_pr.py`, and the AGENTS.md rules. No visible change. Tests in AtelierCoreTests. |
| **A1. Read-only MCP** | Helper, socket, the Look tools and `command_list`. Client approval and grants checked by the app, exposure review per action. Settings > Agents with on/off, client grants, Copy config and the activity log. Lets Rosh try Claude, Codex and Ollama safely. |
| **A2. Organize** | Ratings, flags, labels, keywords, collections, cull groups. Guard, toast and named undo steps, "did you mean" errors, recheck after waiting. |
| **A3. Edit** | Develop adjust, auto, presets, sync, crop, masks, Match Look. `command_run` and atomic `command_batch`. Wait for an active drag. |
| **A4. Everything** | Export, Edit In and AI recipes with an Allow bound to the exact operation, rechecks at run time, folder roots, background jobs, progress and Cancel. |
| **A5. Optional** | HTTP listener with Tailscale and a token, request keys for retries, App Intents for Shortcuts, MCP prompts such as "Cull this import" (built as the person's own skills in SL-002c: `prompts/list`, `prompts/get` and `get_skill`). |

Each phase is one PR, updating the PRD, Help (a new Agents page) and BACKLOG.md. A1 is the cheapest real test of whether this gets used day to day.

## The same approach in Easel

Rosh wants Easel to work the same way once this is implemented, so one chat setup and the same habits work in both apps. VectorCraft does this across the Craft apps: the same tool names and flags, so one client config fits the suite.

- **Shared plumbing, app-specific actions.** The parts that don't know about photos go in one app-neutral Swift module: the action and risk-tier types, the MCP server, `command_list` / `command_run` / `command_batch`, the guard and its Allow sheet, the socket, the helper, the activity log and the Settings > Agents pane. Each app supplies its own actions, typed tools and targets (photos in Atelier; documents, layers and selections in Easel) and assigns their tiers.
- **Same names everywhere.** Same tool names, profiles (Look, Organize, Edit, Everything), error style, tiers and config shape. Each app has its own helper (`atelier-mcp`, `easel-mcp`) and its own private socket.
- **What exactly is shared** is listed under "The shared module" in the review rules above.
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
- OpenCode MCP servers: https://opencode.ai/docs/mcp-servers/ ; models: https://opencode.ai/docs/console/models/
- Cherry Studio, Configure and Use MCP: https://docs.cherry-ai.com/docs/en-us/advanced-basic/mcp/config
- mcp-client-for-ollama (ollmcp) README: https://github.com/jonigl/mcp-client-for-ollama
- Ollama blog and repository (no built-in MCP client found): https://ollama.com/blog , https://github.com/ollama/ollama
- LM Studio MCP: https://lmstudio.ai/docs/app/mcp
- Open WebUI MCP: https://docs.openwebui.com/features/mcp ; mcpo: https://github.com/open-webui/mcpo
- Claude Desktop local servers: https://modelcontextprotocol.io/quickstart/user ; Claude Code MCP: https://code.claude.com/docs/en/mcp
- Codex configuration: https://github.com/openai/codex/blob/main/docs/config.md
- Codex design review of this document, Nov 13, 2026: https://github.com/roshan-davis/atelier/pull/115#issuecomment-6842233533
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

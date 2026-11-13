import AgentActions
import AgentMCP
import Foundation

/// The photo carousel (AT-050i): an MCP Apps view, `ui://atelier/photos`, that a chat app which
/// shows views (Docent) puts in place of search_photos' and cull_groups' text. It shows the
/// photos as a strip of cards with their rating, flag and label, fetches thumbnails through
/// `get_thumbnails` (only when Settings > Agents lets agents see previews), and offers Show in
/// Atelier (the `show` tool, Organize and up) and Ask about this photo (a chat message the person
/// sends by clicking). Clients without views get the same tools with their text, unchanged.
public enum AtelierPhotoCarousel {
    public static let uri = "ui://atelier/photos"

    /// The link search_photos and cull_groups carry.
    public static let link = MCPToolUI(resourceURI: uri)

    /// Thumbnails per call; the view asks in pages.
    public static let thumbnailPage = 24
    /// Longest side of a thumbnail, in pixels.
    public static let thumbnailSize = 320

    public static let getThumbnails = MCPTool(
        name: "get_thumbnails", title: "Photo thumbnails",
        description: "Small JPEG thumbnails of photos as data URLs, for Atelier's photo carousel. Only the carousel calls it.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ids": .object(["type": .string("array"), "items": .object(["type": .string("integer")]),
                                "maxItems": .int(thumbnailPage),
                                "description": .string("Photo ids, at most \(thumbnailPage).")]),
            ]),
            "required": .array([.string("ids")]),
            "additionalProperties": .bool(false),
        ]),
        readOnly: true, idempotent: true, ui: .appOnly)

    public static let resource = MCPResource(
        uri: uri, name: "photos", title: "Photos",
        description: "Photos from Atelier as a carousel, with Show in Atelier.",
        mimeType: MCPApps.mimeType, text: html,
        // Everything is inline and thumbnails are data URLs: no outside connections at all.
        ui: .object(["csp": .object([:]), "prefersBorder": .bool(false)]))

    /// The ids `get_thumbnails` was given, checked: whole numbers, at most one page, no repeats.
    public static func thumbnailIDs(_ arguments: [String: JSONValue]) -> Result<[Int64], ParameterCheck.Problems> {
        guard let list = arguments["ids"]?.arrayValue else {
            return .failure(.init(messages: ["ids is required: a list of photo ids."]))
        }
        var ids: [Int64] = []
        for value in list {
            guard let id = value.intValue else { return .failure(.init(messages: ["ids holds whole numbers."])) }
            if !ids.contains(Int64(id)) { ids.append(Int64(id)) }
        }
        guard ids.count <= thumbnailPage else {
            return .failure(.init(messages: ["ids holds at most \(thumbnailPage) photos; ask in pages."]))
        }
        return .success(ids)
    }

    // The page. Plain HTML, CSS and JavaScript, with nothing loaded from outside. It speaks the
    // MCP Apps messages over postMessage: ui/initialize, then tool-input and tool-result from the
    // host; tools/call, ui/message and size-changed back.
    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Photos</title>
<style>
:root {
  --bg: var(--color-background-primary, #ffffff);
  --card: var(--color-background-secondary, #f2f2f4);
  --text: var(--color-text-primary, #1d1d1f);
  --text-2: var(--color-text-secondary, #6b6e75);
  --line: var(--color-border-primary, #dcdce1);
  --accent: #0a7cff;
  --star: #c48a00;
  --font: var(--font-sans, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif);
  color-scheme: light;
}
:root[data-theme="dark"] {
  --bg: var(--color-background-primary, #1f1f1f);
  --card: var(--color-background-secondary, #2b2b2b);
  --text: var(--color-text-primary, #e8e8e8);
  --text-2: var(--color-text-secondary, #9b9b9b);
  --line: var(--color-border-primary, #3d3d3d);
  --accent: #0a84ff;
  --star: #e7b416;
  color-scheme: dark;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: var(--color-background-primary, #1f1f1f);
    --card: var(--color-background-secondary, #2b2b2b);
    --text: var(--color-text-primary, #e8e8e8);
    --text-2: var(--color-text-secondary, #9b9b9b);
    --line: var(--color-border-primary, #3d3d3d);
    --accent: #0a84ff;
    --star: #e7b416;
    color-scheme: dark;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text); font: 13px/1.35 var(--font); }
body { padding: 10px 12px 12px; }
header { display: flex; align-items: baseline; gap: 8px; margin-bottom: 8px; }
header h1 { font-size: 13px; font-weight: 600; margin: 0; }
header .count { color: var(--text-2); }
header .spacer { flex: 1; }
.nav { display: flex; gap: 4px; }
button {
  font: inherit; color: var(--text); background: var(--card); border: 1px solid var(--line);
  border-radius: 6px; padding: 3px 10px; cursor: pointer;
}
button:hover:not(:disabled) { border-color: var(--accent); }
button:disabled { opacity: 0.45; cursor: default; }
button.icon { padding: 3px 8px; }
.strip {
  display: flex; gap: 10px; overflow-x: auto; scroll-snap-type: x mandatory; scroll-behavior: smooth;
  padding: 2px 2px 8px; outline: none; scrollbar-width: thin;
}
.card {
  flex: 0 0 168px; scroll-snap-align: start; background: var(--card); border: 1px solid var(--line);
  border-radius: 8px; overflow: hidden; cursor: pointer; text-align: left; padding: 0; display: block;
}
.card:focus-visible, .card.selected { outline: none; border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent); }
.thumb {
  height: 120px; display: flex; align-items: center; justify-content: center; background: rgba(127,127,127,0.12);
  color: var(--text-2); font-size: 11px; overflow: hidden;
}
.thumb img { width: 100%; height: 100%; object-fit: contain; display: block; }
.info { padding: 6px 8px 7px; }
.name { font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.meta { display: flex; align-items: center; gap: 6px; color: var(--text-2); font-size: 11px; margin-top: 2px; min-height: 15px; }
.stars { color: var(--star); letter-spacing: 1px; }
.stars .off { color: var(--line); }
.flag { font-weight: 600; }
.flag.picked { color: #1f8a4c; }
.flag.rejected { color: #d23c3c; }
.label { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
.label.red { background: #e5484d; } .label.yellow { background: #e7b416; } .label.green { background: #30a46c; }
.label.blue { background: #0a7cff; } .label.purple { background: #8e4ec6; }
.more { flex: 0 0 120px; display: flex; align-items: center; justify-content: center; }
.actions { display: flex; align-items: center; gap: 8px; margin-top: 4px; min-height: 26px; }
.status { color: var(--text-2); font-size: 12px; flex: 1; min-width: 0; }
.note { color: var(--text-2); font-size: 12px; margin-top: 6px; }
.empty { color: var(--text-2); padding: 18px 0; }
</style>
</head>
<body>
<header>
  <h1>Photos</h1><span class="count" id="count"></span><span class="spacer"></span>
  <div class="nav"><button class="icon" id="prev" aria-label="Previous photos">‹</button><button class="icon" id="next" aria-label="Next photos">›</button></div>
</header>
<div class="strip" id="strip" role="listbox" aria-label="Photos" tabindex="0"><div class="empty">Waiting for photos…</div></div>
<div class="actions">
  <span class="status" id="status" role="status"></span>
  <button id="ask" disabled>Ask about this photo</button>
  <button id="show" disabled>Show in Atelier</button>
</div>
<div class="note" id="note" hidden></div>
<script>
(() => {
  "use strict";
  const PAGE = 24;
  const host = window.parent;
  let nextId = 1;
  const pending = new Map();
  let photos = [];
  let total = 0;
  let nextOffset = null;
  let toolName = "search_photos";
  let toolArguments = {};
  let selected = null;
  let thumbsOff = false;
  const thumbs = new Map();

  const $ = (id) => document.getElementById(id);
  const strip = $("strip");

  function send(message) { host.postMessage(message, "*"); }
  function request(method, params) {
    const id = nextId++;
    send({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  }
  function notify(method, params) { send({ jsonrpc: "2.0", method, params }); }

  function setTheme(context) {
    if (!context) return;
    if (context.theme === "dark" || context.theme === "light") document.documentElement.dataset.theme = context.theme;
    const variables = context.styles && context.styles.variables;
    if (variables) for (const [name, value] of Object.entries(variables)) {
      if (typeof value === "string" && name.startsWith("--")) document.documentElement.style.setProperty(name, value);
    }
  }

  window.addEventListener("message", (event) => {
    if (event.source !== host) return;
    const message = event.data;
    if (!message || message.jsonrpc !== "2.0") return;
    if (message.id !== undefined && pending.has(message.id) && !message.method) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(message.error); else resolve(message.result);
      return;
    }
    switch (message.method) {
      case "ui/notifications/tool-input":
        toolArguments = (message.params && message.params.arguments) || {};
        break;
      case "ui/notifications/tool-result":
        received(message.params || {});
        break;
      case "ui/notifications/host-context-changed":
        setTheme(message.params);
        break;
      default:
        // Requests from the host (ping, ui/resource-teardown): nothing to clean up.
        if (message.id !== undefined && message.method) send({ jsonrpc: "2.0", id: message.id, result: {} });
    }
  });

  function received(result, appending) {
    const content = result.structuredContent;
    if (result.isError || !content || !Array.isArray(content.photos)) {
      const text = (result.content || []).filter((c) => c.type === "text").map((c) => c.text).join(" ");
      if (!appending) { photos = []; render(); }
      status(text || "No photos to show.");
      return;
    }
    photos = appending ? photos.concat(content.photos) : content.photos;
    total = typeof content.total === "number" ? content.total : photos.length;
    nextOffset = typeof content.next_offset === "number" ? content.next_offset : null;
    if (!appending) selected = null;
    render();
    loadThumbnails();
  }

  function stars(rating) {
    const span = document.createElement("span");
    span.className = "stars";
    span.setAttribute("aria-label", rating + (rating === 1 ? " star" : " stars"));
    for (let i = 1; i <= 5; i++) {
      const star = document.createElement("span");
      star.textContent = "★";
      if (i > rating) star.className = "off";
      span.appendChild(star);
    }
    return span;
  }

  function card(photo, index) {
    const button = document.createElement("button");
    button.className = "card";
    button.setAttribute("role", "option");
    button.dataset.index = index;
    const thumb = document.createElement("div");
    thumb.className = "thumb";
    const data = thumbs.get(photo.id);
    if (data) {
      const image = document.createElement("img");
      image.src = data;
      image.alt = photo.filename || "Photo " + photo.id;
      thumb.appendChild(image);
    } else {
      thumb.textContent = thumbsOff ? "No preview" : "…";
    }
    const info = document.createElement("div");
    info.className = "info";
    const name = document.createElement("div");
    name.className = "name";
    name.textContent = photo.filename || "Photo " + photo.id;
    name.title = name.textContent;
    const meta = document.createElement("div");
    meta.className = "meta";
    if (typeof photo.rating === "number") meta.appendChild(stars(photo.rating));
    if (photo.flag === "picked" || photo.flag === "rejected") {
      const flag = document.createElement("span");
      flag.className = "flag " + photo.flag;
      flag.textContent = photo.flag === "picked" ? "⚑ Pick" : "✕ Reject";
      meta.appendChild(flag);
    }
    if (photo.label) {
      const label = document.createElement("span");
      label.className = "label " + photo.label;
      label.title = photo.label[0].toUpperCase() + photo.label.slice(1);
      meta.appendChild(label);
    }
    info.append(name, meta);
    button.append(thumb, info);
    button.addEventListener("click", () => select(index));
    button.addEventListener("dblclick", () => { select(index); show(); });
    return button;
  }

  // Thumbnails go into the cards already there, so focus and scrolling stay put.
  function placeThumbnails() {
    strip.querySelectorAll(".card").forEach((element) => {
      const photo = photos[Number(element.dataset.index)];
      const data = photo && thumbs.get(photo.id);
      const thumb = element.querySelector(".thumb");
      if (!data || !thumb || thumb.querySelector("img")) return;
      const image = document.createElement("img");
      image.src = data;
      image.alt = photo.filename || "Photo " + photo.id;
      thumb.replaceChildren(image);
    });
  }

  function render() {
    strip.replaceChildren();
    if (photos.length === 0) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent = "No photos.";
      strip.appendChild(empty);
    }
    photos.forEach((photo, index) => strip.appendChild(card(photo, index)));
    if (nextOffset !== null && toolName === "search_photos") {
      const more = document.createElement("div");
      more.className = "more";
      const button = document.createElement("button");
      button.textContent = (total - photos.length) + " more";
      button.addEventListener("click", loadMore);
      more.appendChild(button);
      strip.appendChild(more);
    }
    $("count").textContent = photos.length === total ? String(total) : photos.length + " of " + total;
    $("note").hidden = !thumbsOff;
    $("note").textContent = thumbsOff
      ? "Atelier doesn't let chat apps see photos. Turn on Let agents see photo previews in Atelier > Settings… > Agents to see them here."
      : "";
    highlight();
    sizeChanged();
  }

  function highlight() {
    strip.querySelectorAll(".card").forEach((element) => {
      const on = Number(element.dataset.index) === selected;
      element.classList.toggle("selected", on);
      element.setAttribute("aria-selected", on ? "true" : "false");
    });
    $("show").disabled = selected === null;
    $("ask").disabled = selected === null;
  }

  function select(index) {
    if (index < 0 || index >= photos.length) return;
    selected = index;
    highlight();
    const element = strip.querySelector('.card[data-index="' + index + '"]');
    if (element) { element.focus({ preventScroll: true }); element.scrollIntoView({ block: "nearest", inline: "nearest" }); }
    status("");
  }

  function status(text) { $("status").textContent = text; }

  async function loadThumbnails() {
    if (thumbsOff) return;
    const missing = photos.map((photo) => photo.id).filter((id) => !thumbs.has(id));
    for (let start = 0; start < missing.length; start += PAGE) {
      const ids = missing.slice(start, start + PAGE);
      try {
        const result = await request("tools/call", { name: "get_thumbnails", arguments: { ids } });
        if (result.isError) {
          const text = (result.content || []).map((c) => c.text || "").join(" ");
          if (/previews|see photos/i.test(text)) { thumbsOff = true; render(); return; }
          continue;
        }
        for (const item of (result.structuredContent && result.structuredContent.thumbnails) || []) {
          if (typeof item.data === "string" && item.data.startsWith("data:image/")) thumbs.set(item.id, item.data);
        }
        placeThumbnails();
      } catch (error) {
        // The tool isn't offered: previews are off in Settings > Agents.
        thumbsOff = true;
        render();
        return;
      }
    }
  }

  async function loadMore() {
    if (nextOffset === null) return;
    status("Loading…");
    try {
      const result = await request("tools/call", { name: "search_photos", arguments: Object.assign({}, toolArguments, { offset: nextOffset }) });
      status("");
      received(result, true);
    } catch (error) {
      status((error && error.message) || "Atelier couldn't load more photos.");
    }
  }

  async function show() {
    if (selected === null) return;
    const photo = photos[selected];
    status("Showing in Atelier…");
    try {
      const result = await request("tools/call", { name: "show", arguments: { ids: [photo.id] } });
      const text = (result.content || []).map((c) => c.text || "").join(" ");
      status(result.isError ? text : "Shown in Atelier.");
    } catch (error) {
      const message = (error && error.message) || "";
      status(/Unknown tool/.test(message)
        ? "Show in Atelier needs the Organize profile (Atelier > Settings… > Agents)."
        : message || "Atelier couldn't show the photo.");
    }
  }

  async function ask() {
    if (selected === null) return;
    const photo = photos[selected];
    try {
      await request("ui/message", { role: "user", content: { type: "text", text: "Tell me about photo " + photo.id + " (" + (photo.filename || "") + ")." } });
      status("");
    } catch (error) {
      status("This chat app can't send messages from here.");
    }
  }

  function page(direction) { strip.scrollBy({ left: direction * strip.clientWidth * 0.9 }); }

  $("prev").addEventListener("click", () => page(-1));
  $("next").addEventListener("click", () => page(1));
  $("show").addEventListener("click", show);
  $("ask").addEventListener("click", ask);
  strip.addEventListener("keydown", (event) => {
    if (event.key === "ArrowRight") { select(selected === null ? 0 : selected + 1); event.preventDefault(); }
    else if (event.key === "ArrowLeft") { select(selected === null ? 0 : selected - 1); event.preventDefault(); }
    else if (event.key === "Enter" && selected !== null) { show(); event.preventDefault(); }
  });

  let lastHeight = 0;
  function sizeChanged() {
    const height = Math.ceil(document.documentElement.getBoundingClientRect().height);
    if (height === lastHeight) return;
    lastHeight = height;
    notify("ui/notifications/size-changed", { height });
  }
  new ResizeObserver(sizeChanged).observe(document.body);

  request("ui/initialize", {
    protocolVersion: "2026-01-26",
    appInfo: { name: "Atelier Photos", version: "1" },
    appCapabilities: {},
  }).then((result) => {
    setTheme(result && result.hostContext);
    if (result && result.hostContext && result.hostContext.toolInfo && result.hostContext.toolInfo.tool) {
      toolName = result.hostContext.toolInfo.tool.name || toolName;
    }
    notify("ui/notifications/initialized", {});
  }).catch(() => notify("ui/notifications/initialized", {}));
})();
</script>
</body>
</html>
"""#
}

// Lightfast Help: the sidebar, search, before/after sliders and the drawn slider rows.
// Pages list their content in plain HTML; this file only adds behavior. The page list and the
// search index come from toc.js, which Scripts/help/build_help_index.py writes.
(function () {
  "use strict";

  const toc = window.HELP_TOC || { groups: [], sections: [] };
  const here = (location.pathname.split("/").pop() || "index.html").replace(/\.html$/, "") || "index";

  // MARK: Sidebar

  function buildSidebar() {
    const layout = document.createElement("div");
    layout.className = "layout";
    const sidebar = document.createElement("nav");
    sidebar.className = "sidebar";
    sidebar.setAttribute("aria-label", "Help topics");
    sidebar.innerHTML =
      '<a class="brand" href="index.html"><span class="brand-mark"></span>Lightfast Help</a>' +
      '<div class="search"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8">' +
      '<circle cx="7" cy="7" r="5"/><path d="M11 11l3.5 3.5" stroke-linecap="round"/></svg>' +
      '<input type="search" placeholder="Search Help" aria-label="Search Help" autocomplete="off" spellcheck="false"></div>' +
      '<div class="results" hidden></div><div class="nav"></div>';
    const nav = sidebar.querySelector(".nav");
    for (const group of toc.groups) {
      const heading = document.createElement("div");
      heading.className = "nav-group";
      heading.textContent = group.title;
      nav.appendChild(heading);
      for (const page of group.pages) {
        const link = document.createElement("a");
        link.href = page.file;
        link.textContent = page.title;
        if (page.file.replace(/\.html$/, "") === here) link.className = "current";
        nav.appendChild(link);
      }
    }

    const toggle = document.createElement("button");
    toggle.className = "menu-toggle";
    toggle.textContent = "☰ Topics";
    toggle.addEventListener("click", () => sidebar.classList.toggle("open"));

    const content = document.createElement("div");
    content.className = "content";
    const page = document.querySelector("main.page") || document.body.firstElementChild;
    content.appendChild(page);
    layout.appendChild(sidebar);
    layout.appendChild(content);
    document.body.prepend(toggle);
    document.body.appendChild(layout);

    const current = nav.querySelector("a.current");
    if (current) current.scrollIntoView({ block: "center" });
    setupSearch(sidebar);
  }

  // MARK: Search

  function words(text) {
    return text.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").split(/[^a-z0-9⌘⇧⌥]+/).filter(Boolean);
  }

  function score(section, terms) {
    const title = section.title.toLowerCase();
    const page = section.page.toLowerCase();
    const text = section.text.toLowerCase();
    let total = 0;
    for (const term of terms) {
      let s = 0;
      if (title.split(/\W+/).includes(term)) s += 12;
      else if (title.includes(term)) s += 8;
      if (page.includes(term)) s += 3;
      const hits = text.split(term).length - 1;
      s += Math.min(hits, 5);
      if (s === 0) return 0; // every word must match somewhere
      total += s;
    }
    return total;
  }

  function setupSearch(sidebar) {
    const input = sidebar.querySelector("input");
    const results = sidebar.querySelector(".results");
    const nav = sidebar.querySelector(".nav");
    let active = 0;

    function render() {
      const terms = words(input.value);
      if (!terms.length) {
        results.hidden = true;
        nav.hidden = false;
        return;
      }
      const found = toc.sections
        .map((s) => ({ s, score: score(s, terms) }))
        .filter((r) => r.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, 25);
      results.innerHTML = "";
      if (!found.length) {
        results.innerHTML = '<div class="empty">No topics match “' + escapeHTML(input.value) + "”.</div>";
      }
      found.forEach((r, i) => {
        const link = document.createElement("a");
        link.href = r.s.file + (r.s.id ? "#" + r.s.id : "");
        link.innerHTML = '<div class="r-title"></div><div class="r-page"></div>';
        link.firstChild.textContent = r.s.title;
        link.lastChild.textContent = r.s.page;
        if (i === active) link.classList.add("active");
        results.appendChild(link);
      });
      results.hidden = false;
      nav.hidden = true;
    }

    input.addEventListener("input", () => { active = 0; render(); });
    input.addEventListener("keydown", (event) => {
      const links = results.querySelectorAll("a");
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        if (!links.length) return;
        active = (active + (event.key === "ArrowDown" ? 1 : links.length - 1)) % links.length;
        links.forEach((l, i) => l.classList.toggle("active", i === active));
        links[active].scrollIntoView({ block: "nearest" });
      } else if (event.key === "Enter" && links[active]) {
        location.href = links[active].href;
      } else if (event.key === "Escape") {
        input.value = "";
        render();
        input.blur();
      }
    });
    document.addEventListener("keydown", (event) => {
      const typing = /input|textarea/i.test(document.activeElement.tagName);
      if ((event.key === "f" && (event.metaKey || event.ctrlKey)) || (event.key === "/" && !typing)) {
        event.preventDefault();
        input.focus();
        input.select();
      }
    });
    // The app opens Help with ?search=word to search straight away.
    const query = new URLSearchParams(location.search).get("search");
    if (query) {
      input.value = query;
      render();
    }
  }

  function escapeHTML(text) {
    return text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  }

  // MARK: Headings get anchors, so any section can be linked to

  function anchorHeadings() {
    document.querySelectorAll("main h2[id], main h3[id]").forEach((h) => {
      const a = document.createElement("a");
      a.className = "anchor";
      a.href = "#" + h.id;
      a.textContent = "#";
      a.setAttribute("aria-label", "Link to this section");
      h.appendChild(a);
    });
  }

  // MARK: Drawn slider rows

  const GRADIENTS = {
    temp: "linear-gradient(90deg, #4d80ff, #ffd94d)",
    tint: "linear-gradient(90deg, #4dcc4d, #d94dd9)",
    sat: "linear-gradient(90deg, #808080, #ff6633, #4d99ff)",
    bw: "linear-gradient(90deg, #000, #fff)",
    rainbow: "linear-gradient(90deg, hsl(0,80%,55%), hsl(60,80%,55%), hsl(120,80%,55%), hsl(180,80%,55%), hsl(240,80%,55%), hsl(300,80%,55%), hsl(360,80%,55%))",
  };

  function gradient(name) {
    if (!name) return null;
    if (GRADIENTS[name]) return GRADIENTS[name];
    const [kind, value] = name.split("-");
    const h = Number(value);
    const c = (hue) => "hsl(" + ((hue + 360) % 360) + ", 85%, 55%)";
    if (kind === "hue") return "linear-gradient(90deg, " + c(h - 30) + ", " + c(h) + ", " + c(h + 30) + ")";
    if (kind === "sat") return "linear-gradient(90deg, #808080, " + c(h) + ")";
    if (kind === "lum" || kind === "gray") return "linear-gradient(90deg, #000, " + c(h) + ", #fff)";
    return null;
  }

  // <div class="sl" data-name="Exposure" data-value="+0.60" data-at="0.56" data-def="0.5" data-gradient="temp">
  // data-at and data-def are positions along the track, 0...1.
  function drawSlider(el) {
    const at = Number(el.dataset.at ?? 0.5);
    const def = el.dataset.def === undefined ? 0.5 : Number(el.dataset.def);
    const grad = gradient(el.dataset.gradient);
    el.innerHTML =
      '<span class="name"></span><span class="track"><span class="bar"></span><span class="fill"></span>' +
      '<span class="mark"></span><span class="knob"></span></span><span class="value"></span>';
    el.querySelector(".name").textContent = el.dataset.name || "";
    const value = el.querySelector(".value");
    value.textContent = el.dataset.value ?? "0";
    if (el.dataset.value !== undefined && Math.abs(at - def) > 0.001) value.classList.add("changed");
    const bar = el.querySelector(".bar");
    const fill = el.querySelector(".fill");
    const mark = el.querySelector(".mark");
    if (grad) {
      bar.style.background = grad;
      fill.remove();
    }
    if (def <= 0.005 || def >= 0.995) mark.remove();
    else mark.style.left = def * 100 + "%";
    setSlider(el, at, def);
  }

  function setSlider(el, at, def) {
    const knob = el.querySelector(".knob");
    const fill = el.querySelector(".fill");
    knob.style.left = at * 100 + "%";
    if (fill) {
      fill.style.left = Math.min(at, def) * 100 + "%";
      fill.style.width = Math.abs(at - def) * 100 + "%";
    }
  }

  // MARK: Interactive slider figures

  // <div class="frame scrub" data-frames="a.jpg,b.jpg,c.jpg" data-values="-1,0,+1" data-name="Exposure"
  //      data-start="2" data-def="2" data-gradient="temp" data-hint="Drag the slider">
  function buildScrub(el) {
    const frames = el.dataset.frames.split(",");
    const values = el.dataset.values.split(",");
    const start = Number(el.dataset.start ?? Math.floor(frames.length / 2));
    const defIndex = Number(el.dataset.def ?? start);
    const n = frames.length - 1;
    el.innerHTML = '<div class="stack"></div><div class="scrub-controls"><div class="sl live"></div>' +
      '<span class="hint"></span></div>';
    const stack = el.querySelector(".stack");
    frames.forEach((src, i) => {
      const img = document.createElement("img");
      img.src = "images/" + src;
      img.alt = (el.dataset.name || "") + " " + values[i];
      if (i === start) img.className = "on";
      stack.appendChild(img);
    });
    const slider = el.querySelector(".sl");
    slider.dataset.name = el.dataset.name || "";
    slider.dataset.value = values[start];
    slider.dataset.at = String(start / n);
    slider.dataset.def = String(defIndex / n);
    if (el.dataset.gradient) slider.dataset.gradient = el.dataset.gradient;
    drawSlider(slider);
    el.querySelector(".hint").textContent = el.dataset.hint || "Drag the slider";

    const track = slider.querySelector(".track");
    const imgs = stack.querySelectorAll("img");
    // The first picture stays in the flow and sets the height; the others sit on top.
    imgs.forEach((img, i) => { if (i > 0) img.style.position = "absolute"; });
    let index = start;
    function show(i) {
      index = i;
      imgs.forEach((img, j) => img.classList.toggle("on", j === i || j === 0));
      setSlider(slider, i / n, defIndex / n);
      const value = slider.querySelector(".value");
      value.textContent = values[i];
      value.classList.toggle("changed", i !== defIndex);
    }
    function at(event) {
      const rect = track.getBoundingClientRect();
      const f = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width));
      show(Math.round(f * n));
    }
    track.addEventListener("pointerdown", (event) => {
      track.setPointerCapture(event.pointerId);
      at(event);
    });
    track.addEventListener("pointermove", (event) => { if (event.buttons) at(event); });
    track.addEventListener("dblclick", () => show(defIndex));
    slider.querySelector(".name").addEventListener("dblclick", () => show(defIndex));
    show(start);
  }

  // MARK: Before/after sliders

  // <div class="frame compare" data-before="a.jpg" data-after="b.jpg" data-labels="Before|After" data-at="0.5">
  function buildCompare(el) {
    const [beforeLabel, afterLabel] = (el.dataset.labels || "Before|After").split("|");
    el.innerHTML =
      '<img class="b" alt=""><div class="after-wrap"><img class="a" alt=""></div><div class="divider"></div>' +
      '<div class="handle">↔</div><span class="tag before"></span><span class="tag after"></span>';
    el.querySelector("img.b").src = "images/" + el.dataset.before;
    el.querySelector("img.a").src = "images/" + el.dataset.after;
    el.querySelector("img.b").alt = beforeLabel;
    el.querySelector("img.a").alt = afterLabel;
    el.querySelector(".tag.before").textContent = beforeLabel;
    el.querySelector(".tag.after").textContent = afterLabel;
    el.setAttribute("role", "slider");
    el.setAttribute("aria-label", "Drag to compare " + beforeLabel + " and " + afterLabel);
    el.tabIndex = 0;
    const wrap = el.querySelector(".after-wrap");
    const divider = el.querySelector(".divider");
    const handle = el.querySelector(".handle");
    const tags = el.querySelectorAll(".tag");
    let position = Number(el.dataset.at ?? 0.5);
    function set(f) {
      position = Math.min(1, Math.max(0, f));
      wrap.style.clipPath = "inset(0 0 0 " + position * 100 + "%)";
      divider.style.left = handle.style.left = position * 100 + "%";
      tags[0].style.opacity = position > 0.14 ? 1 : 0;
      tags[1].style.opacity = position < 0.86 ? 1 : 0;
      el.setAttribute("aria-valuenow", Math.round(position * 100));
    }
    function at(event) {
      const rect = el.getBoundingClientRect();
      set((event.clientX - rect.left) / rect.width);
    }
    el.addEventListener("pointerdown", (event) => {
      el.setPointerCapture(event.pointerId);
      at(event);
    });
    el.addEventListener("pointermove", (event) => { if (event.buttons) at(event); });
    el.addEventListener("keydown", (event) => {
      if (event.key === "ArrowLeft") set(position - 0.05);
      if (event.key === "ArrowRight") set(position + 0.05);
    });
    set(position);
  }

  // MARK: Histogram drawings

  // <canvas class="histogram" data-source="redwoods"></canvas>
  function drawHistogram(canvas) {
    const data = (window.HELP_HISTOGRAM || {})[canvas.dataset.source || "redwoods"];
    if (!data) return;
    const ratio = window.devicePixelRatio || 1;
    const width = canvas.clientWidth || 300;
    const height = canvas.clientHeight || 90;
    canvas.width = width * ratio;
    canvas.height = height * ratio;
    const ctx = canvas.getContext("2d");
    ctx.scale(ratio, ratio);
    ctx.globalCompositeOperation = "lighter";
    const channels = canvas.dataset.channel === "l"
      ? [[data.l, "rgba(255,255,255,0.22)"]]
      : [[data.r, "rgba(230,51,51,0.7)"], [data.g, "rgba(51,204,77,0.7)"], [data.b, "rgba(64,102,255,0.7)"]];
    for (const [bins, color] of channels) {
      ctx.beginPath();
      ctx.moveTo(0, height);
      bins.forEach((v, i) => ctx.lineTo((width * i) / (bins.length - 1), height * (1 - v * 0.92)));
      ctx.lineTo(width, height);
      ctx.closePath();
      ctx.fillStyle = color;
      ctx.fill();
    }
  }

  // MARK: Numbered pins

  // Inside <div class="pins">, any element with data-pin="3" gets a numbered pin in the left
  // margin, level with it. Positions follow the layout, so pins never drift off their rows.
  function placePins(wrap) {
    wrap.querySelectorAll(":scope > .pin.auto").forEach((p) => p.remove());
    const box = wrap.getBoundingClientRect();
    wrap.querySelectorAll("[data-pin]").forEach((el) => {
      const r = el.getBoundingClientRect();
      const pin = document.createElement("span");
      pin.className = "pin auto";
      pin.textContent = el.dataset.pin;
      const side = el.dataset.pinSide;
      let x;
      if (wrap.classList.contains("pinned")) {
        x = side === "right" ? box.width - 14 : 14; // in the gutter beside the panel
      } else if (side === "center") {
        x = r.left - box.left + r.width / 2;
      } else if (side === "right") {
        x = r.right - box.left - 10;
      } else if (side === "left") {
        x = r.left - box.left - 12;
      } else {
        x = r.left - box.left + 10;
      }
      let y = r.top - box.top + r.height / 2;
      // On a drawn window, pins sit just above their part (or beside it), so they never hide its label.
      if (!wrap.classList.contains("pinned") && side !== "center" && side !== "left") y = r.top - box.top - 7;
      pin.style.left = x + "px";
      pin.style.top = y + "px";
      wrap.appendChild(pin);
    });
  }

  // MARK: Start

  function start() {
    anchorHeadings();
    document.querySelectorAll(".sl").forEach((el) => { if (!el.closest(".scrub")) drawSlider(el); });
    document.querySelectorAll(".scrub").forEach(buildScrub);
    document.querySelectorAll(".compare").forEach(buildCompare);
    buildSidebar();
    document.querySelectorAll("canvas.histogram").forEach(drawHistogram);
    const pinned = document.querySelectorAll(".pins");
    const place = () => pinned.forEach(placePins);
    place();
    window.addEventListener("resize", place);
    window.addEventListener("load", place);
    if (location.hash) {
      const target = document.getElementById(decodeURIComponent(location.hash.slice(1)));
      if (target) target.scrollIntoView();
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();

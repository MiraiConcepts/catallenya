// Archived-copy viewer for the blog's /tidings/ links: /view/?id=<snapshot id>.
// Fetches the SingleFile copy ArchiveBox saved (only Unlisted/Public snapshots
// open), repairs what breaks when a page is saved mid-load, and shows it in a
// sandboxed frame that can't run scripts:
//   1. lazy images still on their placeholder get the copy the archive saved
//      (or, failing that, their real address);
//   2. pop-up layers (role="dialog", aria-modal, <dialog>) are removed;
//   3. scrolling is unlocked;
//   4. footers stay at the end instead of floating over the article;
//   5. a Wayback Machine link loses archive.org's toolbar and the gap it leaves;
//   6. empty ad slots, which only reserve space for an ad that never loads, go;
//   7. layout the copy lost by being saved at desktop width is put back for a
//      phone (fixed-width tables, a hidden mobile art box, a crop-sized frame).
// Scripts, frames, plugins, inline handlers and javascript: links are stripped too.
(async () => {
  const status = document.getElementById("status");
  const frame = document.getElementById("page");
  const fail = (msg) => { status.textContent = msg; };

  const id = new URLSearchParams(location.search).get("id") || "";
  if (!/^[0-9a-fA-F-]{8,36}$/.test(id)) return fail("No archived copy here.");
  const base = `/snapshot/${id}`;

  let html, index;
  try {
    // raw=1: without it ArchiveBox may serve a "preview" instead of the file. It
    // reads SingleFile's tag-light HTML as Markdown and re-renders it, or injects
    // a stylesheet that shrinks every unsized image to 12rem.
    const res = await fetch(`${base}/singlefile/singlefile.html?raw=1`);
    if (!res.ok) throw new Error(res.status);
    html = await res.text();
    // ArchiveBox serves this as immutable for a year; revalidate, since it can grow.
    index = await fetch(`${base}/responses/index.jsonl`, { cache: "no-cache" }).then((r) => (r.ok ? r.text() : "")).catch(() => "");
  } catch {
    return fail("This archived copy isn't available.");
  }

  // Images ArchiveBox saved while loading the page: original URL -> archive URL.
  // A CDN's other size of the same picture still matches by file name.
  const saved = index.split("\n").filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter((e) => e && e.resourceType === "image" && e.status === 200 && /\.(jpe?g|png|webp|gif)$/.test(e.path));
  const name = (u) => { try { return decodeURIComponent(u.split(/[?#]/)[0]).split("/").pop(); } catch { return ""; } };
  const local = (url) => {
    let hit = saved.find((e) => e.url === url || e.url.endsWith(`/${url}`));
    const file = name(url);
    if (!hit && file.length > 8) hit = saved.find((e) => name(e.url) === file);
    return hit ? `${location.origin}${base}/responses/${hit.path.replace(/^\.\//, "")}` : null;
  };

  const doc = new DOMParser().parseFromString(html, "text/html"); // parsing runs nothing

  // 1. Lazy images saved before they loaded.
  const lazyAttrs = ["data-src", "data-lazy-src", "data-original", "data-srcset", "data-lazy-srcset"];
  for (const img of doc.querySelectorAll("img")) {
    const src = img.getAttribute("src") || "";
    if (src && !(src.startsWith("data:") && src.length < 2000)) continue;
    let url = lazyAttrs.map((a) => img.getAttribute(a)).find(Boolean);
    if (url && (url.includes(",") || /\s\d+[wx]$/.test(url.trim()))) url = url.split(",").map((c) => c.trim().split(/\s+/)[0]).filter(Boolean).pop();
    if (!url || !/^https?:/.test(url)) continue;
    img.setAttribute("src", local(url) || url);
    img.removeAttribute("srcset"); img.removeAttribute("sizes"); img.removeAttribute("loading");
    img.closest("picture")?.querySelectorAll("source").forEach((s) => s.remove());
    // The picture's box was sized by CSS for the crop the page would have served
    // at this width (WIRED: 3:4 on a phone), but the copy kept another (3:2), so
    // the image sits in a box of the wrong shape with the rest left blank. When
    // the address names its crop, the box follows it.
    const crop = url.match(/\/(\d+):(\d+)\//);
    const box = img.closest('[data-testid="aspect-ratio-container"]');
    if (crop && box && +crop[1] && +crop[2]) box.style.setProperty("--viewer-crop", `${(crop[2] / crop[1]) * 100}%`);
  }

  // 1b. Hero clips: SingleFile saves a <video> with no source. When a page has
  // exactly one, it gets the clip ArchiveBox kept from the page's own requests,
  // if a whole file was kept: some pages only yielded partial byte ranges, which
  // never play. A lead clip with nothing playable shows the featured image
  // instead. With several videos nothing says which clip is whose, so they keep
  // their poster stills (The Verge: 6 videos, 3 clips).
  const clips = index.split("\n").filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter((e) => e && e.resourceType === "media" && /\.(mp4|webm)$/.test(e.path || ""));
  const playable = async () => {
    for (const path of [...new Set(clips.map((e) => e.path.replace(/^\.\//, "")))].reverse()) {
      const head = await fetch(`${base}/responses/${path}`, { headers: { Range: "bytes=0-11" } })
        .then((r) => (r.ok ? r.arrayBuffer() : null)).catch(() => null);
      // An MP4 or WebM starts with its own header; a mid-file range does not.
      const b = head && new Uint8Array(head);
      if (b && (String.fromCharCode(...b.slice(4, 8)) === "ftyp" || (b[0] === 0x1a && b[1] === 0x45))) return path;
    }
    return null;
  };
  const featured = async () => {
    for (const ext of ["jpg", "png", "webp"]) {
      const url = `${base}/seo/featured-image.${ext}`;
      if (await fetch(url, { method: "HEAD" }).then((r) => r.ok).catch(() => false)) return url;
    }
    return null;
  };
  const bare = [...doc.querySelectorAll("video")].filter((v) => !v.getAttribute("src") && !v.querySelector("source"));
  const video = bare.length === 1 ? bare[0] : null;
  if (video) {
    const clip = clips.length ? await playable() : null;
    if (clip) {
      video.setAttribute("src", `${location.origin}${base}/responses/${clip}`);
      for (const a of ["muted", "autoplay", "loop", "playsinline"]) video.setAttribute(a, "");
      // The frame runs no scripts, so Chrome won't autoplay and shows its own
      // controls; the site's play/pause button is dead weight on top of them.
      video.parentElement?.querySelectorAll("button").forEach((b) => b.remove());
    } else if (video.closest('[class*="lead-asset" i], [class*="LeadAsset"], [class*="hero" i]')) {
      const still = await featured();
      if (still) {
        const img = doc.createElement("img");
        img.setAttribute("src", `${location.origin}${still}`);
        img.setAttribute("alt", video.getAttribute("aria-label") || "");
        img.setAttribute("style", "display:block;width:100%;height:auto");
        // The clip's own play/pause button has nothing left to control.
        video.parentElement?.querySelectorAll("button").forEach((b) => b.remove());
        video.replaceWith(img);
      }
    }
  }

  // 2. Pop-up layers, then any wrapper they leave empty.
  // Popovers too: nothing can open one here, and a closed one is often parked
  // off-screen, which made The Verge's page scroll sideways on a phone.
  for (const el of doc.querySelectorAll('[role="dialog"], [role="alertdialog"], [aria-modal="true"], dialog, [id^="popover-"]')) {
    let parent = el.parentElement;
    el.remove();
    for (let i = 0; i < 3 && parent && !parent.matches("body, main, article"); i++) {
      if (parent.children.length || parent.textContent.trim()) break;
      const up = parent.parentElement;
      parent.remove();
      parent = up;
    }
  }

  // 5. Wayback Machine toolbar, and the line breaks it leaves at the top of <body>
  // (the stray paragraphs there hold the page's stylesheets, so they stay).
  const wayback = !!doc.getElementById("wm-ipp-base");
  doc.querySelectorAll("#wm-ipp-base, #wm-ipp-print, #donato").forEach((e) => e.remove());
  if (wayback && doc.body) {
    let lead = doc.body.firstElementChild;
    while (lead && /^(P|BR)$/.test(lead.tagName)) {
      const next = lead.nextElementSibling;
      if (lead.tagName === "BR") lead.remove();
      lead = next;
    }
  }

  // 6. Ad slots: the ad's script never ran, so all that is left is a box holding
  // space for it (WIRED's sits inside its sticky header and pins a 266px gap to
  // the top of the screen). Only empty boxes go, so an ad-named class on real
  // content keeps it.
  const adClass = /^(ad|ads|advert|advertisement)$|^ad[-_]|[-_]ad$|^Ad[A-Z]\w*-|[a-z]Ad(Wrapper|Slot|Unit|Container)/;
  for (const el of doc.querySelectorAll("[class]")) {
    if (!el.isConnected || el.matches("html, body, main, article")) continue;
    if (![...el.classList].some((c) => adClass.test(c))) continue;
    if (el.textContent.trim() || el.querySelector("img[src]:not([src^='data:']), video[src], picture, svg")) continue;
    el.remove();
  }

  // 7. SingleFile saves at desktop width, so what only a phone would see is
  // marked sf-hidden (display:none for good) and anything sized for a desktop
  // stays that size.
  //  - The Verge's feature ledes: the square art box shown on a phone is hidden
  //    and emptied, while the lead clip below is still pulled up by its height
  //    and lands on the headline. Unhidden, the empty box holds the space again
  //    and the page's own CSS still hides it on a wide screen.
  doc.querySelectorAll(".duet--layout--entry-image .sf-hidden:empty").forEach((e) => e.classList.remove("sf-hidden"));
  //  - Old fixed-width pages (Clovis Free Press: a 600px table) run off a phone's
  //    edge mid-word. A pixel width becomes a ceiling instead of a size; fixed
  //    layout is what lets the cells, and the images in them, shrink with it.
  for (const el of doc.querySelectorAll("table[width]")) {
    const w = el.getAttribute("width").trim();
    if (/^\d+$/.test(w)) el.setAttribute("style", `${el.getAttribute("style") || ""};width:min(100%, ${w}px);table-layout:fixed`);
  }
  //  - A server-side include that failed when the page was saved left its error
  //    text in the copy.
  const ssi = "[an error occurred while processing this directive]";
  const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = walker.nextNode());) if (n.nodeValue.includes(ssi)) n.nodeValue = n.nodeValue.replaceAll(ssi, "");

  // Nothing that can run code survives.
  doc.querySelectorAll("script, noscript, iframe, frame, frameset, object, embed, applet, base, meta[http-equiv]").forEach((e) => e.remove());
  for (const el of doc.querySelectorAll("*")) {
    for (const { name: attr, value } of [...el.attributes]) {
      if (/^on/i.test(attr) || attr === "srcdoc" || /^\s*(javascript|vbscript):/i.test(value)) el.removeAttribute(attr);
    }
  }

  // 3 + 4. Unlock scrolling, keep footers in place; links open in a new tab.
  // The doubled :not(#_) outranks a page's own lock: the Guardian's consent banner
  // pins the page with `.sp-message-open body { overflow: hidden !important }`.
  // body stays visible, not auto: an auto body becomes its own scroll box and
  // swallows the wheel on pages like WIRED's.
  const style = doc.createElement("style");
  style.textContent = "html:not(#_):not(#_) { overflow: auto !important; height: auto !important; } html:not(#_):not(#_) body { overflow: visible !important; position: static !important; height: auto !important; }" +
    'footer, [class~="footer"], [class$="-footer"], [id~="footer"] { position: static !important; }' +
    '[data-testid="aspect-ratio-container"][style*="--viewer-crop"]::before { padding-top: var(--viewer-crop) !important; }' +
    "table[style*=table-layout] img { max-width: 100%; height: auto; }" +
    (wayback ? "body { margin-top: 0 !important; }" : "");
  doc.head.append(style);
  const target = doc.createElement("base");
  target.setAttribute("target", "_blank");
  doc.head.prepend(target);

  document.title = doc.title || "Archived copy";
  frame.srcdoc = "<!doctype html>" + doc.documentElement.outerHTML;
  frame.addEventListener("load", () => { status.remove(); frame.style.display = "block"; }, { once: true });
})();

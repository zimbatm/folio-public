.pragma library

// Markdown to Qt rich text. Qt's own Markdown importer sets code in the system
// fixed font at its own tiny size and drops text around inline HTML, so the
// app renders this subset itself: headings, paragraphs, nested lists, fenced
// and inline code, bold, italics, links, quotes, rules and tables.

var CODE = 'font-family: monospace; font-size: 26px';

function esc(t) {
    return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// links: real <a href> links, black and underlined (on web pages, where a tap
// opens them), else the link text underlined. A backslash escapes a Markdown
// character.
function inline(t, links) {
    var held = [];
    function hold(html) {
        held.push(html);
        return "\u0001" + (held.length - 1) + "\u0002";
    }
    t = t.replace(/\\([\\`*_\[\]()#|~>!+.-])/g, function (m, c) { return hold(esc(c)); });
    t = t.replace(/`([^`]+)`/g, function (m, c) {
        return hold('<span style="' + CODE + '">' + esc(c).replace(/ /g, "&nbsp;") + "</span>");
    });
    // an image, where a page view has no room for it: its description
    t = t.replace(/!\[([^\]]*)\]\([^)\s]*\)/g, function (m, alt) { return hold("<i>[" + esc(alt || "image") + "]</i>"); });
    // an address is not Markdown: its _ and * stay
    t = t.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (m, text, href) {
        return "[" + text + "](" + hold(esc(href).replace(/"/g, "%22")) + ")";
    });
    t = esc(t)
        .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
        .replace(/__(.+?)__/g, "<b>$1</b>")
        .replace(/(^|[^*])\*(?!\s)(.+?)\*(?!\*)/g, "$1<i>$2</i>")
        .replace(/(^|\W)_(?!\s)(.+?)_(?=\W|$)/g, "$1<i>$2</i>")
        .replace(/~~(.+?)~~/g, "<s>$1</s>")
        .replace(/\[([^\]]+)\]\(([^)]+)\)/g, links ? '<a href="$2" style="color: #000000; text-decoration: underline">$1</a>' : "<u>$1</u>");
    // twice: a held link can hold an escape
    for (var k = 0; k < 2; k++) t = t.replace(/\u0001(\d+)\u0002/g, function (m, i) { return held[+i]; });
    return t.replace(/\u0003/g, "|");
}

// a \| is a | in the cell
function cells(line) {
    return line.trim().replace(/\\\|/g, "\u0003").replace(/^\|/, "").replace(/\|$/, "").split("|").map(function (c) { return c.trim(); });
}

var LIST = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
var TABLE_SEP = /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/;

function toHtml(md, links) {
    var lines = md.replace(/\r/g, "").split("\n");
    var out = [];
    var para = [];
    var i = 0;

    function flush() {
        if (para.length) out.push("<p>" + para.map(function (s) { return inline(s, links); }).join(" ") + "</p>");
        para = [];
    }

    while (i < lines.length) {
        var line = lines[i];
        var m;

        if (/^\s*$/.test(line)) { flush(); i++; continue; }

        if (/^\s*```/.test(line)) {
            flush();
            var code = [];
            i++;
            while (i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i++]);
            i++;
            out.push('<pre style="' + CODE + '">' + esc(code.join("\n")) + "</pre>");
            continue;
        }

        if ((m = line.match(/^(#{1,6})\s+(.*?)\s*#*\s*$/))) {
            flush();
            out.push("<h" + m[1].length + ">" + inline(m[2], links) + "</h" + m[1].length + ">");
            i++;
            continue;
        }

        if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { flush(); out.push("<hr>"); i++; continue; }

        if (/^\s*>/.test(line)) {
            flush();
            var quote = [];
            while (i < lines.length && /^\s*>/.test(lines[i])) quote.push(lines[i++].replace(/^\s*>\s?/, ""));
            out.push("<blockquote><i>" + quote.map(function (s) { return inline(s, links); }).join(" ") + "</i></blockquote>");
            continue;
        }

        if (/\|/.test(line) && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1])) {
            flush();
            var rows = ['<table border="1" cellspacing="0" cellpadding="8"><tr>'
                + cells(line).map(function (c) { return "<th>" + inline(c, links) + "</th>"; }).join("") + "</tr>"];
            i += 2;
            while (i < lines.length && /\|/.test(lines[i]) && !/^\s*$/.test(lines[i])) {
                rows.push("<tr>" + cells(lines[i++]).map(function (c) { return "<td>" + inline(c, links) + "</td>"; }).join("") + "</tr>");
            }
            out.push(rows.join("") + "</table>");
            continue;
        }

        if (LIST.test(line)) {
            flush();
            var stack = [];
            while (i < lines.length && (m = lines[i].match(LIST))) {
                var indent = m[1].replace(/\t/g, "    ").length;
                var tag = /\d/.test(m[2]) ? "ol" : "ul";
                while (stack.length && indent < stack[stack.length - 1].indent) out.push("</li></" + stack.pop().tag + ">");
                var top = stack[stack.length - 1];
                if (!top || indent > top.indent) {
                    stack.push({ indent: indent, tag: tag });
                    out.push("<" + tag + ">");
                } else {
                    out.push("</li>");
                }
                var item = [m[3]];
                i++;
                while (i < lines.length && !/^\s*$/.test(lines[i]) && !LIST.test(lines[i]) && /^\s+/.test(lines[i])) item.push(lines[i++].trim());
                out.push("<li>" + item.map(function (s) { return inline(s, links); }).join(" "));
            }
            while (stack.length) out.push("</li></" + stack.pop().tag + ">");
            continue;
        }

        para.push(line.trim());
        i++;
    }
    flush();
    return out.join("");
}

// ---- web pages: HTML to Markdown, for the reader view
//
// fromHtml(html, url) returns { title, site, markdown, images, links }: the
// page's main content as the Markdown above (headings, lists, tables, links,
// quotes, code) with each image on a line of its own, ![alt](address). Menus,
// headers, footers, forms, ads, cookie banners and share bars are left out.

var VOID = { area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1, input: 1, link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1 };
var SKIP = { head: 1, nav: 1, footer: 1, aside: 1, form: 1, button: 1, select: 1, option: 1, input: 1, label: 1, dialog: 1,
             menu: 1, embed: 1, map: 1, picture: 0 };
var BLOCK = { address: 1, article: 1, aside: 1, blockquote: 1, dd: 1, div: 1, dl: 1, dt: 1, figcaption: 1, figure: 1,
              footer: 1, h1: 1, h2: 1, h3: 1, h4: 1, h5: 1, h6: 1, header: 1, hr: 1, li: 1, main: 1, nav: 1, ol: 1,
              p: 1, pre: 1, section: 1, table: 1, ul: 1, tr: 1, td: 1, th: 1, tbody: 1, thead: 1, caption: 1, details: 1, summary: 1 };
var JUNK = /(^|[\s_-])(cookies?|consent|gdpr|banners?|advert\w*|ads?|adslot|ad-slot|sponsored|promo\w*|newsletter|subscribe|signup|share|sharing|social|related|recommended|comments?|disqus|menu|navbar|nav|navigation|sidebar|footer|masthead|popup|modal|overlay|breadcrumbs?|skip-link|toolbar|paywall|outbrain|taboola|cmp|onetrust|didomi|editsection|reference|navbox|catlinks|printfooter|noprint)([\s_-]|$)/i;
var ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", ndash: "–", mdash: "—", hellip: "…",
                 lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", laquo: "«", raquo: "»", copy: "©", reg: "®", trade: "™",
                 deg: "°", middot: "·", bull: "•", times: "×", divide: "÷", euro: "€", pound: "£", yen: "¥", cent: "¢",
                 sect: "§", para: "¶", shy: "", zwj: "", zwnj: "", thinsp: " ", ensp: " ", emsp: " ", minus: "−",
                 frac12: "½", frac14: "¼", frac34: "¾", eacute: "é", egrave: "è", agrave: "à", ccedil: "ç", uuml: "ü",
                 ouml: "ö", auml: "ä", szlig: "ß", rarr: "→", larr: "←", hArr: "⇔", rArr: "⇒" };

function decode(t) {
    return t.replace(/&(#x[0-9a-f]+|#\d+|[a-z][a-z0-9]*);?/gi, function (m, e) {
        if (e[0] === "#") {
            var n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
            return n > 0 && n < 0x110000 ? String.fromCodePoint(n) : "";
        }
        return ENTITIES.hasOwnProperty(e) ? ENTITIES[e] : ENTITIES.hasOwnProperty(e.toLowerCase()) ? ENTITIES[e.toLowerCase()] : m;
    });
}

function attrsOf(s) {
    var a = {}, m, re = /([^\s"'=\/<>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g;
    while ((m = re.exec(s))) a[m[1].toLowerCase()] = decode(m[2] !== undefined ? m[2] : m[3] !== undefined ? m[3] : m[4] || "");
    return a;
}

// a forgiving tree: { tag, a (attributes), kids, up } and { text }
function parse(html) {
    html = html.replace(/<!--[\s\S]*?-->/g, " ")
        .replace(/<(script|style|noscript|template|svg|math|textarea|iframe|object|canvas|video|audio)\b[\s\S]*?<\/\1\s*>/gi, " ");
    var root = { tag: "#root", a: {}, kids: [], up: null }, cur = root, m;
    // a quoted attribute value can hold ">"
    var re = /<(\/?)([a-zA-Z][\w:-]*)((?:=\s*"[^"]*"|=\s*'[^']*'|[^>])*)>|([^<]+)|</g;
    function close(names, stop) {
        for (var n = cur; n && n !== root; n = n.up) {
            if (stop && stop[n.tag]) return;
            if (names[n.tag]) { cur = n.up; return; }
        }
    }
    while ((m = re.exec(html))) {
        if (m[4] !== undefined || m[0] === "<") {
            cur.kids.push({ text: m[4] !== undefined ? m[4] : "<" });
            continue;
        }
        var tag = m[2].toLowerCase();
        if (m[1]) {
            for (var n = cur; n && n !== root; n = n.up)
                if (n.tag === tag) { cur = n.up; break; }
            continue;
        }
        if (tag === "li") close({ li: 1 }, { ul: 1, ol: 1 });
        else if (tag === "tr") close({ tr: 1 }, { table: 1 });
        else if (tag === "td" || tag === "th") close({ td: 1, th: 1 }, { tr: 1, table: 1 });
        else if (tag === "dt" || tag === "dd") close({ dt: 1, dd: 1 }, { dl: 1 });
        else if (tag === "option") close({ option: 1 }, { select: 1 });
        if (BLOCK[tag] && tag !== "li" && tag !== "td" && tag !== "th") close({ p: 1 }, { div: 1, li: 1, td: 1, th: 1, blockquote: 1, section: 1, article: 1 });
        var el = { tag: tag, a: attrsOf(m[3]), kids: [], up: cur };
        cur.kids.push(el);
        if (!VOID[tag] && !/\/\s*$/.test(m[3])) cur = el;
    }
    return root;
}

function walk(n, f) {
    if (!n.kids) return;
    for (var i = 0; i < n.kids.length; i++) {
        var k = n.kids[i];
        if (f(k) !== false) walk(k, f);
    }
}

function textLen(n) {
    if (n.text !== undefined) return n.text.replace(/\s+/g, " ").length;
    if (n.len === undefined) {
        n.len = 0;
        for (var i = 0; i < n.kids.length; i++) n.len += textLen(n.kids[i]);
    }
    return n.len;
}

function has(n, tags) {
    var found = false;
    walk(n, function (k) { if (tags[k.tag]) found = true; return !found; });
    return found;
}

function hidden(n) {
    var a = n.a, style = (a.style || "").replace(/\s/g, "").toLowerCase();
    return a.hidden !== undefined || a["aria-hidden"] === "true" || /display:none|visibility:hidden/.test(style)
        || /^(navigation|banner|contentinfo|complementary|dialog|alertdialog|search|menu|menubar)$/.test(a.role || "");
}

// drops what is not the page's content
function prune(n) {
    n.kids = n.kids.filter(function (k) {
        if (k.text !== undefined) return true;
        if (SKIP[k.tag] || hidden(k)) return false;
        var names = (k.a["class"] || "") + " " + (k.a.id || "");
        if (JUNK.test(names) && k.tag !== "body" && k.tag !== "html" && !has(k, { h1: 1, article: 1, main: 1 })) return false;
        prune(k);
        return true;
    });
}

// the element with the article: an <article> or <main>, else the one whose
// paragraphs hold the most text
function mainOf(root) {
    var best = null, top = 0;
    walk(root, function (n) {
        if (n.tag === "article" && textLen(n) > top) { best = n; top = textLen(n); }
    });
    if (best && top >= 400) return best;
    best = null;
    walk(root, function (n) {
        if (!best && (n.tag === "main" || (n.a && n.a.role === "main")) && textLen(n) >= 400) best = n;
    });
    if (best) return best;
    var score = [];
    walk(root, function (n) {
        if (n.tag !== "p" && n.tag !== "pre" && n.tag !== "li") return;
        var l = textLen(n);
        if (l < 40) return false;
        for (var up = n.up, w = 1; up && w > 0.2; up = up.up, w /= 2) {
            up.score = (up.score || 0) + l * w;
            if (score.indexOf(up) < 0) score.push(up);
        }
        return false;
    });
    top = 0;
    for (var i = 0; i < score.length; i++) if (score[i].score > top && score[i].tag !== "#root") { top = score[i].score; best = score[i]; }
    if (best && top >= 300) return best;
    var body = null;
    walk(root, function (n) { if (!body && n.tag === "body") body = n; });
    return body || root;
}

// the address `href` on the page at `base`, absolute
function resolve(href, base) {
    href = String(href || "").trim();
    if (!href || /^(javascript|mailto|tel|data|about|blob):/i.test(href)) return "";
    if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return /^https?:/i.test(href) ? href : "";
    var m = String(base || "").match(/^([a-z][a-z0-9+.-]*:)\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?/i);
    if (!m) return "";
    if (href.indexOf("//") === 0) return m[1] + href;
    if (href[0] === "#") return m[1] + "//" + m[2] + m[3] + (m[4] || "") + href;
    if (href[0] === "?") return m[1] + "//" + m[2] + m[3] + href;
    var path = href[0] === "/" ? href : m[3].replace(/[^\/]*$/, "") + href;
    var tail = path.match(/[?#].*$/);
    var parts = path.replace(/[?#].*$/, "").split("/"), out = [];
    for (var i = 0; i < parts.length; i++) {
        if (parts[i] === "..") { if (out.length > 1) out.pop(); }
        else if (parts[i] !== "." || i === parts.length - 1) out.push(parts[i] === "." ? "" : parts[i]);
    }
    return m[1] + "//" + m[2] + (out.join("/") || "/") + (tail ? tail[0] : "");
}

// an address as Markdown takes it: no spaces, no ( ) " < >
function safeUrl(u) {
    return u.replace(/[\s()"<>]/g, function (c) { return "%" + c.charCodeAt(0).toString(16).toUpperCase(); });
}

function escText(t) {
    return t.replace(/([\\`*_\[\]|~])/g, "\\$1");
}

// the address of an <img>: lazy loaders keep it in data-src or a srcset
function imageSrc(a, base) {
    var src = a["data-src"] || a["data-original"] || a["data-lazy-src"] || a.src || "";
    var set = a["data-srcset"] || a.srcset || "";
    if ((!src || /^data:/.test(src)) && set) {
        // the widest candidate up to ~1000 px, else the first
        var best = "", bw = 0;
        set.split(/,\s+/).forEach(function (c) {
            var p = c.trim().split(/\s+/), w = parseInt(p[1]) || 1;
            if (!best || (w <= 1100 && w > bw)) { best = p[0]; bw = w; }
        });
        src = best;
    }
    return resolve(src, base);
}

function fromHtml(html, url) {
    html = String(html || "");
    var head = (html.match(/<head[\s\S]*?<\/head>/i) || [""])[0];
    function meta(name) {
        var re = new RegExp("<meta[^>]+(?:property|name)\\s*=\\s*[\"']" + name + "[\"'][^>]*>", "i");
        var tag = head.match(re);
        return tag ? decode((attrsOf(tag[0]).content || "")).trim() : "";
    }
    var title = meta("og:title") || decode(((head.match(/<title[^>]*>([\s\S]*?)<\/title>/i) || [])[1] || "")).replace(/\s+/g, " ").trim();
    var host = (String(url).match(/^[a-z]+:\/\/(?:www\.)?([^\/?#:]+)/i) || [])[1] || "";
    var site = meta("og:site_name") || host;
    var baseTag = head.match(/<base[^>]+href\s*=\s*["']([^"']+)["']/i);
    var base = baseTag ? resolve(baseTag[1], url) || url : url;

    var root = parse(html);
    prune(root);
    var main = mainOf(root);
    var images = [], links = [], seenImg = {};

    function inl(n, pre) {
        if (n.text !== undefined) return pre ? decode(n.text) : escText(decode(n.text).replace(/\s+/g, " "));
        var t = "";
        for (var i = 0; i < n.kids.length; i++) t += inl(n.kids[i], pre);
        switch (n.tag) {
        case "br": return pre ? "\n" : " ";
        case "img": return "";
        case "a": {
            var href = resolve(n.a.href, base);
            var s = t.replace(/\s+/g, " ").trim();
            if (!href || !s || pre) return t;
            links.push({ text: s.replace(/\\(.)/g, "$1"), href: href });
            return "[" + s.replace(/[\[\]]/g, "") + "](" + safeUrl(href) + ")";
        }
        case "strong": case "b": return t.trim() ? " **" + t.trim() + "** " : t;
        case "em": case "i": case "cite": return t.trim() ? " *" + t.trim() + "* " : t;
        case "code": case "kbd": case "samp": case "tt": return pre || !t.trim() ? t : "`" + t.replace(/`/g, "").replace(/\\(.)/g, "$1") + "`";
        case "sup": return t.trim() ? "^" + t.trim() : "";
        default: return t;
        }
    }

    function clean(t) {
        return t.replace(/[ \t\u00a0]+/g, " ").replace(/\*\* +\*\*/g, " ").replace(/ +([,.;:!?)])/g, "$1").trim();
    }

    var out = [];
    function para(t) {
        t = clean(t);
        if (!t) return;
        // text that would read as a heading, a quote or a list
        if (/^\d+[.)]\s/.test(t)) t = t.replace(/^(\d+)/, "$1\\");
        else if (/^(#|>|[-+]\s)/.test(t)) t = "\\" + t;
        out.push(t);
    }
    function image(n) {
        var src = imageSrc(n.a, base);
        var w = parseInt(n.a.width) || 0, h = parseInt(n.a.height) || 0;
        if (!src || seenImg[src] || /\.svg(\?|$)/i.test(src) || (w && w < 48) || (h && h < 48)) return;
        seenImg[src] = true;
        var alt = clean((n.a.alt || "").replace(/[\[\]]/g, ""));
        images.push({ src: src, alt: alt });
        out.push("![" + alt + "](" + safeUrl(src) + ")");
    }
    function imagesIn(n) {
        walk(n, function (k) { if (k.tag === "img") image(k); });
    }
    function listOf(n, depth) {
        var k = 0;
        n.kids.forEach(function (li) {
            if (li.tag !== "li") return;
            k++;
            var own = { tag: "span", a: {}, kids: li.kids.filter(function (c) { return c.tag !== "ul" && c.tag !== "ol"; }) };
            var t = clean(inl(own));
            if (t) out.push(new Array(depth + 1).join("  ") + (n.tag === "ol" ? k + ". " : "- ") + t);
            li.kids.forEach(function (c) { if (c.tag === "ul" || c.tag === "ol") listOf(c, depth + 1); });
        });
    }
    function tableOf(n) {
        var rows = [];
        walk(n, function (k) {
            if (k.tag === "table" && k !== n) return false;
            if (k.tag !== "tr") return;
            var row = [];
            k.kids.forEach(function (c) {
                if (c.tag === "td" || c.tag === "th") row.push(clean(inl(c)).replace(/\|/g, "\\|") || " ");
            });
            if (row.length) rows.push(row);
            return false;
        });
        var cols = 0;
        rows.forEach(function (r) { cols = Math.max(cols, r.length); });
        // layout tables: their cells as paragraphs
        if (cols < 2 || rows.length < 2 || has(n, { table: 1, p: 1, div: 1 }) && textLen(n) > 1500) {
            blocks(n);
            return;
        }
        // the pictures in its cells (an infobox's portrait): above it, two at most
        var pics = 0;
        walk(n, function (k) {
            if (k.tag !== "img" || pics >= 2) return;
            var had = images.length;
            image(k);
            if (images.length > had) pics++;
        });
        rows.forEach(function (r, i) {
            while (r.length < cols) r.push(" ");
            out.push("| " + r.join(" | ") + " |");
            if (i === 0) out.push("|" + new Array(cols + 1).join(" --- |"));
        });
        out.push("");
    }
    function blocks(n) {
        var run = "";
        function flush() {
            para(run);
            run = "";
        }
        for (var i = 0; i < n.kids.length; i++) {
            var k = n.kids[i];
            if (k.text !== undefined || !BLOCK[k.tag] && k.tag !== "img" && k.tag !== "br" && !has(k, BLOCK) && !has(k, { img: 1 })) {
                run += inl(k);
                continue;
            }
            if (k.tag === "br") { run += " "; continue; }
            flush();
            var m = k.tag.match(/^h([1-6])$/);
            if (m) {
                var h = clean(inl(k));
                if (h && !(out.length === 0 && h.replace(/\\(.)/g, "$1") === title)) out.push(new Array(+m[1] + 1).join("#") + " " + h);
                imagesIn(k);
            } else if (k.tag === "img") {
                image(k);
            } else if (k.tag === "p") {
                para(inl(k));
                imagesIn(k);
            } else if (k.tag === "ul" || k.tag === "ol") {
                listOf(k, 0);
                out.push("");
            } else if (k.tag === "pre") {
                var code = inl(k, true).replace(/^\n+|\s+$/g, "");
                if (code) out.push("```\n" + code.replace(/```/g, "'''") + "\n```");
            } else if (k.tag === "blockquote") {
                var q = clean(inl(k));
                if (q) out.push("> " + q);
            } else if (k.tag === "table") {
                tableOf(k);
            } else if (k.tag === "hr") {
                out.push("---");
            } else if (k.tag === "figcaption" || k.tag === "caption") {
                var c = clean(inl(k));
                if (c) out.push("*" + c.replace(/\*/g, "") + "*");
            } else if (k.tag === "dt") {
                var d = clean(inl(k));
                if (d) out.push("**" + d.replace(/\*/g, "") + "**");
            } else {
                blocks(k);
            }
        }
        flush();
    }
    blocks(main);

    var md = [], blank = true;
    for (var i = 0; i < out.length; i++) {
        var line = out[i];
        var listy = /^\s*(- |\d+\. |\| )/.test(line), prev = i > 0 && /^\s*(- |\d+\. |\| )/.test(out[i - 1]);
        if (line === "") { if (!blank) md.push(""); blank = true; continue; }
        if (!blank && !(listy && prev && (line[0] === "|") === (out[i - 1][0] === "|"))) md.push("");
        md.push(line);
        blank = false;
    }
    return { title: title || host, site: site, markdown: md.join("\n").trim(), images: images, links: links };
}

// Splits Markdown at blank lines into parts of about `size` characters, never
// inside a code block or a table, and with at most `pics` images in a part.
function split(md, size, pics) {
    var blocks = [], cur = [], fence = false;
    md.split("\n").forEach(function (line) {
        if (/^\s*```/.test(line)) fence = !fence;
        if (!fence && line === "" && cur.length) {
            blocks.push(cur.join("\n"));
            cur = [];
        } else {
            cur.push(line);
        }
    });
    if (cur.length) blocks.push(cur.join("\n"));
    var parts = [], part = [], len = 0, n = 0;
    blocks.forEach(function (b) {
        var img = /^!\[[^\]]*\]\([^)]*\)$/.test(b) ? 1 : 0;
        if (part.length && (len + b.length > size || n + img > pics)) {
            parts.push(part.join("\n\n"));
            part = [];
            len = n = 0;
        }
        part.push(b);
        len += b.length + 2;
        n += img;
    });
    if (part.length) parts.push(part.join("\n\n"));
    return parts;
}

// The shown part of a page: runs of Markdown text and images, in order:
// [{ md }] and [{ img, alt }]
function pieces(md) {
    var out = [], run = [];
    md.split("\n").forEach(function (line) {
        var m = line.match(/^!\[([^\]]*)\]\(([^)\s]+)\)$/);
        if (m) {
            if (run.join("").trim()) out.push({ md: run.join("\n"), img: "", alt: "" });
            run = [];
            out.push({ md: "", img: m[2], alt: m[1] });
        } else {
            run.push(line);
        }
    });
    if (run.join("").trim()) out.push({ md: run.join("\n"), img: "", alt: "" });
    return out;
}

// Markdown without its images and link addresses, for the assistant to read
function plain(md) {
    return md.replace(/^!\[([^\]]*)\]\([^)]*\)$/gm, function (m, alt) { return alt ? "[image: " + alt + "]" : "[image]"; });
}

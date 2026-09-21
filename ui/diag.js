.pragma library

// Folio's own lines from xochitl's journal, sent by the backend (message
// 102): errors in its files, versions that failed to load, xochitl crashes.
// A module, not a property: a QML var array reads back as a copy.

var lines = [];
var KEEP = 30;

// "2026-09-20T21:28:52+0000 host xochitl[4702]: 21:28:52.039 default   file:///…/code/v15/markdown.js:263: TypeError: … (file:///…)"
// becomes { t: ms, text: "code/v15/markdown.js:263: TypeError: …" }
function parse(raw) {
    var m = String(raw).match(/^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)([+-]\d\d:?\d\d|Z)?\s+\S+\s+[^:]+:\s(.*)$/);
    if (!m) return { t: Date.now(), text: String(raw).slice(0, 300) };
    var zone = !m[2] || m[2] === "Z" ? "Z" : m[2].slice(0, 3) + ":" + m[2].slice(-2);
    var text = m[3].replace(/^\d\d:\d\d:\d\d\.\d+\s+\S+\s+/, "")
        .replace(/\s*\([^()]*(?:file|qrc):[^()]*\)\s*$/, "")
        .replace(/file:\/\/\/home\/root\/\.local\/share\/claude-app\//g, "")
        .replace(/qrc:\/[A-Z]+\/ui\//g, "built-in ")
        .trim();
    return { t: Date.parse(m[1] + zone) || Date.now(), text: text.slice(0, 300) };
}

function add(raw) {
    var l = parse(raw);
    for (var i = 0; i < lines.length; i++)
        if (lines[i].t === l.t && lines[i].text === l.text) return false;
    lines.push(l);
    lines.sort(function (a, b) { return a.t - b.t; });
    if (lines.length > KEEP) lines.splice(0, lines.length - KEEP);
    return true;
}

// the newest n lines at most `ageMs` old, oldest first
function recent(n, ageMs, now) {
    var since = (now || Date.now()) - ageMs;
    return lines.filter(function (l) { return l.t >= since; }).slice(-n);
}

function clear() {
    lines = [];
}

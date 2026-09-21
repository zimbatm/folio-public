// The user layer of the page: ink in page coordinates. It lives in plain JS: a
// QML `property var` array reads back as a copy, so push() on it is lost.
//
// A stroke is { p: [{x, y}], x0, y0, x1, y1, turn, w }. turn is the index of
// the request that sent it to the assistant, or -1 while it is new (not sent yet). w
// is the typeset word it was converted to (an index into the app's `typed`),
// or -1: handwriting the assistant read shows as type, its ink kept underneath.
var strokes = [];
var current = null;
var ROW = 128;
var rows = {};      // tile row -> strokes that touch it
var history = [];   // undo: { add: stroke } or { erased: [strokes] }

function grow(s, pt) {
    s.x0 = Math.min(s.x0, pt.x); s.y0 = Math.min(s.y0, pt.y);
    s.x1 = Math.max(s.x1, pt.x); s.y1 = Math.max(s.y1, pt.y);
}

function index(s) {
    for (var r = Math.floor((s.y0 - 4) / ROW); r <= Math.floor((s.y1 + 4) / ROW); r++) {
        if (!rows[r]) rows[r] = [];
        if (rows[r].indexOf(s) < 0) rows[r].push(s);
    }
}

function reindex() {
    rows = {};
    for (var i = 0; i < strokes.length; i++) index(strokes[i]);
}

function inRow(r) {
    return rows[r] || [];
}

function begin(x, y) {
    current = { p: [{ x: x, y: y }], x0: x, y0: y, x1: x, y1: y, turn: -1, w: -1 };
    strokes.push(current);
    index(current);
}

// the new segment [a, b], or null when the pen barely moved
function add(x, y) {
    if (!current) return null;
    var a = current.p[current.p.length - 1];
    if (Math.abs(x - a.x) + Math.abs(y - a.y) < 1.5) return null;
    var b = { x: x, y: y };
    current.p.push(b);
    grow(current, b);
    index(current);
    return [a, b];
}

// the finished stroke, or null
function end() {
    var s = current;
    current = null;
    if (s) history.push({ add: s });
    return s;
}

function remove(s) {
    var i = strokes.indexOf(s);
    if (i >= 0) strokes.splice(i, 1);
    for (var r in rows) {
        var j = rows[r].indexOf(s);
        if (j >= 0) rows[r].splice(j, 1);
    }
}

function near(s, x, y, d) {
    if (x < s.x0 - d || x > s.x1 + d || y < s.y0 - d || y > s.y1 + d) return false;
    var p = s.p;
    if (p.length === 1) return Math.abs(p[0].x - x) + Math.abs(p[0].y - y) <= d * 1.4;
    for (var i = 1; i < p.length; i++) {
        var ax = p[i - 1].x, ay = p[i - 1].y, bx = p[i].x - ax, by = p[i].y - ay;
        var l = bx * bx + by * by;
        var t = l ? Math.max(0, Math.min(1, ((x - ax) * bx + (y - ay) * by) / l)) : 0;
        var dx = ax + t * bx - x, dy = ay + t * by - y;
        if (dx * dx + dy * dy <= d * d) return true;
    }
    return false;
}

// the distance from (x, y) to the stroke's line
function dist(s, x, y) {
    var p = s.p, best = Math.hypot(p[0].x - x, p[0].y - y);
    for (var i = 1; i < p.length; i++) {
        var ax = p[i - 1].x, ay = p[i - 1].y, bx = p[i].x - ax, by = p[i].y - ay;
        var l = bx * bx + by * by;
        var t = l ? Math.max(0, Math.min(1, ((x - ax) * bx + (y - ay) * by) / l)) : 0;
        best = Math.min(best, Math.hypot(ax + t * bx - x, ay + t * by - y));
    }
    return best;
}

// removes the strokes under the eraser, except those skip(s) keeps; returns
// their union box, or null
function erase(x, y, d, skip) {
    var hit = inRow(Math.floor(y / ROW)).filter(function (s) {
        return s !== current && !(skip && skip(s)) && near(s, x, y, d);
    });
    return eraseList(hit);
}

// removes these strokes as part of the current eraser stroke
// the strokes the last erase removed, for what changed since the last ask
var lastErased = [];

function eraseList(hit) {
    lastErased = hit;
    if (!hit.length) return null;
    for (var i = 0; i < hit.length; i++) remove(hit[i]);
    var last = history[history.length - 1];
    if (last && last.erasing) last.erased = last.erased.concat(hit);
    else history.push({ erased: hit, erasing: true });
    return box(hit);
}

// one eraser stroke is one undo step
function endErase() {
    var last = history[history.length - 1];
    if (last) delete last.erasing;
}

// undoes the last stroke or eraser stroke; returns the box to repaint, or null
function undo() {
    var h = history.pop();
    if (!h) return null;
    if (h.add) {
        remove(h.add);
        return box([h.add]);
    }
    for (var i = 0; i < h.erased.length; i++) {
        strokes.push(h.erased[i]);
        index(h.erased[i]);
    }
    return box(h.erased);
}

// forgets a stroke that was a gesture (the send mark), not writing
function drop(s) {
    remove(s);
    var last = history[history.length - 1];
    if (last && last.add === s) history.pop();
}

function clear() {
    strokes = [];
    rows = {};
    history = [];
    current = null;
    loop = null;
    lasso = null;
}

function pending() {
    return strokes.filter(function (s) { return s.turn < 0; });
}

function box(list) {
    if (!list.length) return null;
    var b = { x0: 1e9, y0: 1e9, x1: -1e9, y1: -1e9 };
    for (var i = 0; i < list.length; i++) {
        var s = list[i];
        b.x0 = Math.min(b.x0, s.x0); b.y0 = Math.min(b.y0, s.y0);
        b.x1 = Math.max(b.x1, s.x1); b.y1 = Math.max(b.y1, s.y1);
    }
    return b;
}

function bottom() {
    var b = box(strokes);
    return b ? b.y1 : 0;
}

// Groups strokes into regions: strokes of the same turn whose boxes come
// within `gap` px of each other. Each region is { x0, y0, x1, y1, turn, last }
// where `last` is the order of its newest stroke. Sorted top to bottom.
function regions(list, gap) {
    var out = [];
    var order = new Map();
    for (var k = 0; k < strokes.length; k++) order.set(strokes[k], k);
    for (var i = 0; i < list.length; i++) {
        var s = list[i];
        var r = { x0: s.x0, y0: s.y0, x1: s.x1, y1: s.y1, turn: s.turn, last: order.has(s) ? order.get(s) : -1 };
        for (var j = out.length - 1; j >= 0; j--) {
            var o = out[j];
            if (o.turn === r.turn && r.x0 - gap < o.x1 && o.x0 - gap < r.x1 && r.y0 - gap < o.y1 && o.y0 - gap < r.y1) {
                r = { x0: Math.min(r.x0, o.x0), y0: Math.min(r.y0, o.y0), x1: Math.max(r.x1, o.x1), y1: Math.max(r.y1, o.y1),
                      turn: r.turn, last: Math.max(r.last, o.last) };
                out.splice(j, 1);
                j = out.length;
            }
        }
        out.push(r);
    }
    return out.sort(function (a, b) { return a.y0 - b.y0; });
}

// Splits strokes into pieces for the assistant to label as text or drawing: strokes
// that come within `gap` px of each other, by their lines, not their boxes (a
// circle around words is a piece of its own). A dot or an accent that touches
// nothing joins the nearest piece within 40 px. Returns
// [{ strokes, x0, y0, x1, y1 }] in reading order: lines top to bottom, then
// left to right.
function pieces(list, gap) {
    var n = list.length, up = [], i, j;
    for (i = 0; i < n; i++) up.push(i);
    function find(k) {
        while (up[k] !== k) { up[k] = up[up[k]]; k = up[k]; }
        return k;
    }
    function join(a, b) { up[find(a)] = find(b); }
    function touch(a, b) {
        if (a.x0 - gap > b.x1 || b.x0 - gap > a.x1 || a.y0 - gap > b.y1 || b.y0 - gap > a.y1) return false;
        var k;
        for (k = 0; k < a.p.length; k++) if (near(b, a.p[k].x, a.p[k].y, gap)) return true;
        for (k = 0; k < b.p.length; k++) if (near(a, b.p[k].x, b.p[k].y, gap)) return true;
        return false;
    }
    function small(s) { return s.x1 - s.x0 < 16 && s.y1 - s.y0 < 16; }
    for (i = 0; i < n; i++)
        for (j = i + 1; j < n; j++)
            if (find(i) !== find(j) && touch(list[i], list[j])) join(i, j);
    var big = {};
    for (i = 0; i < n; i++) if (!small(list[i])) big[find(i)] = true;
    for (i = 0; i < n; i++) {
        if (big[find(i)]) continue;
        var best = -1, bd = 40, a = list[i];
        for (j = 0; j < n; j++) {
            var b = list[j];
            if (small(b)) continue;
            var d = dist(b, (a.x0 + a.x1) / 2, (a.y0 + a.y1) / 2);
            if (d <= bd) { bd = d; best = j; }
        }
        if (best >= 0) join(i, best);
    }
    var groups = {}, out = [];
    for (i = 0; i < n; i++) {
        var r = find(i);
        if (!groups[r]) { groups[r] = { strokes: [] }; out.push(groups[r]); }
        groups[r].strokes.push(list[i]);
    }
    for (i = 0; i < out.length; i++) {
        var bx = box(out[i].strokes);
        out[i].x0 = bx.x0; out[i].y0 = bx.y0; out[i].x1 = bx.x1; out[i].y1 = bx.y1;
    }
    return readingOrder(out);
}

// Groups boxes { x0, y0, x1, y1 } into lines of writing. First the lines,
// then the order in each: sorting by the middle of each box mixes up the
// words of a line (a short word sits lower than a tall one, and a line slopes).
// The boxes of usual height are taken left to right, and each joins the line
// one of whose 2 nearest boxes its height overlaps most, by at least half of
// the smaller of the two: a line that slopes up or down stays one line, and a
// descender does not reach into the next one. Then the others: a small mark (a comma, a dot) goes with the line
// nearest to its middle, and a box much taller than the rest (strokes that
// touch across two lines) with the line of its top. Returns the lines top to
// bottom, each [boxes] left to right.
function lines(list) {
    if (!list.length) return [];
    function mid(v) {
        v = v.slice().sort(function (a, b) { return a - b; });
        var k = v.length >> 1;
        return v.length % 2 ? v[k] : (v[k - 1] + v[k]) / 2;
    }
    function height(b) { return Math.max(1, b.y1 - b.y0); }
    var H = mid(list.map(height)), few = list.length < 3;
    function kind(b) { return few ? 0 : height(b) > 2.2 * H ? 1 : height(b) < 0.5 * H ? -1 : 0; }
    function byX(a, b) { return a.x0 - b.x0; }
    var out = [];
    // the 2 boxes of usual height of line l nearest to x, as spans (the top
    // of a tall one)
    function closest(l, x) {
        return l.usual.slice().sort(function (a, b) {
            return Math.abs((a.x0 + a.x1) / 2 - x) - Math.abs((b.x0 + b.x1) / 2 - x);
        }).slice(0, 2).map(function (b) { return { y0: b.y0, y1: kind(b) > 0 ? b.y0 + H : b.y1 }; });
    }
    function add(l, p) {
        if (!l) {
            l = { list: [], usual: [] };
            out.push(l);
        }
        l.list.push(p);
        if (!kind(p) || !l.usual.length) l.usual.push(p);
    }
    function join(p, y0, y1) {
        var best = null, most = 0, x = (p.x0 + p.x1) / 2;
        for (var j = 0; j < out.length; j++) {
            closest(out[j], x).forEach(function (r) {
                var o = (Math.min(y1, r.y1) - Math.max(y0, r.y0)) / Math.max(1, Math.min(y1 - y0, r.y1 - r.y0));
                if (o >= 0.5 && o > most) { most = o; best = out[j]; }
            });
        }
        add(best, p);
    }
    function nearest(p) {
        var best = null, least = 0.75 * H, x = (p.x0 + p.x1) / 2, c = (p.y0 + p.y1) / 2;
        for (var j = 0; j < out.length; j++) {
            closest(out[j], x).forEach(function (r) {
                var d = c < r.y0 ? r.y0 - c : c > r.y1 ? c - r.y1 : 0;
                if (d <= least) { least = d; best = out[j]; }
            });
        }
        add(best, p);
    }
    var todo = list.slice().sort(byX), i;
    for (i = 0; i < todo.length; i++) if (!kind(todo[i])) join(todo[i], todo[i].y0, todo[i].y1);
    for (i = 0; i < todo.length; i++) if (kind(todo[i]) > 0) join(todo[i], todo[i].y0, todo[i].y0 + H);
    for (i = 0; i < todo.length; i++) if (kind(todo[i]) < 0) nearest(todo[i]);
    out.forEach(function (l) { l.m = mid(l.usual.map(function (b) { return kind(b) > 0 ? 2 * b.y0 + H : b.y0 + b.y1; })); });
    out.sort(function (a, b) { return a.m - b.m; });
    return out.map(function (l) { return l.list.sort(byX); });
}

// the boxes in reading order: lines top to bottom, then left to right
function readingOrder(list) {
    var ls = lines(list), out = [];
    for (var i = 0; i < ls.length; i++) out = out.concat(ls[i]);
    return out;
}

// The rewrite pad, where the user writes a typeset word again to correct it:
// its own strokes, in pad px.
var fix = [];
var fixing = null;

function fixBegin(x, y) {
    fixing = { p: [{ x: x, y: y }], x0: x, y0: y, x1: x, y1: y, turn: -1, w: -1 };
    fix.push(fixing);
}

function fixAdd(x, y) {
    if (!fixing) return null;
    var a = fixing.p[fixing.p.length - 1];
    if (Math.abs(x - a.x) + Math.abs(y - a.y) < 1.5) return null;
    var b = { x: x, y: y };
    fixing.p.push(b);
    grow(fixing, b);
    return [a, b];
}

function fixEnd() { fixing = null; }
function fixClear() { fix = []; fixing = null; }

// A check mark (✓): a short stroke down to the right, then a longer one up to
// the right. The app's send mark.
function isCheck(s) {
    var p = s.p;
    var w = s.x1 - s.x0, h = s.y1 - s.y0;
    if (p.length < 4 || w < 24 || h < 20 || w > 220 || h > 220) return false;
    var lo = 0;
    for (var i = 1; i < p.length; i++) if (p[i].y > p[lo].y) lo = i;
    var a = p[0], m = p[lo], b = p[p.length - 1];
    var first = Math.hypot(m.x - a.x, m.y - a.y), second = Math.hypot(b.x - m.x, b.y - m.y);
    return lo > 0 && lo < p.length - 1
        && m.x > a.x && m.y - a.y > 8
        && b.x - m.x > 10 && m.y - b.y > h * 0.8
        && second > first * 1.5
        && b.y < a.y;
}

function save() {
    return strokes.map(function (s) {
        var flat = [];
        for (var i = 0; i < s.p.length; i++) flat.push(Math.round(s.p[i].x), Math.round(s.p[i].y));
        var o = { t: s.turn, p: flat };
        if (s.w >= 0) o.w = s.w;
        if (s.d) o.d = s.d;
        return o;
    });
}

function load(saved) {
    clear();
    for (var i = 0; i < saved.length; i++) {
        var f = saved[i].p;
        if (!f || f.length < 2) continue;
        var s = { p: [], x0: f[0], y0: f[1], x1: f[0], y1: f[1], turn: saved[i].t,
                  w: saved[i].w >= 0 ? saved[i].w : -1, d: saved[i].d || "" };
        for (var k = 0; k + 1 < f.length; k += 2) {
            var pt = { x: f[k], y: f[k + 1] };
            s.p.push(pt);
            grow(s, pt);
        }
        strokes.push(s);
    }
    reindex();
}

// Rectangles { x, y, w, h } for layout.
function hits(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

// moves r down, below whatever it hits in `taken`, until it is free
function slide(r, taken, gap) {
    for (var n = 0; n < 1000; n++) {
        var down = -1;
        for (var i = 0; i < taken.length; i++)
            if (hits(r, taken[i])) down = Math.max(down, taken[i].y + taken[i].h + gap);
        if (down < 0) return r;
        r = { x: r.x, y: down, w: r.w, h: r.h };
    }
    return r;
}

// The lasso: a loop the user draws round part of the page to ask about it,
// shown dashed. { id, p: [{x, y}], dash: [[a, b]] (the dashes), len (the
// path so far), x0, y0, x1, y1 }. `loop` is the one being drawn, `lasso`
// the one the next question is about.
var loop = null;
var lasso = null;
var loops = 0;
var DASH = 14, GAP = 10;

// the dashes of the segment a–b, whose start is `from` px along the path
function dashes(a, b, from) {
    var out = [], len = Math.hypot(b.x - a.x, b.y - a.y), per = DASH + GAP, t = 0;
    function at(u) { return { x: a.x + (b.x - a.x) * u / len, y: a.y + (b.y - a.y) * u / len }; }
    while (t < len) {
        var ph = (from + t) % per;
        if (ph < DASH) {
            var e = Math.min(len, t + DASH - ph);
            out.push([at(t), at(e)]);
            t = e;
        } else {
            t = Math.min(len, t + per - ph);
        }
    }
    return out;
}

function loopBegin(x, y) {
    loop = { id: 0, p: [{ x: x, y: y }], dash: [], len: 0, x0: x, y0: y, x1: x, y1: y };
}

// the new dashes, to draw now
function loopAdd(x, y) {
    if (!loop) return [];
    var a = loop.p[loop.p.length - 1];
    if (Math.abs(x - a.x) + Math.abs(y - a.y) < 3) return [];
    var b = { x: x, y: y }, d = dashes(a, b, loop.len);
    loop.p.push(b);
    grow(loop, b);
    loop.len += Math.hypot(b.x - a.x, b.y - a.y);
    for (var i = 0; i < d.length; i++) loop.dash.push(d[i]);
    return d;
}

// the loop, closed, or null when it was too small to hold anything (a tap)
function loopEnd() {
    var l = loop;
    loop = null;
    if (!l || l.p.length < 4 || (l.x1 - l.x0 < 40 && l.y1 - l.y0 < 40)) return null;
    var d = dashes(l.p[l.p.length - 1], l.p[0], l.len);
    for (var i = 0; i < d.length; i++) l.dash.push(d[i]);
    l.id = ++loops;
    return l;
}

// a closed loop through the points [x, y, x, y…] (a saved lasso), keeping
// its id when it has one
function makeLoop(flat, id) {
    if (!flat || flat.length < 8) return null;
    loopBegin(flat[0], flat[1]);
    for (var k = 2; k + 1 < flat.length; k += 2) loopAdd(flat[k], flat[k + 1]);
    var l = loopEnd();
    if (l && id > 0) {
        l.id = id;
        loops = Math.max(loops, id);
    }
    return l;
}

function setLasso(l) {
    lasso = l || null;
}

function flatLoop(l) {
    var flat = [];
    for (var i = 0; i < l.p.length; i++) flat.push(Math.round(l.p[i].x), Math.round(l.p[i].y));
    return flat;
}

// is (x, y) inside the loop l?
function inside(l, x, y) {
    if (x < l.x0 || x > l.x1 || y < l.y0 || y > l.y1) return false;
    var p = l.p, n = p.length, yes = false;
    for (var i = 0, j = n - 1; i < n; j = i++) {
        if ((p[i].y > y) !== (p[j].y > y) && x < (p[j].x - p[i].x) * (y - p[i].y) / (p[j].y - p[i].y) + p[i].x) yes = !yes;
    }
    return yes;
}

// What the assistant saw in a region of ink that is no text (a drawing, a
// mark): kept on its strokes, so it reads each piece once
function describe(r, text) {
    for (var i = 0; i < strokes.length; i++) {
        var s = strokes[i];
        if (s.turn === r.turn && s.x0 >= r.x0 && s.x1 <= r.x1 && s.y0 >= r.y0 && s.y1 <= r.y1) s.d = text;
    }
}

// the description of the strokes in region r, if they have one
function described(r) {
    for (var i = 0; i < strokes.length; i++) {
        var s = strokes[i];
        if (s.d && s.turn === r.turn && s.x0 >= r.x0 && s.x1 <= r.x1 && s.y0 >= r.y0 && s.y1 <= r.y1) return s.d;
    }
    return "";
}

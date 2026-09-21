import QtQuick
import net.asivery.AppLoad 1.0
import net.asivery.ApploadUtils
import "ink.js" as Ink
import "markdown.js" as Markdown
import "net.js" as Net
import "diag.js" as Diag
import "prompt.js" as Prompt

// One endless page with two layers in the same page coordinates (x 0–960, y
// down from the top of the page): the user's ink (ink.js, black) and the assistant's
// items (Markdown and SVG, grey), each placed where the assistant chose.
Rectangle {
    id: root
    anchors.fill: parent
    color: "white"

    signal close
    function unloading() {
        savePage();
        Net.closeAll();
    }

    // the settings a person sets: see README.md, Configuration
    readonly property string envFile: "file:///home/root/.config/folio/folio.env"
    // its name before 2026-09-21
    readonly property string oldEnvFile: "file:///home/root/.config/folio/bridge.env"
    property string dataDir: "file:///home/root/.local/share/claude-app"
    readonly property int historyTurns: 12

    property string version: ""
    property string slot: ""
    // from folio.env: FOLIO_SERVER_URL
    property string serverUrl: "http://127.0.0.1:18082"
    // from folio.env: FOLIO_SERVER_TOKEN, sent as x-api-key on every call
    property string serverToken: ""
    property string latestVersion: ""
    property string apiKey: ""
    property string baseUrl: ""
    property bool busy: false
    property string status: ""
    property int strokeCount: 0     // new ink, not sent yet
    property int asks: 0
    property real pageBottom: 0     // lowest ink or item on the page
    property bool inking: false
    property bool eraser: false     // the Erase button
    property bool penEraser: false  // the Marker's eraser end is in range (backend/eraser.c)
    property int toolReports: 0     // backend messages 101 since Folio opened
    property int rubberReports: 0   // of them, the eraser end
    readonly property bool erasingTool: eraser || penEraser
    property bool erasing: false
    property bool confirmNew: false

    // the toolbar: one slim row at the top, none at the bottom where the palm
    // rests. Hidden, a tab at the top edge brings it back.
    property bool barShown: true
    readonly property int barHeight: 84
    readonly property int barButtons: 6
    // the gap before Close is 40 px wider than the others
    readonly property real barCell: (width - 32 - (barButtons - 1) * 8 - 40) / barButtons
    // room to write: a stroke that ends this close to the bottom of the
    // screen scrolls the page up a third of a screen, once the pen has been
    // off the screen for roomDelay ms
    readonly property int roomEdge: 300
    property int roomDelay: 600
    // the lasso: in lassoMode the next pen stroke is a loop round part of the
    // page (Ink.lasso, drawn dashed), and the next question is about it
    property bool lassoMode: false
    property bool lassoing: false
    property int lassoId: 0         // Ink.lasso's id, or 0
    property bool lassoLast: false  // no ink since the loop: Undo takes it away

    // xochitl gives apps the pen as a mouse, tip and eraser alike; the backend
    // reads the digitizer and says which end is in range
    AppLoad {
        id: backend
        objectName: "backend"
        applicationID: "claude"
        onMessageReceived: (type, contents) => {
            if (type === 101) root.setPenEraser(contents === "rubber");
            else if (type === 102 && Diag.add(contents)) root.diagCount++;
        }
    }

    // which layers show: both, user (only the ink) or replies
    property string layers: "both"
    readonly property var layerLabels: ({ both: "Show both", user: "Show ink", replies: "Show replies" })
    // what sends the new ink: the Ask button only, a pause, a check mark or a
    // double tap (the tablet fonts may have no ✓)
    readonly property var sendModes: [
        { id: "button", label: "Ask button only", help: "Tap Ask to send what you wrote." },
        { id: "pause", label: "Pause", help: "Stop writing for a moment and it sends by itself." },
        { id: "mark", label: "Check mark", help: "Draw a small check mark (a tick) anywhere to send. The mark is not kept." },
        { id: "double", label: "Double tap", help: "Double tap the page with a finger to send." }
    ]
    // a pause: it needs no extra step, like writing on paper
    property string sendMode: "pause"
    property real pauseSecs: 4
    readonly property var pauseChoices: [2, 4, 8]

    // Handwriting the assistant has read shows as black type in its place (`typed`);
    // off, the page shows the ink as written. The ink is kept either way.
    property bool showType: true
    // conversion waits until the pen has rested this long
    property int typingDelay: 2500
    property real lastPen: 0
    property var typingQueue: []
    // the typeset word being corrected by rewriting it, or -1
    property int fixIndex: -1
    property bool fixBusy: false
    property bool fixBelow: true
    property int fixStrokes: 0
    property var pendingWord: -1
    property real tapSentAt: 0

    // the bridge accepts exactly these (bridge/main.go)
    readonly property var models: [
        { id: "haiku", label: "Haiku" },
        { id: "sonnet", label: "Sonnet" },
        { id: "opus", label: "Opus" },
        { id: "fable", label: "Fable" }
    ]
    readonly property var efforts: [
        { id: "low", label: "Low effort" },
        { id: "medium", label: "Medium effort" },
        { id: "high", label: "High effort" },
        { id: "xhigh", label: "X-high effort" },
        { id: "max", label: "Max effort" }
    ]
    property int modelIndex: 1
    property int effortIndex: 1
    property string notes: ""
    property bool notesOpen: false
    property bool confirmClearNotes: false
    readonly property int notesLimit: 4000

    readonly property int pageWidth: 960
    readonly property int margin: 36

    // the words the model gets are in prompt.js
    readonly property string systemPrompt: Prompt.system(changeChars, webCalls)
    readonly property string howBuilt: Prompt.howBuilt

    function fullSystemPrompt() {
        return systemPrompt + "\n\n" + howBuilt + "\n\nYour notes:\n" + (notes.trim() ? notes : "(none yet)");
    }

    readonly property var replyTool: Prompt.replyTool(changeChars)

    // the assistant's live access, run by the app between two requests (the
    // bridge takes user messages only, so the results go back as text)
    readonly property int webCalls: 5
    // the output limit of a reply: long items, such as an app change, must
    // not end mid-sentence (a reply that still reaches it says so)
    readonly property int maxTokens: 16000
    readonly property var webTools: Prompt.webTools(webChars)
    readonly property int webChars: 8000
    // a page view: its text in parts of about this many characters, with at
    // most so many images a part and a page, each at most 888 by 1200 px
    property int partChars: 5000
    readonly property int partImages: 4
    readonly property int pageImages: 12
    readonly property int shotParts: 6
    // web items opened a reply, and how long each may take (ms)
    readonly property int maxPages: 2
    property int pageTimeout: 60000
    property int shotTimeout: 90000
    // from folio.env: FOLIO_SEARCH_URL (a search returning SearXNG JSON or
    // DuckDuckGo HTML, with {q}) and FOLIO_SCREENSHOT_URL (with {url})
    property string searchUrl: ""
    property string shotService: ""
    // tests: function (url, opts, done) instead of the network, and
    // function (body, p) instead of posting a job to the bridge
    property var fetcher: null
    property var jobPoster: null
    property int postTries: 4
    // a link the user tapped on a web page, for the next ask: { item, href, text }
    property var chosenLink: null
    property bool webBusy: false
    // New bumps it: a page still opening then goes nowhere
    property int epoch: 0
    // bumps when a greyscale image is ready
    property int imagesVersion: 0

    // the assistant's layer. kind: markdown, svg, web (a web page), failed or change (an
    // app change card); place: below, margin, over or at; px, py, pw, ph: the
    // box in page px. A web item has its url, title, site, mode (reader or
    // screenshot), part (from 0) of parts (0: unknown), imgs (JSON: the size
    // of each image), rest (the Markdown of the parts not shown yet) and
    // webState: more (a Continue mark), continued, or end. A failed item (a web
    // item that did not open) has its url, mode and failure (why, in words).
    ListModel { id: items }
    // one per request: what the user wrote and where
    ListModel { id: turns }
    // items placed off screen: { item, up }
    ListModel { id: markers }
    // the user's handwriting as type, over its ink: { text, x, y, w, h (the
    // ink's box), size (px), turn, alive (some of its ink is still there) }
    ListModel { id: typed }

    function item(t) {
        return {
            kind: t.kind || "markdown", content: t.content || "", place: t.place || "below",
            px: +t.px || 0, py: +t.py || 0, pw: +t.pw || 0, ph: +t.ph || 0,
            small: !!t.small, turn: t.turn === undefined ? -1 : +t.turn,
            changeState: t.changeState || (t.kind === "change" ? "proposed" : ""),
            changeJob: t.changeJob || "", changeVersion: t.changeVersion || "", changeNote: t.changeNote || "",
            url: t.url || "", title: t.title || "", site: t.site || "", mode: t.mode || "",
            part: +t.part || 0, parts: +t.parts || 0, imgs: t.imgs || "", rest: t.rest || "", webState: t.webState || "",
            links: t.links || "", failure: t.failure || ""
        };
    }

    function fileGet(url, done) {
        const x = Net.xhr();
        x.onreadystatechange = () => {
            if (x.readyState === XMLHttpRequest.DONE)
                done(x.status === 200 || x.status === 0 ? x.responseText : null);
        };
        x.open("GET", url);
        x.send();
    }

    function filePut(url, text) {
        const x = new XMLHttpRequest();
        x.open("PUT", url);
        x.send(text);
    }

    function loadConfig(from) {
        const file = from || envFile;
        fileGet(file, text => {
            if (!text && file === envFile) { loadConfig(oldEnvFile); return; }
            if (!text) { status = "Cannot read " + envFile; return; }
            for (const line of text.split("\n")) {
                const m = line.match(/^\s*(?:export\s+)?([A-Z_]+)=(.*)$/);
                if (!m) continue;
                const v = m[2].trim().replace(/^["']|["']$/g, "");
                if (m[1] === "ANTHROPIC_API_KEY") apiKey = v;
                if (m[1] === "ANTHROPIC_BASE_URL") baseUrl = v.replace(/\/$/, "");
                if (m[1] === "FOLIO_SEARCH_URL") searchUrl = v;
                if (m[1] === "FOLIO_SCREENSHOT_URL") shotService = v;
                if (m[1] === "FOLIO_SERVER_URL") serverUrl = v.replace(/\/$/, "");
                if (m[1] === "FOLIO_SERVER_TOKEN") serverToken = v;
            }
            if (!apiKey || !baseUrl) status = "No ANTHROPIC_API_KEY or ANTHROPIC_BASE_URL in " + file;
        });
    }

    function loadSettings() {
        fileGet(dataDir + "/settings.json", text => {
            if (!text) return;
            try {
                const st = JSON.parse(text);
                const m = models.findIndex(x => x.id === st.model);
                const e = efforts.findIndex(x => x.id === st.effort);
                if (m >= 0) modelIndex = m;
                if (e >= 0) effortIndex = e;
                if (sendModes.some(x => x.id === st.send)) sendMode = st.send;
                if (pauseChoices.indexOf(st.pause) >= 0) pauseSecs = st.pause;
                // "claude": its name before 2026-09-21
                const lay = st.layers === "claude" ? "replies" : st.layers;
                if (layerLabels[lay]) layers = lay;
                if (typeof st.type === "boolean" && st.type !== showType) { showType = st.type; inkLayer.redrawAll(); }
                if (typeof st.bar === "boolean") barShown = st.bar;
            } catch (e) {
                console.log("Folio: bad settings.json: " + e);
            }
        });
    }

    function saveSettings() {
        filePut(dataDir + "/settings.json", JSON.stringify({
            model: models[modelIndex].id, effort: efforts[effortIndex].id,
            send: sendMode, pause: pauseSecs, layers: layers, type: showType, bar: barShown
        }));
    }

    function loadNotes() {
        fileGet(dataDir + "/notes.md", text => { if (text) notes = text; });
    }

    function saveNotes() {
        filePut(dataDir + "/notes.md", notes);
    }

    // ---- the page: saved as page.json, both layers

    function pageState() {
        const its = [], ts = [];
        for (let i = 0; i < items.count; i++) its.push(item(items.get(i)));
        for (let i = 0; i < turns.count; i++) {
            const t = turns.get(i);
            ts.push({ heard: t.heard, y0: t.y0, y1: t.y1 });
        }
        const words = [];
        for (let i = 0; i < typed.count; i++) {
            const w = typed.get(i);
            words.push({ text: w.text, x: w.x, y: w.y, w: w.w, h: w.h, size: w.size, turn: w.turn });
        }
        // the live calls' results, without screenshots (the request itself,
        // with the ink's images, is in ask.json)
        const ask = pending ? { id: pending.id, started: pending.started, who: pending.who, ctx: saveCtx(pending.ctx),
                                calls: (pending.calls || []).map(c => ({ name: c.name, input: c.input, text: c.text })) } : null;
        const loop = Ink.lasso ? { id: Ink.lasso.id, p: Ink.flatLoop(Ink.lasso) } : null;
        const opening = openingReplies.map(j => ({ specs: j.specs, ctx: saveCtx(j.ctx), turn: j.turn, cursor: j.cursor }));
        return { version: 2, strokes: Ink.save(), items: its, turns: ts, typed: words, ask: ask, lasso: loop, opening: opening };
    }

    function restorePage(st) {
        Ink.load(st.strokes || []);
        Ink.setLasso(st.lasso ? Ink.makeLoop(st.lasso.p, +st.lasso.id || 0) : null);
        lassoId = Ink.lasso ? Ink.lasso.id : 0;
        lassoMode = lassoing = lassoLast = false;
        items.clear();
        turns.clear();
        markers.clear();
        typed.clear();
        typingQueue = [];
        for (const it of st.items || []) items.append(item(it));
        for (const t of st.turns || []) turns.append({ heard: t.heard || "", y0: +t.y0 || 0, y1: +t.y1 || 0 });
        for (const w of st.typed || [])
            typed.append({ text: String(w.text || ""), x: +w.x || 0, y: +w.y || 0, w: +w.w || 0, h: +w.h || 0,
                           size: +w.size || 30, turn: w.turn === undefined ? -1 : +w.turn, alive: false });
        refreshTyped();
        strokeCount = Ink.pending().length;
        updateBottom();
        for (let i = 0; i < items.count; i++) if (items.get(i).changeState === "building") changePoll.start();
        page.contentY = Math.max(0, Math.min(page.contentHeight - page.height, pageBottom - page.height * 0.5));
        inkLayer.redrawAll();
        if (st.ask && st.ask.id) {
            pending = { id: st.ask.id, started: +st.ask.started || Date.now(), who: st.ask.who || "", ctx: loadCtx(st.ask.ctx || {}),
                        calls: Array.isArray(st.ask.calls) ? st.ask.calls : [], base: null };
            busy = true;
            status = "Waiting for the answer to the last question…";
            askPoll.start();
        }
        // replies whose pages were still opening: opened again
        openingReplies = [];
        epoch++;
        webBusy = false;
        for (const j of Array.isArray(st.opening) ? st.opening : [])
            if (j && Array.isArray(j.specs)) placeLater(j.specs, loadCtx(j.ctx || {}), +j.turn || 0, +j.cursor || pageBottom + margin);
    }

    // false until page.json is read: a save before that (Folio closed in the
    // same second it opened) would write the empty page over the real one
    property bool pageLoaded: false

    function savePage() {
        saveTimer.stop();
        if (!pageLoaded) return;
        filePut(dataDir + "/page.json", JSON.stringify(pageState()));
    }

    function scheduleSave() {
        saveTimer.restart();
    }

    function loadPage() {
        fileGet(dataDir + "/page.json", text => {
            if (text) {
                try { restorePage(JSON.parse(text)); }
                catch (e) {
                    // kept aside: the next save replaces page.json
                    console.log("Folio: bad page.json, kept as page.bad.json: " + e);
                    filePut(dataDir + "/page.bad.json", text);
                }
            }
            pageLoaded = true;
        });
    }

    function updateBottom() {
        let b = Ink.bottom();
        for (let i = 0; i < items.count; i++) {
            const it = items.get(i);
            b = Math.max(b, it.py + it.ph);
        }
        pageBottom = b;
    }

    function newPage() {
        if (busy) return;
        // the pages' greyscale images, kept beside page.json (QML cannot
        // delete files: they are emptied)
        for (let i = 0; i < items.count; i++)
            for (const im of imgsOf(items.get(i))) filePut(imageFile(im.src), "");
        chosenLink = null;
        epoch++;
        openingReplies = [];
        webBusy = false;
        Ink.clear();
        items.clear();
        turns.clear();
        markers.clear();
        typed.clear();
        typingQueue = [];
        closeFix();
        strokeCount = 0;
        lassoId = 0;
        lassoMode = lassoing = lassoLast = false;
        roomTimer.stop();
        scrollAnim.stop();
        pageBottom = 0;
        page.contentY = 0;
        inkLayer.redrawAll();
        savePage();
        status = "";
    }

    // ---- the user layer

    function penDown(x, y) {
        inking = true;
        lastPen = Date.now();
        inkIdle.stop();
        pauseTimer.stop();
        // the page never moves under the pen
        roomTimer.stop();
        scrollAnim.stop();
        if (layers === "replies") { layers = "both"; saveSettings(); }
        if (erasingTool) {
            lastErase = null;
            erasing = true;
            eraseAt(x, y);
        } else if (lassoMode) {
            lassoing = true;
            Ink.loopBegin(x, y);
        } else {
            Ink.begin(x, y);
        }
    }

    function penMove(x, y) {
        if (erasing) { eraseAt(x, y); return; }
        if (lassoing) {
            for (const d of Ink.loopAdd(x, y)) inkLayer.route([d[0], d[1], true]);
            return;
        }
        const seg = Ink.add(x, y);
        if (seg) inkLayer.route(seg);
    }

    function penUp() {
        lastPen = Date.now();
        if (lassoing) {
            lassoing = false;
            endLasso();
            inkIdle.restart();
            return;
        }
        if (erasing) {
            erasing = false;
            Ink.endErase();
            refreshTyped();
        } else {
            const s = Ink.end();
            const tick = s && Ink.isCheck(s) ? continueAt(s) : -1;
            if (tick >= 0) {
                // a tick on a page's Continue mark: the mark is not kept
                Ink.drop(s);
                inkLayer.redrawBox(s);
                continueWeb(tick);
            } else if (s && sendMode === "mark" && Ink.isCheck(s) && Ink.pending().length > 1) {
                Ink.drop(s);
                inkLayer.redrawBox(s);
                strokeCount = Ink.pending().length;
                ask();
            }
            if (s && Ink.strokes.indexOf(s) >= 0) {
                lassoLast = false;
                if (s.y1 > page.contentY + page.height - roomEdge) roomTimer.restart();
            }
        }
        strokeCount = Ink.pending().length;
        updateBottom();
        scheduleSave();
        inkIdle.restart();
        if (sendMode === "pause" && strokeCount > 0 && !busy) pauseTimer.restart();
    }

    // The digitizer says which end is in range (backend message 101). It can
    // come just after the eraser end touched the page: the stroke it began is
    // then no ink, and is never sent. It erases along its path so far.
    function setPenEraser(on) {
        toolReports++;
        if (on) rubberReports++;
        penEraser = on;
        if (!on || !Ink.current || lassoing) return;
        const s = Ink.current;
        Ink.end();
        Ink.drop(s);
        inkLayer.redrawBox(s);
        lastErase = null;
        erasing = true;
        for (const p of s.p) eraseAt(p.x, p.y);
    }

    // along the pen's path: a fast eraser moves far between two events. With
    // the type shown, the hidden ink goes with its word, a whole word at once.
    property var lastErase: null
    function eraseAt(x, y) {
        const a = erasing && lastErase ? lastErase : { x: x, y: y };
        const n = Math.max(1, Math.ceil(Math.hypot(x - a.x, y - a.y) / 8));
        const skip = showType ? (s => s.w >= 0) : null;
        for (let i = 1; i <= n; i++) {
            const px = a.x + (x - a.x) * i / n, py = a.y + (y - a.y) * i / n;
            const b = Ink.erase(px, py, 16, skip);
            if (b) inkLayer.redrawBox(b);
            if (showType) eraseWordsAt(px, py);
        }
        lastErase = { x: x, y: y };
    }

    function eraseWordsAt(x, y) {
        for (let k = 0; k < typed.count; k++) {
            const w = typed.get(k);
            if (!w.alive || x < w.x - 8 || x > w.x + w.w + 8 || y < w.y - 8 || y > w.y + w.h + 8) continue;
            typed.setProperty(k, "alive", false);
            inkLayer.redrawBox(Ink.eraseList(Ink.strokes.filter(s => s.w === k)));
        }
    }

    // a word shows while some of its ink is on the page (undo brings it back)
    function refreshTyped() {
        const n = [];
        for (const s of Ink.strokes) if (s.w >= 0) n[s.w] = true;
        for (let k = 0; k < typed.count; k++)
            if (typed.get(k).alive !== !!n[k]) typed.setProperty(k, "alive", !!n[k]);
    }

    // the strokes the ink layer draws: not those shown as type
    function shown(list) {
        return showType ? list.filter(s => !(s.w >= 0)) : list;
    }

    function setShowType(on) {
        showType = on;
        inkLayer.redrawAll();
        saveSettings();
    }

    // each layer on or off; at least one shows
    function toggleUserLayer() {
        layers = layers === "both" || layers === "user" ? "replies" : "both";
        saveSettings();
    }

    function toggleReplyLayer() {
        layers = layers === "both" || layers === "replies" ? "user" : "both";
        saveSettings();
    }

    // for the tests
    function pageView() { return page; }
    function inkCount() { return Ink.strokes.length; }
    function replyCount() { return items.count; }
    function replyItem(i) { return items.get(i); }
    function typedCount() { return typed.count; }
    function typedWord(k) { return typed.get(k); }
    function shownInk() { return shown(Ink.strokes).length; }
    function webDelegate(i) { return replyItems.itemAt(i); }
    function greyCached(src) { return Net.images[src] || null; }
    function itemBox(i) {
        const it = items.get(i);
        return { x: it.px, y: it.py, w: it.pw, h: it.ph };
    }

    function undoStroke() {
        if (lassoLast && Ink.lasso) { clearLasso(); return; }
        inkLayer.redrawBox(Ink.undo());
        refreshTyped();
        strokeCount = Ink.pending().length;
        updateBottom();
        scheduleSave();
    }

    // drops the new ink
    function clearInk() {
        const pend = Ink.pending();
        for (const s of pend) Ink.remove(s);
        strokeCount = 0;
        inkLayer.redrawAll();
        updateBottom();
    }

    // ---- scrolling: room to write, the newest part of the page

    // a third of a screen up, once the pen rests near the bottom
    function makeRoom() {
        if (Ink.current || lassoing || erasing || pen.pressed) return;
        scrollTo(page.contentY + Math.round(page.height / 3), true);
    }

    function scrollTo(y, smooth) {
        const to = Math.max(0, Math.min(page.contentHeight - page.height, y));
        scrollAnim.stop();
        page.cancelFlick();
        if (Math.abs(to - page.contentY) < 1) return;
        if (!smooth) { page.contentY = to; return; }
        scrollAnim.from = page.contentY;
        scrollAnim.to = to;
        scrollAnim.start();
    }

    // the end of the page, with blank paper below it
    function jumpToLatest() {
        scrollTo(pageBottom - page.height * 0.5, false);
    }

    function setBar(on) {
        barShown = on;
        saveSettings();
    }

    // ---- the lasso

    function toggleLasso() {
        if (lassoMode) {
            lassoMode = false;
            clearLasso();
            status = "";
            return;
        }
        lassoMode = true;
        eraser = false;
        status = "Lasso: draw a loop with the pen round the part of the page to ask about.";
    }

    function endLasso() {
        const live = Ink.loop, l = Ink.loopEnd();
        if (live) inkLayer.redrawBox(live);
        if (!l) return;  // a tap: still in lasso mode
        const n = lassoed(l, Ink.regions(Ink.strokes, 60)).length;
        if (!n) {
            status = "Nothing inside the loop. Draw it round your writing or a reply.";
            return;
        }
        const old = Ink.lasso;
        Ink.setLasso(l);
        if (old) inkLayer.redrawBox(old);
        inkLayer.redrawBox(l);
        lassoId = l.id;
        lassoMode = false;
        lassoLast = true;
        status = "Lassoed " + (n > 1 ? n + " parts" : "one part") + " of the page. Now write your question about " + (n > 1 ? "them." : "it.");
        scheduleSave();
    }

    function clearLasso() {
        const old = Ink.lasso;
        Ink.setLasso(null);
        lassoId = 0;
        lassoLast = false;
        if (old) inkLayer.redrawBox(old);
        scheduleSave();
    }

    // the reply to the question about the lasso is on the page: the loop goes
    function dropLasso(ctx) {
        if (ctx && ctx.lasso && Ink.lasso && Ink.lasso.id === ctx.lasso.id) clearLasso();
    }

    // What the loop L goes round: the ink regions (ids from `regions`; not
    // the new ink, which is the question) and the assistant's items, each
    // with its box and text. [{ id, what, box, part (the box of the part
    // inside, or null for all of it), text, none (said when it has no text) }]
    function lassoed(L, regions) {
        const out = [];
        const inL = p => Ink.inside(L, p.x, p.y);
        regions.forEach((r, k) => {
            if (r.turn < 0 || r.x1 < L.x0 || r.x0 > L.x1 || r.y1 < L.y0 || r.y0 > L.y1) return;
            const all = Ink.strokes.filter(s => s.turn === r.turn && s.x0 >= r.x0 && s.x1 <= r.x1 && s.y0 >= r.y0 && s.y1 <= r.y1);
            const hit = all.filter(s => s.p.filter(inL).length * 2 >= s.p.length);
            if (!hit.length) return;
            const seen = {}, words = [];
            for (const s of hit) {
                if (!(s.w >= 0) || seen[s.w] || s.w >= typed.count) continue;
                seen[s.w] = true;
                const w = typed.get(s.w);
                if (w.alive) words.push({ text: w.text, x0: w.x, y0: w.y, x1: w.x + w.w, y1: w.y + w.h });
            }
            const b = Ink.box(hit);
            out.push({ id: "i" + (k + 1), what: "the user's ink (turn " + (r.turn + 1) + ")",
                       box: { x0: r.x0, y0: r.y0, x1: r.x1, y1: r.y1 }, part: hit.length < all.length ? b : null,
                       text: Ink.readingOrder(words).map(w => w.text).join(" "),
                       none: "handwriting or a drawing, not typeset: see the image of the loop" });
        });
        for (let i = 0; i < items.count; i++) {
            const it = items.get(i);
            const x0 = Math.max(it.px, L.x0), y0 = Math.max(it.py, L.y0);
            const x1 = Math.min(it.px + it.pw, L.x1), y1 = Math.min(it.py + it.ph, L.y1);
            if (x1 <= x0 || y1 <= y0) continue;
            let n = 0;
            for (let a = 0; a < 12; a++)
                for (let b = 0; b < 12; b++)
                    if (Ink.inside(L, x0 + (a + 0.5) * (x1 - x0) / 12, y0 + (b + 0.5) * (y1 - y0) / 12)) n++;
            if (!n) continue;
            const cover = n / 144 * (x1 - x0) * (y1 - y0) / Math.max(1, it.pw * it.ph);
            const d = it.kind === "web" && it.mode !== "screenshot" ? replyItems.itemAt(i) : null;
            const text = it.kind === "svg" || it.kind === "web" && !d ? "" : d ? d.textIn(x0, y0, x1, y1)
                : it.kind === "change" ? it.content : Markdown.plain(it.content);
            out.push({ id: "c" + i, what: "your " + it.kind + " (" + it.place + (it.turn >= 0 ? ", turn " + (it.turn + 1) : "") + ")",
                       box: { x0: it.px, y0: it.py, x1: it.px + it.pw, y1: it.py + it.ph },
                       part: cover < 0.85 ? { x0: x0, y0: y0, x1: x1, y1: y1 } : null,
                       text: String(text || "").replace(/\s+/g, " ").trim(),
                       none: it.kind === "svg" ? "a drawing" : "a screenshot of a web page" });
        }
        return out;
    }

    // for the tests
    function lassoParts() { return Ink.lasso ? lassoed(Ink.lasso, Ink.regions(Ink.strokes, 60)) : []; }

    // the lasso in the request
    function lassoText(ls) {
        if (!ls) return "";
        const b = ls.box;
        const lines = ls.parts.slice(0, 16).map(e => "- " + e.id + ": " + e.what + ", x " + span(e.box.x0, e.box.x1) +
            ", y " + span(e.box.y0, e.box.y1) +
            (e.part ? " (partly: the loop holds x " + span(e.part.x0, e.part.x1) + ", y " + span(e.part.y0, e.part.y1) + " of it)" : "") + ": " +
            (e.text ? "\"" + (e.text.length > 800 ? e.text.slice(0, 800) + "…" : e.text) + "\"" : e.none));
        return "Lasso: the user drew a loop round part of the page, x " + span(b.x0, b.x1) + ", y " + span(b.y0, b.y1) +
               ". The new handwriting is a question about just that part: answer about what is inside the loop. Inside it:\n" +
               (lines.join("\n") || "(nothing)") + "\n\n";
    }

    function lassoStyle(ctx) {
        ctx.strokeStyle = "black";
        ctx.lineWidth = 3;
        ctx.lineCap = "butt";
    }

    // the dashes of the loop l, for a canvas at page (dx, dy), w by h
    function drawLoop(ctx, l, dx, dy, w, h) {
        if (!l || l.x1 < dx - 4 || l.x0 > dx + w + 4 || l.y1 < dy - 4 || l.y0 > dy + h + 4) return;
        lassoStyle(ctx);
        ctx.beginPath();
        for (const [a, b] of l.dash) {
            if (Math.max(a.x, b.x) < dx - 4 || Math.min(a.x, b.x) > dx + w + 4 ||
                Math.max(a.y, b.y) < dy - 4 || Math.min(a.y, b.y) > dy + h + 4) continue;
            ctx.moveTo(a.x - dx, a.y - dy);
            ctx.lineTo(b.x - dx, b.y - dy);
        }
        ctx.stroke();
    }

    property var lastTap: null
    function fingerTap(x, y) {
        if (sendMode !== "double") return;
        const now = Date.now();
        const t = lastTap;
        if (t && now - t.time < 500 && Math.abs(x - t.x) + Math.abs(y - t.y) < 80 && t.cy === page.contentY) {
            lastTap = null;
            tapSentAt = now;
            wordTap.stop();
            ask();
        } else {
            lastTap = { time: now, x: x, y: y, cy: page.contentY };
        }
    }

    function inkStyle(ctx) {
        ctx.strokeStyle = "black";
        ctx.lineWidth = 4;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
    }

    function drawStrokes(ctx, list, dx, dy) {
        inkStyle(ctx);
        ctx.beginPath();
        for (const s of list) {
            const p = s.p;
            if (p.length === 1) {
                ctx.moveTo(p[0].x - dx, p[0].y - dy);
                ctx.lineTo(p[0].x - dx + 0.5, p[0].y - dy);
            }
            for (let i = 1; i < p.length; i++) {
                ctx.moveTo(p[i - 1].x - dx, p[i - 1].y - dy);
                ctx.lineTo(p[i].x - dx, p[i].y - dy);
            }
        }
        ctx.stroke();
    }

    // strokes that touch the page rows from y0 to y1
    function strokesIn(y0, y1) {
        const seen = new Set();
        for (let r = Math.floor(y0 / Ink.ROW); r <= Math.floor(y1 / Ink.ROW); r++)
            for (const s of Ink.inRow(r)) seen.add(s);
        return Array.from(seen);
    }

    // ---- placing the assistant's items

    // the page as it is when the ink is sent: ink regions i1… and the newest one
    function context() {
        const pend = Ink.pending();
        const regions = Ink.regions(Ink.strokes, 60);
        const fresh = Ink.regions(pend, 60);
        let newest = null;
        for (const r of fresh) if (!newest || r.last > newest.last) newest = r;
        return { regions: regions, newest: newest, sent: pend, box: Ink.box(pend), pieces: Ink.pieces(pend, 18).slice(0, 200) };
    }

    function pieceList(ctx) {
        return ctx.pieces.map((p, k) => "n" + (k + 1) + ": x " + span(p.x0, p.x1) + ", y " + span(p.y0, p.y1)).join("\n");
    }

    // ---- handwriting as type

    // the assistant has read the ink: its `typeset` goes on the page once the pen
    // rests, never under a pen that is still writing.
    function convertLater(list, ctx) {
        if (!Array.isArray(list) || !list.length) return;
        typingQueue = typingQueue.concat([{ list: list, ctx: ctx }]);
        flushTyping();
    }

    function flushTyping() {
        if (!typingQueue.length) return;
        const wait = typingDelay - (Date.now() - lastPen);
        if (Ink.current || Ink.fixing || wait > 0) {
            typingTimer.interval = Math.max(50, wait);
            typingTimer.restart();
            return;
        }
        const q = typingQueue;
        typingQueue = [];
        for (const job of q) applyTyping(job.list, job.ctx);
        scheduleSave();
    }

    // the font size for the type of handwriting `h` px tall: how much of the
    // em that handwriting spans depends on its ascenders and descenders
    function typeSize(text, h) {
        const tall = /[A-Zbdfhklt0-9!?'"()\/\[\]{}]/.test(text), low = /[gjpqy,;()\[\]{}]/.test(text);
        return h * (tall && low ? 1.0 : tall ? 1.3 : low ? 1.35 : 1.9);
    }

    // Entries that share a piece become one run of words, in the assistant's
    // order: the piece's ink is theirs together, and one entry alone would
    // hide the other's words under its text. Unknown ids and ink that already
    // shows as type are left out; ink that no entry covers stays ink.
    function applyTyping(list, ctx) {
        const byId = {};
        ctx.pieces.forEach((p, k) => byId["n" + (k + 1)] = p);
        const live = new Set(Ink.strokes);
        const entries = [], seen = new Set();
        for (const e of list) {
            const text = String(e && e.text || "").replace(/\s+/g, " ").trim();
            const ids = [...new Set((e && Array.isArray(e.ids) ? e.ids : []).map(id => String(id).trim()))].filter(id => byId[id]);
            const key = text + "|" + ids.slice().sort().join(",");
            if (!text || !ids.length || seen.has(key)) continue;
            seen.add(key);
            entries.push({ text: text, ids: ids });
        }
        const up = entries.map((e, i) => i);
        const find = i => up[i] === i ? i : (up[i] = find(up[i]));
        const owner = {};
        entries.forEach((e, i) => e.ids.forEach(id => {
            if (id in owner) up[find(i)] = find(owner[id]);
            else owner[id] = i;
        }));
        const runs = new Map();
        entries.forEach((e, i) => {
            const g = find(i);
            if (!runs.has(g)) runs.set(g, { texts: [], ids: new Set() });
            runs.get(g).texts.push(e.text);
            e.ids.forEach(id => runs.get(g).ids.add(id));
        });
        const words = [];
        for (const run of runs.values()) {
            let strokes = [];
            for (const id of run.ids) strokes = strokes.concat(byId[id].strokes);
            strokes = strokes.filter(s => live.has(s) && !(s.w >= 0));
            if (!strokes.length) continue;
            const text = run.texts.join(" ");
            const b = Ink.box(strokes);
            words.push({ text: text, strokes: strokes, b: b, x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1,
                         size: typeSize(text, Math.max(8, b.y1 - b.y0)) });
        }
        // in reading order: by line, then left to right (an entry's own words
        // keep the assistant's order); one size a line, the median of its words
        for (const line of Ink.lines(words)) {
            const sizes = line.map(w => w.size).sort((a, b) => a - b);
            const size = Math.round(Math.max(22, Math.min(96, sizes[Math.floor(sizes.length / 2)])));
            for (const w of line) {
                const k = typed.count;
                typed.append({ text: w.text, x: w.b.x0, y: w.b.y0, w: w.b.x1 - w.b.x0, h: w.b.y1 - w.b.y0,
                               size: size, turn: w.strokes[0].turn, alive: true });
                for (const s of w.strokes) s.w = k;
                if (showType) inkLayer.redrawBox(w.b);
            }
        }
    }

    // the typeset words of the page that lie in the box, in reading order
    function typedIn(b) {
        const out = [];
        for (let k = 0; k < typed.count; k++) {
            const w = typed.get(k);
            const cx = w.x + w.w / 2, cy = w.y + w.h / 2;
            if (w.alive && cx >= b.x0 && cx <= b.x1 && cy >= b.y0 && cy <= b.y1)
                out.push({ text: w.text, x0: w.x, y0: w.y, x1: w.x + w.w, y1: w.y + w.h });
        }
        return Ink.readingOrder(out);
    }

    // tapping a word opens the rewrite pad (after a pause in double tap mode,
    // where the tap may be the first of two)
    function tapWord(k) {
        if (Date.now() - tapSentAt < 700) return;
        if (sendMode === "double") {
            pendingWord = k;
            wordTap.restart();
        } else {
            openFix(k);
        }
    }

    function openFix(k) {
        if (k < 0 || k >= typed.count) return;
        const w = typed.get(k);
        fixBelow = w.y + w.h / 2 - page.contentY < page.height / 2;
        Ink.fixClear();
        fixStrokes = 0;
        fixIndex = k;
        fixPad.redraw();
    }

    function closeFix() {
        Ink.fixClear();
        fixStrokes = 0;
        fixIndex = -1;
        fixBusy = false;
        fixPad.redraw();
    }

    // the line around the word, for context
    function lineOf(k) {
        const w = typed.get(k);
        const out = [];
        for (let j = 0; j < typed.count; j++) {
            const o = typed.get(j);
            if (o.alive && o.turn === w.turn) out.push({ text: o.text, k: j, x0: o.x, y0: o.y, x1: o.x + o.w, y1: o.y + o.h });
        }
        const line = Ink.lines(out).find(l => l.some(o => o.k === k)) || [];
        return line.map(o => o.text).join(" ");
    }

    // the rewritten word, read by the assistant
    function sendFix() {
        if (fixIndex < 0 || !Ink.fix.length || fixBusy || exporting) return;
        if (!apiKey || !baseUrl) { loadConfig(); return; }
        const k = fixIndex;
        const b = Ink.box(Ink.fix);
        const x0 = Math.max(0, Math.floor(b.x0 - 24)), y0 = Math.max(0, Math.floor(b.y0 - 24));
        fixBusy = true;
        status = "Reading the word…";
        exportImages([{ ink: true, strokes: Ink.fix.slice(),
                        box: { x: x0, y: y0, w: Math.ceil(b.x1 + 24) - x0, h: Math.ceil(b.y1 + 24) - y0 } }],
                     pngs => recognize(pngs[0], k),
                     () => { fixBusy = false; status = "Failed: the word could not be rendered."; });
    }

    function recognize(png, k) {
        const old = typed.get(k).text, line = lineOf(k);
        const body = {
            model: models[modelIndex].id,
            output_config: { effort: "low" },
            max_tokens: 200,
            system: "You read handwriting on a reMarkable tablet. Reply with only the handwritten text in the image, " +
                    "exactly as written, on one line: no quotes, no comments.",
            messages: [{ role: "user", content: [
                { type: "text", text: "The user rewrote this to correct the typeset \"" + old + "\"" +
                                      (line && line !== old ? " in the line \"" + line + "\"" : "") + "." },
                { type: "image", source: { type: "base64", media_type: "image/png", data: png } }
            ] }]
        };
        const x = Net.xhr();
        x.timeout = 60000;
        x.onreadystatechange = () => {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            fixBusy = false;
            let text = "";
            try {
                const r = JSON.parse(x.responseText);
                if (x.status !== 200) throw (r.error && r.error.message) || ("HTTP " + x.status);
                for (const c of r.content) if (c.type === "text") text += c.text;
                text = text.split("\n").map(l => l.trim()).filter(l => l)[0] || "";
                text = text.replace(/^["“”']+|["“”']+$/g, "").trim();
                if (!text) throw "the assistant could not read it";
            } catch (e) {
                status = "Failed: " + (x.status === 0 && !x.responseText ? "cannot reach the assistant at " + baseUrl + "." : String(e)) +
                         " Write it again or cancel.";
                return;
            }
            if (fixIndex !== k) { status = ""; return; }  // cancelled meanwhile
            closeFix();
            setWord(k, text);
            status = "Corrected to “" + text + "”";
        };
        x.open("POST", baseUrl + "/v1/messages");
        x.setRequestHeader("content-type", "application/json");
        x.setRequestHeader("x-api-key", apiKey);
        x.setRequestHeader("anthropic-version", "2023-06-01");
        x.send(JSON.stringify(body));
    }

    // corrects a typeset word, and what the assistant heard in its turn
    function setWord(k, text) {
        const w = typed.get(k), old = w.text;
        typed.setProperty(k, "text", text);
        if (w.turn >= 0 && w.turn < turns.count) {
            const heard = turns.get(w.turn).heard, i = heard.indexOf(old);
            if (i >= 0) turns.setProperty(w.turn, "heard", heard.slice(0, i) + text + heard.slice(i + old.length));
        }
        savePage();
    }

    function refBox(ref, ctx) {
        const m = String(ref || "").trim().match(/^([ic])(\d+)$/);
        if (!m) return null;
        const n = +m[2];
        if (m[1] === "i") return ctx.regions[n - 1] || null;
        if (n >= items.count) return null;
        const it = items.get(n);
        return { x0: it.px, y0: it.py, x1: it.px + it.pw, y1: it.py + it.ph };
    }

    function svgAspect(svg) {
        let m = svg.match(/viewBox\s*=\s*["']\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)/);
        if (!m) m = svg.match(/<svg[^>]*?\swidth\s*=\s*["']([\d.]+)[^>]*?\sheight\s*=\s*["']([\d.]+)/);
        return m && +m[1] > 0 && +m[2] > 0 ? +m[2] / +m[1] : 0.75;
    }

    function taken() {
        const out = [];
        for (const g of Ink.regions(Ink.strokes, 30))
            out.push({ x: g.x0 - 12, y: g.y0 - 12, w: g.x1 - g.x0 + 24, h: g.y1 - g.y0 + 24 });
        for (let i = 0; i < items.count; i++) {
            const it = items.get(i);
            out.push({ x: it.px, y: it.py, w: it.pw, h: it.ph });
        }
        return out;
    }

    // Places the assistant's items on the page (see the system prompt) and returns
    // their indices. state.cursor is where the next below item goes.
    function placeItems(specs, ctx, turn, state) {
        if (!state.taken) state.taken = taken();
        const placed = [];
        const num = v => v === undefined || v === null || v === "" || isNaN(Number(v)) ? null : Number(v);
        // one item that cannot be placed does not stop the others
        for (const spec of specs) try {
            const content = String(spec.content || "");
            if (!content.trim() && !(spec.kind === "web" && spec.imgs)) continue;
            const kind = ["svg", "change", "web", "failed"].indexOf(spec.kind) >= 0 ? spec.kind : "markdown";
            let place = ["below", "margin", "over", "at"].indexOf(spec.place) >= 0 ? spec.place : "below";
            // a page needs the width of the paper
            if ((kind === "web" || kind === "failed") && place !== "at") place = "below";
            const x = num(spec.x), y = num(spec.y), w = num(spec.width), h = num(spec.height);
            let R = refBox(spec.ref, ctx);
            if (!R && x !== null && y !== null) R = { x0: x, y0: y, x1: x + (w || 240), y1: y + (h || 60) };
            if ((place === "margin" || place === "over") && !R) place = "below";
            if (place === "at" && (x === null || y === null)) place = "below";

            let r, slide = true, small = false;
            if (place === "below") {
                r = { x: margin, y: state.cursor, w: pageWidth - 2 * margin };
            } else if (place === "margin") {
                small = true;
                const most = kind === "svg" ? 320 : 420;
                const right = pageWidth - 24 - (R.x1 + 24), left = R.x0 - 48;
                if (right >= 220) r = { x: R.x1 + 24, y: R.y0, w: Math.min(right, most) };
                else if (left >= 220) r = { x: R.x0 - 24 - Math.min(left, most), y: R.y0, w: Math.min(left, most) };
                else r = { x: margin, y: R.y1 + 16, w: pageWidth - 2 * margin };
            } else if (place === "over") {
                slide = false;
                r = x !== null && y !== null && w && h && !spec.ref
                    ? { x: x, y: y, w: w, h: h }
                    : { x: R.x0 - 12, y: R.y0 - 12, w: R.x1 - R.x0 + 24, h: R.y1 - R.y0 + 24 };
            } else {
                r = { x: x, y: y, w: w || pageWidth - margin - x };
            }
            r.x = Math.max(0, Math.min(pageWidth - 120, r.x));
            r.y = Math.max(0, r.y);
            r.w = Math.max(120, Math.min(pageWidth - r.x, r.w));

            if (kind === "svg" && place !== "over") r.h = Math.min(1600, h && place === "at" ? h : r.w * svgAspect(content));
            items.append(item({
                kind: kind, content: content, place: place, small: small, turn: turn,
                px: r.x, py: r.y, pw: r.w, ph: r.h || 0,
                changeState: spec.changeState, changeJob: spec.changeJob,
                changeVersion: spec.changeVersion, changeNote: spec.changeNote,
                url: spec.url, title: spec.title, site: spec.site, mode: spec.mode, part: spec.part, parts: spec.parts,
                imgs: spec.imgs, rest: spec.rest, webState: spec.webState, failure: spec.failure
            }));
            const i = items.count - 1;
            if (kind !== "svg") {
                const d = replyItems.itemAt(i);
                if (d) d.layoutNow();
                if (place !== "over" || !r.h) r.h = d && d.height > 0 ? d.height : 60;
                // the boxes of a page's links, once: the item does not move
                if (d && kind === "web") items.setProperty(i, "links", JSON.stringify(d.scanLinks()));
            }
            if (slide) {
                const s = Ink.slide(r, state.taken, 20);
                r.y = s.y;
            }
            items.setProperty(i, "py", r.y);
            items.setProperty(i, "ph", r.h);
            state.taken.push({ x: r.x, y: r.y, w: r.w, h: r.h });
            if (place === "below") state.cursor = r.y + r.h + 28;
            placed.push(i);
        } catch (e) {
            console.warn("Folio: an item could not be placed: " + e);
        }
        updateBottom();
        return placed;
    }

    // Shows the reply: scrolls to a below reply that runs off the bottom of
    // the screen, as long as the newest ink stays in view; marks the rest.
    function announce(list, ctx) {
        if (!list.length) return;
        const first = items.get(list[0]);
        const top = page.contentY, bottom = top + page.height;
        const n = ctx.newest;
        if (first.place === "below" && first.py + first.ph > bottom && n && n.y1 > top && n.y0 < bottom) {
            const want = Math.min(first.py + first.ph + 40 - page.height, n.y0 - 60);
            if (want > top) page.contentY = Math.min(want, page.contentHeight - page.height);
        }
        for (const i of list) if (!onScreen(i, 60)) markers.append({ item: i, up: items.get(i).py < page.contentY });
    }

    function onScreen(i, inset) {
        const it = items.get(i);
        return it.py + it.ph > page.contentY + inset && it.py < page.contentY + page.height - inset;
    }

    function checkMarkers() {
        for (let k = markers.count - 1; k >= 0; k--)
            if (markers.get(k).item >= items.count || onScreen(markers.get(k).item, 60)) markers.remove(k);
    }

    function markerLabel(k) {
        const m = markers.get(k);
        const it = items.get(m.item);
        const what = it.kind === "svg" ? "drawing" : it.kind === "change" ? "app change" : it.kind === "web" || it.kind === "failed" ? "page"
            : it.place === "below" ? "reply" : it.place === "over" ? "mark" : "note";
        return what + (m.up ? " added above" : " below") + (markers.count > 1 ? "  (+" + (markers.count - 1) + ")" : "");
    }

    function goToMarker() {
        if (!markers.count) return;
        const i = markers.get(markers.count - 1).item;
        markers.remove(markers.count - 1);
        const it = items.get(i);
        page.contentY = Math.max(0, Math.min(page.contentHeight - page.height, it.py - 160));
        checkMarkers();
    }

    // ---- asking the assistant

    property var askCtx: null
    property var exportJobs: []
    property var exportOut: []
    property var exportGrab: null
    property var lastImages: []

    // the parts of the page around the new ink: full width, a little above
    // and below each group of it, at most three
    function pageBoxes(pend) {
        let boxes = Ink.regions(pend, 200).map(r => ({
            y0: Math.max(0, r.y0 - 260), y1: Math.min(Math.max(pageBottom, r.y1) + 40, r.y1 + 160)
        }));
        boxes.sort((a, b) => a.y0 - b.y0);
        const out = [];
        for (const b of boxes) {
            const last = out[out.length - 1];
            if (last && b.y0 <= last.y1) last.y1 = Math.max(last.y1, b.y1);
            else out.push(b);
        }
        while (out.length > 3) {
            let k = 0;
            for (let j = 1; j < out.length - 1; j++) if (out[j + 1].y0 - out[j].y1 < out[k + 1].y0 - out[k].y1) k = j;
            out[k].y1 = out[k + 1].y1;
            out.splice(k + 1, 1);
        }
        return out.map(b => ({ x: 0, y: Math.round(Math.max(b.y0, b.y1 - 2400)), w: pageWidth,
                               h: Math.round(b.y1 - Math.max(b.y0, b.y1 - 2400)) }));
    }

    function ask() {
        if (busy || (strokeCount === 0 && !chosenLink) || exporting) return;
        if (!apiKey || !baseUrl) { loadConfig(); return; }
        busy = true;
        asks++;
        pauseTimer.stop();
        askCtx = context();
        refreshBuilds();
        askCtx.links = markedLinks(askCtx.sent);
        askCtx.marks = markedText(askCtx.sent);
        const L = Ink.lasso;
        askCtx.lasso = L ? { id: L.id, box: { x0: L.x0, y0: L.y0, x1: L.x1, y1: L.y1 }, parts: lassoed(L, askCtx.regions) } : null;
        const tapped = chosenLink;
        chosenLink = null;
        if (tapped) {
            askCtx.links.unshift(Object.assign({ tapped: true }, tapped));
            // with no ink, the reply goes below the page the link is on
            if (!askCtx.newest && tapped.item < items.count) {
                const it = items.get(tapped.item);
                askCtx.newest = { x0: it.px, y0: it.py, x1: it.px + it.pw, y1: it.py + it.ph, turn: -1, last: -1 };
            }
        }
        const jobs = [];
        const b = askCtx.box;
        if (b) {
            const x0 = Math.max(0, Math.floor(b.x0 - 24)), y0 = Math.max(0, Math.floor(b.y0 - 24));
            jobs.push({ ink: true, strokes: askCtx.sent,
                        box: { x: x0, y: y0, w: Math.min(pageWidth, Math.ceil(b.x1 + 24)) - x0, h: Math.ceil(b.y1 + 24) - y0 } });
            // ink only: grabToImage of the replies crashes xochitl ("Layers
            // are not supported"), and a crash loop reboots the tablet
            for (const pb of pageBoxes(askCtx.sent)) jobs.push({ ink: true, box: pb, strokes: Ink.strokes.slice() });
            // what the question is about: the ink in the loop, and the loop
            if (L) {
                const lx = Math.max(0, Math.floor(L.x0 - 24)), ly = Math.max(0, Math.floor(L.y0 - 24));
                jobs.push({ ink: true, loop: L, strokes: Ink.strokes.slice(),
                            box: { x: lx, y: ly, w: Math.min(pageWidth, Math.ceil(L.x1 + 24)) - lx,
                                   h: Math.min(2400, Math.ceil(L.y1 + 24) - ly) } });
            }
        }
        askCtx.jobs = jobs;
        status = "Sending…";
        exportImages(jobs, pngs => { lastImages = pngs; send(pngs); }, () => {
            busy = false;
            status = "Failed: the page could not be rendered. The ink is kept: ask again.";
        });
    }

    // renders the jobs to PNGs, one after the other, then done(pngs)
    readonly property bool exporting: exportJobs.length > 0
    property var exportDone: null
    property var exportFail: null
    function exportImages(jobs, done, fail) {
        exportDone = done;
        exportFail = fail;
        exportOut = [];
        exportJobs = jobs;
        nextExport();
    }

    function nextExport() {
        if (!exportJobs.length) {
            const done = exportDone;
            exportDone = exportFail = null;
            if (done) done(exportOut);
            return;
        }
        const job = exportJobs[0];
        sink.width = job.box.w;
        sink.height = job.box.h;
        sink.job = job;
        if (job.ink) {
            sink.requestPaint();
        } else {
            scene.box = job.box;
            scene.list = [];
            scene.words = [];
            const list = [];
            for (let i = 0; i < items.count; i++) {
                const it = items.get(i);
                if (it.py < job.box.y + job.box.h && it.py + it.ph > job.box.y) list.push(item(it));
            }
            const words = [];
            for (let k = 0; showType && k < typed.count; k++) {
                const w = typed.get(k);
                if (w.alive && w.y < job.box.y + job.box.h && w.y + w.h > job.box.y)
                    words.push({ text: w.text, x: w.x, y: w.y, w: w.w, h: w.h, size: w.size });
            }
            scene.list = list;
            scene.words = words;
            scene.active = true;
        }
    }

    function grabScene() {
        const ok = scene.item && scene.item.grabToImage(res => {
            exportGrab = res;
            sink.src = res.url;
            sink.loadImage(res.url);
            if (sink.isImageLoaded(res.url)) sink.requestPaint();
        });
        if (!ok) exportFailed();
    }

    function exported(png) {
        sink.job = null;
        if (sink.src) sink.unloadImage(sink.src);
        sink.src = "";
        exportGrab = null;
        scene.active = false;
        exportOut = exportOut.concat([png]);
        exportJobs = exportJobs.slice(1);
        Qt.callLater(nextExport);
    }

    function exportFailed() {
        sink.job = null;
        scene.active = false;
        exportJobs = [];
        const fail = exportFail;
        exportDone = exportFail = null;
        if (fail) fail();
    }

    function span(a, b) { return Math.round(a) + "–" + Math.round(b); }

    // the page map: regions near the new ink, with their ids
    function pageMap(ctx) {
        const near = ctx.box ? (ctx.box.y0 + ctx.box.y1) / 2 : pageBottom;
        const all = [];
        ctx.regions.forEach((r, k) => {
            const words = r.turn < 0 ? [] : typedIn(r);
            all.push({ y: r.y0, d: Math.abs((r.y0 + r.y1) / 2 - near),
                line: "i" + (k + 1) + ": ink" + (r.turn < 0 ? " (new)" : ", turn " + (r.turn + 1)) +
                      ", x " + span(r.x0, r.x1) + ", y " + span(r.y0, r.y1) +
                      (words.length ? ", shown as type: \"" + words.map(w => w.text).join(" ").slice(0, 120) + "\"" : "") });
        });
        for (let i = 0; i < items.count; i++) {
            const it = items.get(i);
            const text = it.kind === "svg" ? "a drawing" : it.kind === "web" ? webLabel(it) : it.kind === "failed" ? failedLabel(it)
                : "\"" + it.content.replace(/\s+/g, " ").slice(0, 80) + "\"";
            all.push({ y: it.py, d: Math.abs(it.py + it.ph / 2 - near),
                line: "c" + i + ": your " + it.kind + " (" + it.place + (it.turn >= 0 ? ", turn " + (it.turn + 1) : "") + "), x " +
                      span(it.px, it.px + it.pw) + ", y " + span(it.py, it.py + it.ph) + ": " + text });
        }
        const kept = all.sort((a, b) => a.d - b.d).slice(0, 40).sort((a, b) => a.y - b.y);
        return kept.map(e => "- " + e.line).join("\n");
    }

    function transcript() {
        let s = "";
        for (let t = Math.max(0, turns.count - historyTurns); t < turns.count; t++) {
            let replies = "";
            for (let i = 0; i < items.count; i++) {
                const it = items.get(i);
                if (it.turn !== t) continue;
                replies += "\n[c" + i + ", " + it.place + "] " + (it.kind === "svg" ? "(a drawing)"
                    : it.kind === "web" ? "(" + webLabel(it) + ")" + (it.mode === "screenshot" ? "" : "\n" + Markdown.plain(it.content).slice(0, 1500))
                    : it.kind === "failed" ? "(" + failedLabel(it) + ")"
                    : it.kind === "change" ? changeText(it) : it.content.slice(0, 1500));
            }
            const u = turns.get(t);
            s += "Turn " + (t + 1) + ". User (ink at y " + span(u.y0, u.y1) + "): " + u.heard + "\nAssistant:" + replies + "\n\n";
        }
        return s;
    }

    function send(pngs) {
        const ctx = askCtx;
        const history = transcript();
        const ink = ctx.jobs.length ? ctx.jobs[0].box : null;
        const content = [{ type: "text", text:
            (history ? "The conversation so far:\n\n" + history : "This is the first message on the page.\n\n") +
            "The page is " + pageWidth + " px wide and " + Math.round(Math.max(pageBottom, page.height)) +
            " px tall so far; the user sees y " + span(page.contentY, page.contentY + page.height) + ".\n" +
            "Page map:\n" + (pageMap(ctx) || "(empty)") + "\n\n" +
            linkText(ctx.links, ctx.marks) +
            lassoText(ctx.lasso) +
            failedText() +
            "Recent builds of app changes, newest first:\n" + (buildStatus() || "(none)") + "\n\n" +
            selfReport() +
            "Pieces of the new ink, for `typeset`:\n" + (pieceList(ctx) || "(none)") + "\n\n" +
            (ink ? "Image 1: the user's new ink alone, the page box x " + span(ink.x, ink.x + ink.w) +
                   ", y " + span(ink.y, ink.y + ink.h) + " (1 image px = 1 page px)." +
                   (ctx.newest ? " The newest ink is at x " + span(ctx.newest.x0, ctx.newest.x1) + ", y " + span(ctx.newest.y0, ctx.newest.y1) + "." : "")
                 : "There is no new ink: the user tapped a link and then Ask.")
        }];
        if (pngs.length) content.push({ type: "image", source: { type: "base64", media_type: "image/png", data: pngs[0] } });
        for (let k = 1; k < pngs.length; k++) {
            const b = ctx.jobs[k].box;
            content.push({ type: "text", text: ctx.jobs[k].loop
                ? "Image " + (k + 1) + ": the lassoed part of the page, x " + span(b.x, b.x + b.w) + ", y " + span(b.y, b.y + b.h) +
                  ": the user's ink and the loop (dashed); your items are not drawn, their text is with the lasso above. " +
                  "Image x 0, y 0 is page x " + b.x + ", y " + b.y + "."
                : "Image " + (k + 1) + ": the page from y " + span(b.y, b.y + b.h) +
                  ", full width, the user's ink only (your replies are not drawn; their text is in the conversation). Image y 0 is page y " + b.y + "." });
            content.push({ type: "image", source: { type: "base64", media_type: "image/png", data: pngs[k] } });
        }
        const p = { id: "", started: Date.now(), who: models[modelIndex].label + ", " + efforts[effortIndex].id, ctx: ctx,
                    calls: [], base: { content: content, model: models[modelIndex].id, effort: efforts[effortIndex].id, system: fullSystemPrompt() } };
        // for a reopened app that must send the live calls' results
        filePut(dataDir + "/ask.json", JSON.stringify(p.base));
        status = p.who;
        postJob(p);
    }

    // what Folio knows about itself: the version that runs, the model, and
    // its recent log lines (from the backend: QML cannot read the journal)
    property int diagCount: 0
    function selfReport() {
        const lines = Diag.recent(8, 24 * 3600 * 1000).map(l =>
            "- " + new Date(l.t).toISOString().slice(0, 16).replace("T", " ") + " UTC: " + l.text);
        return "About Folio itself: version " + (version || "built-in") + (slot ? " (from code/" + slot + ")" : " (the copy built into the app)") +
               "; you run as " + models[modelIndex].label + ", " + efforts[effortIndex].id + " effort. " +
               (lines.length
                   ? "Folio's log on the tablet in the last 24 hours (its errors, versions that failed to load, xochitl crashes), oldest first:\n" + lines.join("\n")
                   : "Folio's log on the tablet has no errors in the last 24 hours.") + "\n" + eraserReport() + "\n\n";
    }

    // the eraser end works only when the native backend reads the digitizer
    function eraserReport() {
        if (!toolReports)
            return "The pen's eraser end: the native backend (backend/entry) has not reported since Folio opened, so the eraser end writes like the tip. It may not be installed (build.sh --install) or not running.";
        if (!rubberReports)
            return "The pen's eraser end: the backend runs, but has not seen the eraser end since Folio opened (it reads /dev/input/event2).";
        return "The pen's eraser end: the backend reports it, and it erases.";
    }

    // the items of the last reply that did not open, and why
    function failedText() {
        const lines = [];
        for (let i = 0; i < items.count; i++) {
            const it = items.get(i);
            if (it.kind === "failed" && it.turn === turns.count - 1)
                lines.push("- c" + i + ": the web page " + it.url + (it.mode === "screenshot" ? " (a screenshot)" : " (reader view)") +
                           " did not open: " + it.failure + ".");
        }
        return lines.length ? "Items of your last reply that failed; the user sees a grey line \"Couldn't open this page\" in their " +
                              "place and nothing else. Tell the user briefly which page and why:\n" + lines.join("\n") + "\n\n" : "";
    }

    // the links the request is about: tapped, or marked by the new ink
    function linkText(links, marks) {
        const lines = (links || []).map(l => (l.tapped ? "The user tapped the link " : "The new ink marks the link ") +
                                             "\"" + l.text + "\" (" + l.href + ") on c" + l.item + ".");
        for (const m of marks || []) lines.push("The new ink is over this text of the web page c" + m.item + ": \"" + m.text + "\"");
        return lines.length ? lines.join("\n") + "\n\n" : "";
    }

    // the request for the ask p: its first message, then the live calls'
    // results so far; with no calls left, only the reply tool
    function requestBody(p) {
        const left = webCalls - p.calls.length;
        const content = p.base.content.slice();
        if (p.calls.length) {
            content.push({ type: "text", text: "Live access. While answering this request you called these tools; their results follow. " +
                "Use them, and cite the sources briefly (site name or short URL). Where a call failed, say that live access failed " +
                "and do not make up what it would have said." });
            p.calls.forEach((c, k) => {
                content.push({ type: "text", text: "[" + (k + 1) + "] " + c.name + "(" + JSON.stringify(c.input || {}) + "):\n" + c.text });
                if (c.image) content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: c.image } });
            });
            content.push({ type: "text", text: left > 0
                ? "You can make " + left + " more live call" + (left > 1 ? "s" : "") + "; do not repeat one. Reply with the reply tool once you have enough."
                : "No live calls are left: reply now with the reply tool." });
        }
        return {
            model: p.base.model,
            output_config: { effort: p.base.effort },
            max_tokens: maxTokens,
            system: p.base.system,
            tools: left > 0 ? [replyTool].concat(webTools) : [replyTool],
            messages: [{ role: "user", content: content }]
        };
    }

    function postJob(p) {
        if (jobPoster) { jobPoster(requestBody(p), p); return; }
        const x = Net.xhr();
        x.timeout = 60000;
        x.onreadystatechange = () => {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            let r = null;
            try { r = JSON.parse(x.responseText); } catch (e) {}
            if (x.status === 202 && r && r.id) {
                p.id = r.id;
                p.tries = 0;
                pending = p;
                savePage();
                askPoll.start();
            } else if (x.status === 0 && !x.responseText && (p.tries || 0) < postTries) {
                // after sleep the tunnel needs a few seconds, and a bridge
                // restart closes its socket for about one
                p.tries = (p.tries || 0) + 1;
                status = "The link to the assistant is not up yet. Trying again (" + p.tries + " of " + postTries + ")…";
                postRetry.p = p;
                postRetry.interval = 2500 * p.tries;
                postRetry.restart();
            } else {
                failed(x.status === 0 && !x.responseText
                    ? "cannot reach the assistant at " + baseUrl + ". The tablet's link to the bridge may still be starting after sleep."
                    : (r && r.error && r.error.message) || ("HTTP " + x.status));
            }
        };
        // a job, not /v1/messages: it keeps running when the app is closed,
        // and pollAsk fetches the answer, also after a reopen (see `pending`)
        x.open("POST", baseUrl + "/v1/jobs");
        x.setRequestHeader("content-type", "application/json");
        x.setRequestHeader("x-api-key", apiKey);
        x.setRequestHeader("anthropic-version", "2023-06-01");
        x.send(JSON.stringify(requestBody(p)));
    }

    // the ask whose answer is being waited for: { id, started, who, ctx,
    // calls (the live calls so far), base (the first request) }
    property var pending: null

    function failed(why) {
        busy = false;
        pending = null;
        askPoll.stop();
        postRetry.stop();
        scheduleSave();
        status = "Failed: " + why + " The ink is kept: ask again.";
    }

    function pollAsk() {
        if (!pending || !pending.id) { askPoll.stop(); return; }
        const p = pending;
        if (Date.now() - p.started > 15 * 60000) { failed("no answer after 15 minutes."); return; }
        const x = Net.xhr();
        x.timeout = 20000;
        x.onreadystatechange = () => {
            if (x.readyState !== XMLHttpRequest.DONE || pending !== p) return;
            let r = null;
            try { r = JSON.parse(x.responseText); } catch (e) {}
            if (x.status === 404) { failed("the answer was lost (the assistant restarted)."); return; }
            if (x.status !== 200 || !r || r.state === "running") return;
            if (r.state === "failed") { failed(r.error || "the assistant failed."); return; }
            answered(r.message, p);
        };
        x.open("GET", baseUrl + "/v1/jobs/" + p.id);
        x.setRequestHeader("x-api-key", apiKey);
        x.send();
    }

    function answered(msg, p) {
        askPoll.stop();
        const uses = (msg && msg.content || []).filter(c => c.type === "tool_use");
        const live = uses.filter(c => webTools.some(t => t.name === c.name));
        if (live.length && !uses.some(c => c.name === "reply")) {
            runLive(live, p);
            return;
        }
        busy = false;
        pending = null;
        const secs = Math.round((Date.now() - p.started) / 1000);
        const cut = !!msg && msg.stop_reason === "max_tokens";
        let ok = false;
        try {
            let input = null;
            for (const c of msg.content || []) {
                if (c.type === "tool_use" && c.name !== "reply" && live.indexOf(c) >= 0) continue;
                if (c.type === "tool_use") input = c.input;
                else if (c.type === "text" && !input && c.text.trim()) input = { heard: "", items: [{ kind: "markdown", content: c.text, place: "below" }] };
            }
            if (!input || (cut && !Array.isArray(input.items) && !input.answer))
                throw cut ? "the answer was cut off at the output limit." : "empty reply";
            if (cut) {
                // the end of the reply is missing: say so where it ends
                input = Object.assign({}, input, { cut: true, items: (Array.isArray(input.items) ? input.items : []).concat([
                    { kind: "markdown", place: "below", content: "*The answer was cut off here: it reached the output limit. Ask for the rest.*" }]) });
            }
            const used = p.calls && p.calls.length ? " · " + p.calls.length + " live call" + (p.calls.length > 1 ? "s" : "") : "";
            status = secs + " s · " + p.who + used + (receive(input, p.ctx) ? " · Folio updated its notes" : "") +
                     (cut ? " · cut off at the output limit" : "");
            ok = true;
        } catch (e) {
            status = "Failed: " + String(e) + " The ink is kept: ask again.";
        }
        scheduleSave();
        // ink written while the assistant was busy; after a failure, only new ink
        // or Ask sends again
        if (ok && sendMode === "pause" && strokeCount > 0) pauseTimer.restart();
    }

    // Runs the assistant's live calls (at most webCalls in all), then asks
    // again with their results.
    function runLive(list, p) {
        pending = p;
        if (!p.calls) p.calls = [];
        const left = Math.max(0, webCalls - p.calls.length);
        const run = list.slice(0, left);
        const results = [];
        let n = run.length;
        const again = () => {
            if (pending !== p) return;
            p.calls = p.calls.concat(run.map((c, k) => ({ name: c.name, input: c.input, text: results[k].text, image: results[k].image })));
            if (p.base) { postJob(p); return; }
            // reopened: the first request is in ask.json
            fileGet(dataDir + "/ask.json", text => {
                try { p.base = JSON.parse(text); } catch (e) {}
                if (p.base && p.base.content) postJob(p);
                else failed("the question was lost while the app was closed.");
            });
        };
        if (!n) { again(); return; }
        status = run.map(c => liveLabel(c)).join(" · ");
        run.forEach((c, k) => runTool(c.name, c.input || {}, res => {
            results[k] = res;
            if (--n === 0) again();
        }));
    }

    function liveLabel(c) {
        const i = c.input || {};
        switch (c.name) {
        case "web_search": return "Searching the web: " + String(i.query || "").slice(0, 60) + "…";
        case "fetch_url": return "Reading " + Net.shortUrl(i.url || "") + "…";
        case "weather": return "Weather for " + String(i.place || "").slice(0, 40) + "…";
        default: return "Taking a screenshot of " + Net.shortUrl(i.url || "") + "…";
        }
    }

    function webGet(url, opts, done) {
        if (fetcher) fetcher(url, opts, done);
        else Net.get(url, opts, done);
    }

    // one live call; done({ text, image }), where text says what failed
    function runTool(name, input, done) {
        const fail = why => done({ text: "ERROR: live access failed: " + why + ".", image: "" });
        const mine = Net.personal(input.query || input.url || input.place || "");
        if (mine) {
            done({ text: "ERROR: not sent: it has " + mine + " in it. Never put the user's personal data in a live call.", image: "" });
            return;
        }
        if (name === "web_search") {
            Net.search(input.query, searchUrl, webGet, (err, text) => err ? fail(err) : done({ text: text, image: "" }));
        } else if (name === "fetch_url") {
            Net.page(input.url, webGet, (err, pg) => err ? fail(err) : done({ text: Net.pageText(pg, webChars), image: "" }));
        } else if (name === "weather") {
            Net.weather(input.place, webGet, (err, text) => err ? fail(err) : done({ text: text, image: "" }));
        } else if (name === "screenshot_url") {
            const url = Net.normalUrl(input.url);
            if (!url) { fail("that is not a web address"); return; }
            // for the assistant only: no file is kept
            greyImage(Net.shotUrl(url, 0, shotService), { w: pageWidth - 2 * margin, h: 1480, timeout: 45000, temporary: true }, r => {
                if (r.error) fail("the screenshot failed: " + r.error);
                else done({ text: "A screenshot of " + url + " (the first screen, greyscale), below. To show it to the user, add a web item with mode screenshot.",
                            image: r.data.replace(/^data:[^,]*,/, "") });
            });
        } else {
            fail("no such tool");
        }
    }

    // ---- web pages on the paper (kind web)

    function imgsOf(it) {
        try { const l = JSON.parse(it.imgs || "[]"); return Array.isArray(l) ? l : []; }
        catch (e) { return []; }
    }

    function imageFile(src) { return dataDir + "/img-" + Net.hash(src) + ".txt"; }

    function webLabel(it) {
        const n = it.parts > 1 ? ", part " + (it.part + 1) + " of " + it.parts : it.part > 0 ? ", part " + (it.part + 1) : "";
        return "web page \"" + it.title + "\", " + it.url + (it.mode === "screenshot" ? ", a screenshot" : ", reader view") + n +
               (it.webState === "more" ? ", with more to continue" : "");
    }

    function failedLabel(it) {
        return "a web page that did not open: " + it.url + (it.mode === "screenshot" ? ", a screenshot" : ", reader view") +
               ", because " + it.failure + "; the user sees only a grey line \"Couldn't open this page\"";
    }

    // a web item that could not be shown: a short grey line in its place;
    // the next request tells the assistant why
    function failedSpec(s, url, why) {
        return { kind: "failed", place: "below", content: "Couldn't open this page" + (url ? " (" + Net.shortUrl(url) + ")" : ""),
                 url: url || String(s.content || "").slice(0, 200), mode: s.mode === "screenshot" ? "screenshot" : "reader",
                 failure: String(why || "it failed") };
    }

    // The web items of a reply, opened: the page fetched and split, its
    // images made grey, before it is placed (a page that grew later would
    // run into what is below it). One at a time, each in its own time: one
    // that fails becomes a failed item and the others go on. done(specs).
    function openPages(specs, done) {
        const out = [];
        const e = epoch;
        let shown = 0;
        const next = k => {
            if (e !== epoch) return;
            if (k >= specs.length) {
                webBusy = false;
                if (status.indexOf("Opening") === 0) status = "";
                done(out);
                return;
            }
            const s = specs[k];
            if (!s || s.kind !== "web") { out.push(s); next(k + 1); return; }
            const url = Net.normalUrl(s.content);
            const where = s.place === "at" ? { place: "at", x: s.x, y: s.y } : { place: "below" };
            if (++shown > maxPages) {
                out.push(Object.assign(failedSpec(s, url, "not opened: the app shows at most " + maxPages + " pages a reply"), where));
                next(k + 1);
                return;
            }
            webBusy = true;
            status = "Opening " + Net.shortUrl(url || String(s.content || "")) + "…";
            // later, not from inside the callback that opened the page
            openPage(s, url, spec => { out.push(Object.assign(spec, where)); Qt.callLater(() => next(k + 1)); });
        };
        next(0);
    }

    // Opens the web item s at url; done(spec) exactly once: the page, or a
    // failed item
    function openPage(s, url, done) {
        const shot = s.mode === "screenshot";
        const ms = shot ? shotTimeout : pageTimeout;
        watchJob(ms, "it did not open within " + Math.round(ms / 1000) + " s", ctl => {
            if (!url) { ctl.fail("that is not a web address"); return; }
            if (Net.personal(url)) { ctl.fail("the address has personal data in it: not opened"); return; }
            if (shot) {
                shotSpec(url, 0, "", ctl.guard(spec => spec ? ctl.end(spec) : ctl.fail("the screenshot is blank")), ctl);
            } else {
                // guarded from the answer on: reading the page is where it can throw
                const fetch = (u, opts, got) => webGet(u, opts, ctl.guard(got));
                Net.page(url, fetch, ctl.guard((err, pg) => {
                    if (err) ctl.fail(err);
                    else readerSpec(pg, pageMarkdown(pg), 0, ctl.guard(ctl.end), ctl);
                }));
            }
        }, spec => done(spec && spec.error ? failedSpec(s, url, spec.error) : spec));
    }

    // Runs start(ctl), a page job that ends with ctl.end(spec) or
    // ctl.fail(why); done(spec, or { error }) comes once, after ms at the
    // latest: then a page whose text is there (ctl.finish) is shown with
    // the pictures made grey so far, and one still loading fails (`late`).
    // An error in the app's own code fails this job only.
    function watchJob(ms, late, start, done) {
        const ctl = { finish: null, over: false };
        const watch = { at: Date.now() + ms, fire: null };
        ctl.end = spec => {
            if (ctl.over) return;
            ctl.over = true;
            opening = opening.filter(w => w !== watch);
            // its pictures still waiting are not made grey
            Net.greyQueue = Net.greyQueue.filter((j, k) => k === 0 || j.opts.owner !== ctl);
            done(spec);
        };
        ctl.fail = why => ctl.end({ error: String(why || "it failed") });
        ctl.guard = f => function () {
            if (ctl.over) return;
            try { f.apply(null, arguments); }
            catch (err) { console.warn("Folio: a page job failed: " + err); ctl.fail("the app could not read it (" + err + ")"); }
        };
        watch.fire = ctl.guard(() => ctl.finish ? ctl.finish() : ctl.fail(late));
        opening.push(watch);
        ctl.guard(start)(ctl);
    }

    // the page jobs running: their deadlines, checked every second (netTimer)
    property var opening: []
    function checkOpening() {
        const now = Date.now();
        for (const w of opening.slice()) if (w.at <= now) w.fire();
    }

    // a page's Markdown as it is kept: at most pageImages images, and cut
    // when very long
    function pageMarkdown(pg) {
        let n = 0;
        let md = pg.markdown.split("\n").filter(line => !/^!\[[^\]]*\]\([^)\s]+\)$/.test(line) || ++n <= pageImages).join("\n");
        if (md.length > 60000) md = md.slice(0, Math.max(0, md.lastIndexOf("\n\n", 60000))) + "\n\n*The page is cut here: it is too long.*";
        return md;
    }

    // the web item for `md` (the page from this part on); done(spec). The
    // pictures are made grey one by one; ctl.finish() ends it with those
    // done so far.
    function readerSpec(pg, md, part, done, ctl) {
        const parts = Markdown.split(md, partChars, partImages);
        const first = parts[0] || "", rest = parts.slice(1).join("\n\n");
        const srcs = Markdown.pieces(first).filter(b => b.img).map(b => b.img);
        const dims = {};
        let over = false;
        const finish = () => {
            if (over) return;
            over = true;
            // an image that could not be loaded is left out
            const content = first.split("\n").filter(line => {
                const m = line.match(/^!\[[^\]]*\]\(([^)\s]+)\)$/);
                return !m || dims[m[1]];
            }).join("\n");
            done({ kind: "web", content: content, url: pg.url, title: pg.title || Net.hostOf(pg.url), site: pg.site || Net.hostOf(pg.url),
                   mode: "reader", part: part, parts: part + Math.max(1, parts.length),
                   imgs: JSON.stringify(srcs.filter(s => dims[s]).map(s => ({ src: s, w: dims[s].w, h: dims[s].h }))),
                   rest: rest, webState: rest ? "more" : "end" });
        };
        if (ctl) ctl.finish = finish;
        const next = k => {
            if (over) return;
            if (k >= srcs.length) { finish(); return; }
            greyImage(srcs[k], { w: pageWidth - 2 * margin, h: 1200, timeout: 20000, owner: ctl }, r => {
                if (!r.error) dims[srcs[k]] = { w: r.w, h: r.h };
                next(k + 1);
            });
        };
        next(0);
    }

    // a screen of a screenshot; done(spec), done({ error }), or done(null)
    // past the end of the page (a blank screen)
    function shotSpec(url, part, title, done, ctl) {
        const src = Net.shotUrl(url, part, shotService);
        greyImage(src, { w: pageWidth - 2 * margin, h: 1480, timeout: 45000, owner: ctl }, r => {
            if (r.error) { done({ error: "the screenshot failed: " + r.error }); return; }
            if (r.blank && part > 0) { done(null); return; }
            const pg = Net.pages[url];
            done({ kind: "web", content: "", url: url, title: title || (pg && pg.title) || Net.hostOf(url),
                   site: (pg && pg.site) || Net.hostOf(url), mode: "screenshot", part: part, parts: 0,
                   imgs: JSON.stringify([{ src: src, w: r.w, h: r.h }]), rest: "",
                   webState: part + 1 < shotParts ? "more" : "end" });
        });
    }

    // the Continue mark of item i: the next part goes below it
    function continueWeb(i) {
        if (i < 0 || i >= items.count || webBusy) return;
        const it = items.get(i);
        if (it.kind !== "web" || it.webState !== "more") return;
        const turn = it.turn, url = it.url, title = it.title, e = epoch;
        webBusy = true;
        status = "Loading more of " + (it.site || Net.hostOf(url)) + "…";
        const after = spec => {
            if (e !== epoch) return;  // a new page meanwhile
            webBusy = false;
            if (!spec) {
                items.setProperty(i, "webState", "end");
                status = "That was the end of the page.";
                savePage();
                return;
            }
            if (spec.error) { status = "Could not load more: " + spec.error + ". Tap Continue to try again."; return; }
            items.setProperty(i, "webState", "continued");
            items.setProperty(i, "rest", "");
            const d = replyItems.itemAt(i);
            if (d) { d.layoutNow(); items.setProperty(i, "ph", d.height); }
            const top = items.get(i);
            const placed = placeItems([Object.assign(spec, { place: "below" })], { regions: Ink.regions(Ink.strokes, 60), newest: null },
                                      turn, { cursor: top.py + top.ph + 28 });
            if (placed.length) page.contentY = Math.max(0, Math.min(page.contentHeight - page.height, items.get(placed[0]).py - 160));
            status = "";
            savePage();
        };
        const shot = it.mode === "screenshot";
        watchJob(shot ? shotTimeout : pageTimeout, "no answer in time", ctl => {
            if (shot) shotSpec(url, it.part + 1, title, ctl.guard(ctl.end), ctl);
            else readerSpec({ url: url, title: title, site: it.site }, it.rest, it.part + 1, ctl.guard(ctl.end), ctl);
        }, after);
    }

    // the web item whose Continue mark the stroke s (a tick) is on, or -1
    function continueAt(s) {
        for (let i = 0; i < items.count; i++) {
            if (items.get(i).webState !== "more") continue;
            const d = replyItems.itemAt(i), b = d && d.markBox();
            if (b && s.x1 > b.x0 - 20 && s.x0 < b.x1 + 20 && s.y1 > b.y0 - 20 && s.y0 < b.y1 + 20) return i;
        }
        return -1;
    }

    function linkTitle(it, href) {
        const re = /\[([^\]]+)\]\(([^)\s]+)\)/g;
        let m;
        while ((m = re.exec(it.content)))
            if (m[2] === href) return m[1].replace(/\\(.)/g, "$1").replace(/[*`]/g, "");
        return Net.shortUrl(href);
    }

    // a finger tap on a link of a web page: the next ask gets it
    function tapLink(i, href) {
        if (!href || i < 0 || i >= items.count) return;
        const text = linkTitle(items.get(i), href);
        chosenLink = { item: i, href: href, text: text };
        status = "Link: “" + text + "” (" + Net.shortUrl(href) + "). Tap Ask to open it, or write what to do with it.";
        if (sendMode === "pause" && !busy) pauseTimer.restart();
    }

    function linksOf(it) {
        try { const l = JSON.parse(it.links || "[]"); return Array.isArray(l) ? l : []; }
        catch (e) { return []; }
    }

    // does the ink region b mark the link box l (page px)? It circles it (the
    // middle of the link is inside), underlines it (a flat mark just below,
    // under most of it) or crosses it
    function marksLink(b, l) {
        const w = l.x1 - l.x0, over = Math.min(b.x1, l.x1) - Math.max(b.x0, l.x0);
        const cx = (l.x0 + l.x1) / 2, cy = (l.y0 + l.y1) / 2;
        if (b.y1 - b.y0 > 24 && cx > b.x0 && cx < b.x1 && cy > b.y0 && cy < b.y1) return true;
        return b.y1 - b.y0 <= 30 && over >= w * 0.5 && b.y0 >= l.y0 + (l.y1 - l.y0) * 0.3 && b.y0 <= l.y1 + 24;
    }

    // the links of web pages that the new ink circles or underlines, from
    // the boxes kept with each page (at most 6)
    function markedLinks(sent) {
        const out = [];
        if (!sent.length) return out;
        const boxes = Ink.regions(sent, 20);
        for (let i = 0; i < items.count; i++) {
            const it = items.get(i);
            if (it.kind !== "web" || it.mode === "screenshot") continue;
            for (const b of boxes) {
                if (b.x1 < it.px || b.x0 > it.px + it.pw || b.y1 < it.py || b.y0 > it.py + it.ph + 34) continue;
                for (const l of linksOf(it)) {
                    const box = { x0: it.px + l.x0, y0: it.py + l.y0, x1: it.px + l.x1, y1: it.py + l.y1 };
                    if (out.length < 6 && !out.some(o => o.href === l.href) && marksLink(b, box))
                        out.push({ item: i, href: l.href, text: linkTitle(it, l.href) });
                }
            }
        }
        return out;
    }

    // the text of web pages under the new ink, for its annotations:
    // [{ item, text }]
    function markedText(sent) {
        const out = [];
        if (!sent.length) return out;
        for (const b of Ink.regions(sent, 20)) {
            for (let i = 0; i < items.count; i++) {
                const it = items.get(i);
                if (it.kind !== "web" || it.mode === "screenshot") continue;
                if (b.x1 < it.px || b.x0 > it.px + it.pw || b.y1 < it.py || b.y0 > it.py + it.ph) continue;
                const d = replyItems.itemAt(i);
                // an underline is below its words
                const t = d ? d.textIn(b.x0, b.y1 - b.y0 <= 30 ? b.y0 - 30 : b.y0, b.x1, b.y1) : "";
                if (t && out.length < 6) out.push({ item: i, text: t.length > 300 ? t.slice(0, 300) + "…" : t });
            }
        }
        return out;
    }

    // a web page's image for the screen: from memory, its file, or made
    // again from the network. "" until it is there (imagesVersion bumps).
    function imageData(src, version) {
        const have = Net.images[src];
        if (have && have.data) return have.data;
        if (!Net.wanted[src]) {
            Net.wanted[src] = true;
            fileGet(imageFile(src), text => {
                let r = null;
                try { r = JSON.parse(text); } catch (e) {}
                if (r && r.data) { Net.images[src] = r; imagesVersion++; }
                else greyImage(src, { w: pageWidth - 2 * margin, h: 1480, timeout: 30000 }, () => {});
            });
        }
        return "";
    }

    // Downloads a picture, scales it to fit opts.w by opts.h and makes it
    // grey, one at a time (greyPad). done({ data (a JPEG data URL), w, h,
    // blank }) or done({ error }).
    function greyImage(src, opts, done) {
        const have = Net.images[src];
        if (have && have.data) { done(have); return; }
        Net.greyQueue.push({ src: src, opts: opts, done: done });
        if (Net.greyQueue.length === 1) nextGrey();
    }

    function nextGrey() {
        const job = Net.greyQueue[0];
        if (!job || greyPad.job) return;
        const have = Net.images[job.src];
        if (have && have.data) { finishGrey(have); return; }
        webGet(job.src, { binary: true, timeout: job.opts.timeout || 20000, max: 3e6 }, (err, r) => {
            if (Net.greyQueue[0] !== job) return;
            if (err) { finishGrey({ error: err }); return; }
            const type = r.type.split(";")[0].trim();
            if (/svg|html|text|json/.test(type) || !r.data || !r.data.byteLength) { finishGrey({ error: "not a picture" }); return; }
            greyPad.start(job, "data:" + (/^image\//.test(type) ? type : "image/jpeg") + ";base64," + Net.base64(r.data));
        });
    }

    function finishGrey(res) {
        const job = Net.greyQueue.shift();
        if (!job) return;
        if (res.data) {
            Net.images[job.src] = res;
            if (!job.opts.temporary) filePut(imageFile(job.src), JSON.stringify(res));
            imagesVersion++;
        }
        job.done(res);
        Qt.callLater(root.nextGrey);
    }

    Timer { id: netTimer; interval: 1000; running: true; repeat: true; onTriggered: { Net.expire(); root.checkOpening(); } }

    // an ask context, saved with the page: strokes as indices into Ink.strokes
    function saveCtx(ctx) {
        const idx = s => Ink.strokes.indexOf(s);
        return {
            sent: ctx.sent.map(idx),
            box: ctx.box,
            newest: ctx.newest,
            lasso: ctx.lasso ? { id: ctx.lasso.id } : null,
            pieces: (ctx.pieces || []).map(p => Object.assign({}, p, { strokes: p.strokes.map(idx) }))
        };
    }

    function loadCtx(c) {
        const ref = i => Ink.strokes[i];
        const ok = s => s !== undefined;
        return {
            sent: (c.sent || []).map(ref).filter(ok),
            regions: Ink.regions(Ink.strokes, 60),
            box: c.box,
            newest: c.newest,
            lasso: c.lasso || null,
            pieces: (c.pieces || []).map(p => Object.assign({}, p, { strokes: (p.strokes || []).map(ref).filter(ok) }))
        };
    }

    Timer { id: askPoll; interval: 3000; repeat: true; onTriggered: root.pollAsk() }
    Timer { id: postRetry; property var p: null; onTriggered: root.postJob(p) }

    // puts a reply on the page; true when the assistant changed its notes
    function receive(input, ctx) {
        const t = turns.count;
        for (const s of ctx.sent) s.turn = t;
        strokeCount = Ink.pending().length;
        const b = ctx.box || { y0: pageBottom, y1: pageBottom };
        turns.append({ heard: String(input.heard || ""), y0: b.y0, y1: b.y1 });
        const specs = Array.isArray(input.items) ? input.items.slice() : [];
        if (input.answer) specs.push({ kind: "markdown", content: input.answer, place: "below" });
        if (input.drawing) specs.push({ kind: "svg", content: input.drawing, place: "below" });
        let change = String(input.app_change || "").trim();
        if (change) {
            const tooLong = change.length > changeChars;
            if (tooLong) change = change.slice(0, changeChars);
            specs.push({ kind: "change", content: change, place: "below",
                         changeNote: tooLong ? "This request is cut off: it is longer than " + changeChars + " characters. Ask for a shorter one before you build it."
                                   : input.cut ? cutNote : !endsWhole(change) ? "This request may be cut off: it ends mid-sentence. Ask again before you build it." : "" });
        }
        const state = { cursor: (ctx.newest ? ctx.newest.y1 : pageBottom) + margin };
        // what comes before the first web item shows at once
        const w = specs.findIndex(s => s && s.kind === "web");
        announce(placeItems(w < 0 ? specs : specs.slice(0, w), ctx, t, state), ctx);
        if (w < 0) dropLasso(ctx);
        else placeLater(specs.slice(w), ctx, t, state.cursor);
        if (ctx.pieces) convertLater(input.typeset, ctx);
        let noted = false;
        const newNotes = String(input.notes || "");
        if (newNotes.trim() && newNotes !== notes) {
            notes = newNotes.slice(0, notesLimit);
            saveNotes();
            noted = true;
        }
        savePage();
        const q = String(input.notes_query || "").trim();
        if (q) askNotes(q, ctx, t);
        return noted;
    }

    // The rest of a reply, from its first web item: placed once its pages
    // are open (or failed). Kept with the page, so a Folio closed meanwhile
    // opens them again.
    property var openingReplies: []
    function placeLater(specs, ctx, t, cursor) {
        const job = { specs: specs, ctx: ctx, turn: t, cursor: cursor };
        openingReplies = openingReplies.concat([job]);
        openPages(specs, list => {
            openingReplies = openingReplies.filter(j => j !== job);
            // the ink written meanwhile is kept clear too
            announce(placeItems(list, ctx, t, { cursor: cursor }), ctx);
            dropLasso(ctx);
            savePage();
        });
    }

    function askNotes(question, ctx, t) {
        status = "Looking in your notes…";
        const x = Net.xhr();
        x.timeout = 330000;
        x.onreadystatechange = () => {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            let r = null;
            try { r = JSON.parse(x.responseText); } catch (e) {}
            if (x.status === 200 && r && r.answer) {
                const placed = placeItems([{ kind: "markdown", content: "**From your notes**\n\n" + r.answer, place: "below" }],
                                          ctx, t, { cursor: (ctx.newest ? ctx.newest.y1 : pageBottom) + margin });
                announce(placed, ctx);
                savePage();
                status = "";
            } else {
                status = "The notes could not be searched: " + (unreachable(x.status) || (r && r.error) || ("HTTP " + x.status));
            }
        };
        x.open("POST", serverUrl + "/v1/notes/ask");
        x.setRequestHeader("x-api-key", serverToken);
        x.setRequestHeader("content-type", "application/json");
        x.send(JSON.stringify({ question: question }));
    }

    // ---- activity: what the agents are doing (the server's jobs and their logs)

    property bool activityOpen: false
    property string activityFrom: "page"   // where Back in Activity goes: "page" or "more"
    property var activityJobs: []     // the server's /v1/jobs, newest first
    property string activityJob: ""   // the job whose log is shown, or ""
    property var activityLines: []    // its log, { n, t, text }
    property string activityError: ""

    function openActivity(job, from) {
        activityFrom = from || "page";
        notesOpen = false;
        activityJob = job;
        activityLines = [];
        activityOpen = true;
        refreshActivity();
    }

    function showJob(job) {
        activityJob = job;
        activityLines = [];
        refreshActivity();
    }

    function activityEntry(id) {
        return activityJobs.find(j => j.id === id) || null;
    }

    function refreshActivity() {
        if (!activityOpen) return;
        server("GET", "/v1/jobs", null, (st, r) => {
            if (st === 200 && Array.isArray(r)) { activityJobs = buildJobs = r; activityError = ""; }
            else activityError = unreachable(st) || (r && r.error) || ("HTTP " + st);
        });
        if (!activityJob) return;
        const job = activityJob;
        const after = activityLines.length ? activityLines[activityLines.length - 1].n : 0;
        server("GET", "/v1/jobs/" + job + "/log?after=" + after, null, (st, r) => {
            if (job !== activityJob) return;
            if (st === 200 && r && Array.isArray(r.lines)) {
                if (r.lines.length) activityLines = activityLines.concat(r.lines).slice(-300);
            } else if (st === 404) {
                activityError = "the server no longer has this job (it restarted).";
            }
        });
    }

    // "3 min", "40 s": for the job list and the log
    function since(t0, t1) {
        const s = Math.max(0, Math.round(((t1 ? new Date(t1) : new Date()) - new Date(t0)) / 1000));
        return s < 120 ? s + " s" : Math.round(s / 60) + " min";
    }

    function jobLabel(j) {
        const what = j.kind === "notes" ? "Notes search" : "Build";
        const state = j.state === "running" ? "running for " + since(j.started)
            : j.state === "done" ? (j.version ? "built " + j.version : "done") + " in " + since(j.started, j.finished)
            : "failed after " + since(j.started, j.finished);
        return what + " · " + state;
    }

    Timer { interval: 4000; repeat: true; running: root.activityOpen; onTriggered: root.refreshActivity() }

    // ---- app changes (a change card on the assistant's layer)

    function setChange(i, fields) {
        for (const k in fields) items.setProperty(i, k, fields[k]);
        savePage();
    }

    // the longest app change kept; the whole of it goes to the server and back
    // to the assistant in the conversation
    readonly property int changeChars: 12000
    readonly property string cutNote: "This request may be cut off: the reply reached the output limit. Ask again before you build it."

    // text that ends as a sentence, a list item or a block does
    function endsWhole(s) {
        return /[.!?:;)\]}"'`*”’»>]$/.test(String(s).trim()) || /\n\s*([-*]|\d+\.)\s[^\n]*$/.test(String(s));
    }

    function changeCut(it) {
        return it.content.length >= changeChars || !endsWhole(it.content) || /cut off/.test(it.changeNote || "");
    }

    // an app change in the conversation, with a warning when it is cut short
    function changeText(it) {
        return "(app change, " + changeLabel(it) + ")\n" + it.content.slice(0, changeChars) +
               (changeCut(it) ? "\n[This app change request is cut short: it ends before it is complete. " +
                                "Say so if the user asks about it, and write it again, complete.]" : "");
    }

    function changeLabel(it) {
        switch (it.changeState) {
        case "building": {
            const j = buildJobs.find(b => b.id === it.changeJob);
            return j && /queued|pending|waiting/.test(j.state) ? "queued" : "building";
        }
        case "ready": return "done: version " + it.changeVersion + " is built, ready to install";
        case "review": return "done: a proposal outside the app (server, bridge or tablet), waiting for a person to review and deploy it";
        case "installed": return "done: version " + it.changeVersion + " is installed";
        case "failed": return "failed: " + shortError(it.changeNote);
        default: return "proposed, not built yet";
        }
    }

    function shortError(s) {
        s = String(s || "").replace(/\s+/g, " ").trim();
        if (s.length <= 200) return s || "no reason given";
        return s.slice(0, Math.max(120, s.lastIndexOf(" ", 200))) + "…";
    }

    // the server's recent jobs, fetched when the user asks and when the
    // activity panel is open: the builds' status for the assistant
    property var buildJobs: []

    function refreshBuilds() {
        server("GET", "/v1/jobs", null, (st, r) => { if (st === 200 && Array.isArray(r)) buildJobs = r; });
    }

    function buildLine(j) {
        const st = String(j.state || "");
        const state = /queued|pending|waiting/.test(st) ? "queued"
            : st === "running" ? "building for " + since(j.started)
            : st === "done" ? "done" + (j.version ? ", built version " + j.version : "") + " in " + since(j.started, j.finished) +
                              (j.finished ? ", " + since(j.finished) + " ago" : "")
            : st === "failed" ? "failed after " + since(j.started, j.finished) + ": " + shortError(j.error || j.summary)
            : st || "unknown";
        const req = String(j.request || "").replace(/\s+/g, " ").trim();
        return state + ": \"" + (req.length > 100 ? req.slice(0, 100) + "…" : req) + "\"";
    }

    // the recent builds of app changes, newest first, for each request
    function buildStatus() {
        const out = [];
        const builds = buildJobs.filter(j => j && j.kind === "build").slice(0, 5);
        builds.forEach(j => {
            let card = -1;
            for (let i = 0; i < items.count; i++) if (items.get(i).changeJob === j.id) card = i;
            out.push("- " + buildLine(j) + (card >= 0 ? " (the change card c" + card + ")" : ""));
        });
        for (let i = items.count - 1; i >= 0 && out.length < 8; i--) {
            const it = items.get(i);
            if (it.kind !== "change" || builds.some(j => j.id === it.changeJob)) continue;
            out.push("- the change card c" + i + ": " + changeLabel(it));
        }
        return out.join("\n");
    }

    function server(method, path, body, done) {
        const x = Net.xhr();
        x.timeout = 30000;
        x.onreadystatechange = () => {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            let r = null;
            try { r = JSON.parse(x.responseText); } catch (e) {}
            done(x.status, r);
        };
        x.open(method, serverUrl + path);
        x.setRequestHeader("x-api-key", serverToken);
        if (body) x.setRequestHeader("content-type", "application/json");
        x.send(body ? JSON.stringify(body) : null);
    }

    function unreachable(status) {
        return status === 0 ? "Cannot reach the server. The tablet's link to it may still be starting." : "";
    }

    function buildChange(i) {
        const t = items.get(i);
        setChange(i, { changeState: "building", changeNote: "Sending the request to the server…" });
        server("POST", "/v1/improve", { request: t.content }, (status, r) => {
            if (status === 202 && r) {
                setChange(i, { changeJob: r.id, changeNote: "The builder is working on it. This takes a few minutes; you can keep writing." });
                changePoll.start();
            } else {
                setChange(i, { changeState: "proposed", changeNote: unreachable(status) || (r && r.error) || ("HTTP " + status) });
            }
        });
    }

    function pollChanges() {
        let waiting = false;
        for (let i = 0; i < items.count; i++) {
            const t = items.get(i);
            if (t.changeState !== "building" || !t.changeJob) continue;
            waiting = true;
            const idx = i;
            server("GET", "/v1/jobs/" + t.changeJob, null, (status, r) => {
                if (status === 200 && r && r.state === "done")
                    setChange(idx, { changeState: r.version ? "ready" : "review", changeVersion: r.version || "", changeNote: r.summary || "" });
                else if (status === 200 && r && r.state === "failed")
                    setChange(idx, { changeState: "failed", changeNote: String(r.error || "").slice(0, 600) });
                else if (status === 404)
                    setChange(idx, { changeState: "failed", changeNote: "The server lost the job (it restarted). Try again." });
            });
        }
        if (!waiting) changePoll.stop();
    }

    // done(error) gets "" once the version is in the free slot and current
    // xochitl keeps each QML file it parsed, or failed to parse, by its path
    // until it restarts, so an install must not reuse a path it may have
    // loaded: rotate through the slots s0..s7 (build.sh makes them, each with
    // a SLOT file, since QML cannot create directories); a and b without them
    readonly property int slotCount: 8
    function readFile(url) {
        try {
            const x = new XMLHttpRequest();
            x.open("GET", url, false);
            x.send();
            return x.responseText.trim();
        } catch (e) {
            return "";
        }
    }
    function nextSlot() {
        const seq = parseInt(readFile(dataDir + "/code/seq")) || 0;
        for (let k = 0; k < slotCount; k++) {
            const n = "s" + ((seq + k) % slotCount);
            if (n !== slot && readFile(dataDir + "/code/" + n + "/SLOT")) {
                filePut(dataDir + "/code/seq", String((seq + k + 1) % slotCount));
                return n;
            }
        }
        return slot === "a" ? "b" : "a";
    }

    function installVersion(v, done) {
        const target = nextSlot();
        server("GET", "/v1/versions/" + v + "/files", null, (status, r) => {
            if (status !== 200 || !r || !r.files || !r.files["main.qml"]) {
                done(unreachable(status) || (r && r.error) || "The version has no main.qml.");
                return;
            }
            for (const name in r.files) {
                if (!/^[A-Za-z0-9._-]+\.(qml|js)$/.test(name)) continue;
                filePut(dataDir + "/code/" + target + "/" + name, r.files[name]);
            }
            filePut(dataDir + "/code/" + target + "/VERSION", v);
            filePut(dataDir + "/code/current", target);
            gc();
            done("");
        });
    }

    function installChange(i) {
        const v = items.get(i).changeVersion;
        setChange(i, { changeNote: "Downloading " + v + "…" });
        installVersion(v, err => setChange(i, err
            ? { changeNote: err }
            : { changeState: "installed", changeNote: "Installed. Close and reopen the app to use " + v + "." }));
    }

    function checkLatest() {
        server("GET", "/v1/versions", null, (status, r) => {
            if (status === 200 && r && r.length) latestVersion = r[r.length - 1].version;
        });
    }

    function useBuiltIn() {
        filePut(dataDir + "/code/current", "");
        gc();
        status = "Close and reopen the app to use the built-in version.";
    }

    Timer {
        id: changePoll
        interval: 10000
        repeat: true
        onTriggered: root.pollChanges()
    }
    Timer { id: saveTimer; interval: 2000; onTriggered: root.savePage() }
    Timer { id: pauseTimer; interval: root.pauseSecs * 1000; onTriggered: root.ask() }
    // back to the grey-faithful screen mode once the pen rests
    Timer { id: inkIdle; interval: 1500; onTriggered: root.inking = false }
    Timer { id: newTimeout; interval: 4000; onTriggered: root.confirmNew = false }
    Timer { id: typingTimer; onTriggered: root.flushTyping() }
    Timer { id: wordTap; interval: 450; onTriggered: root.openFix(root.pendingWord) }
    Timer { id: roomTimer; interval: root.roomDelay; onTriggered: root.makeRoom() }
    NumberAnimation { id: scrollAnim; target: page; property: "contentY"; duration: 400; easing.type: Easing.OutCubic }

    Component.onCompleted: {
        loadConfig();
        loadSettings();
        loadNotes();
        checkLatest();
        refreshBuilds();
        loadPage();
    }
    // also when the app goes without unloading(), as when the loader swaps versions
    Component.onDestruction: Net.closeAll()

    // one of the assistant's items, on the page or in an exported picture of it
    component ReplyItem: Item {
        id: ci
        property int idx: -1
        property string kind
        property string content
        property string place
        property bool small
        property real ph
        property string changeState
        property string changeVersion
        property string changeNote
        property string changeJob
        property string url
        property string title
        property string site
        property string mode
        property int part
        property int parts
        property string imgs
        property string webState
        readonly property bool overlay: place === "over"
        height: kind === "svg" ? ph : kind === "change" ? card.height : kind === "web" ? webCol.height : txt.height

        // a Column places its children at the next polish: placeItems needs
        // the height now
        function layoutNow() {
            if (kind === "web") webCol.forceLayout();
        }
        // the Continue mark, in page px
        function markBox() {
            if (!moreMark.visible) return null;
            const p = moreMark.mapToItem(ci, 0, 0);
            return { x0: x + p.x, y0: y + p.y, x1: x + p.x + moreMark.width, y1: y + p.y + moreMark.height };
        }
        // The links of the page's text with their boxes, in item px: one box
        // a line of a link, [{ href, x0, y0, x1, y1 }]. Kept with the item
        // (`links`), for the ink that circles or underlines a link.
        function scanLinks() {
            const out = [];
            if (kind !== "web" || mode === "screenshot") return out;
            for (let k = 0; k < webBlocks.count; k++) {
                const b = webBlocks.itemAt(k);
                if (!b || !b.text || !b.hasLinks) continue;
                const t = b.text, o = b.mapToItem(ci, 0, 0);
                let cur = null, r = t.positionToRectangle(0);
                for (let i = 0; i < t.length; i++) {
                    const n = t.positionToRectangle(i + 1);
                    // a character is from its cursor place to the next, on one line
                    const href = Math.abs(n.y - r.y) < 1 && n.x > r.x ? t.linkAt((r.x + n.x) / 2, r.y + r.height / 2) : "";
                    if (cur && href === cur.href && Math.abs(o.y + r.y - cur.y0) < 1) {
                        cur.x1 = o.x + n.x;
                    } else {
                        if (cur) out.push(cur);
                        cur = href ? { href: href, x0: o.x + r.x, y0: o.y + r.y, x1: o.x + n.x, y1: o.y + r.y + r.height } : null;
                    }
                    r = n;
                }
                if (cur) out.push(cur);
            }
            return out.map(l => ({ href: l.href, x0: Math.round(l.x0), y0: Math.round(l.y0), x1: Math.round(l.x1), y1: Math.round(l.y1) }));
        }
        // the page's text under the box (page px): what the ink marks
        function textIn(x0, y0, x1, y1) {
            const out = [];
            for (let k = 0; k < webBlocks.count; k++) {
                const b = webBlocks.itemAt(k);
                if (!b || !b.text) continue;
                const p = b.mapToItem(ci, 0, 0), bx = x + p.x, by = y + p.y;
                if (x1 < bx || x0 > bx + b.width || y1 < by || y0 > by + b.height) continue;
                const t = b.text;
                const a = t.positionAt(Math.max(0, x0 - bx), Math.max(0, y0 - by));
                const z = t.positionAt(Math.min(b.width, x1 - bx), Math.min(b.height - 1, y1 - by));
                // the frame marks of tables are characters of their own
                const s = t.getText(Math.min(a, z), Math.max(a, z)).split(String.fromCharCode(0xfdd0)).join(" ")
                    .split(String.fromCharCode(0xfdd1)).join(" ").replace(/\s+/g, " ").trim();
                if (s) out.push(s);
            }
            return out.join(" … ");
        }
        readonly property var dims: {
            const d = {};
            if (kind === "web") for (const im of root.imgsOf({ imgs: imgs })) d[im.src] = im;
            return d;
        }

        // a web page: its title and source, then its text and pictures
        Column {
            id: webCol
            visible: ci.kind === "web"
            width: parent.width
            spacing: 14
            Text {
                width: parent.width
                text: ci.title + (ci.part > 0 ? " (continued)" : "")
                font.pixelSize: ci.part > 0 ? 26 : 34
                font.bold: true
                wrapMode: Text.Wrap
                color: "#333333"
            }
            Text {
                width: parent.width
                text: (ci.site && ci.site !== Net.hostOf(ci.url) ? ci.site + " · " : "") + Net.shortUrl(ci.url) +
                      (ci.mode === "screenshot" ? " · screenshot" : "") +
                      (ci.parts > 1 ? " · part " + (ci.part + 1) + " of " + ci.parts : ci.part > 0 ? " · part " + (ci.part + 1) : "")
                font.pixelSize: 22
                elide: Text.ElideRight
                color: "#555555"
            }
            Rectangle { width: parent.width; height: 2; color: "#999999" }
            Repeater {
                id: webBlocks
                model: ci.kind === "web" ? (ci.mode === "screenshot" ? root.imgsOf({ imgs: ci.imgs }).map(im => ({ md: "", img: im.src, alt: "" }))
                                                                    : Markdown.pieces(ci.content)) : []
                Item {
                    readonly property var text: modelData.img ? null : blockText
                    readonly property bool hasLinks: !modelData.img && modelData.md.indexOf("](") >= 0
                    readonly property var size: modelData.img ? ci.dims[modelData.img] || { w: 0, h: 0 } : null
                    width: webCol.width
                    height: modelData.img ? pic.height : blockText.height
                    // a TextEdit, not a Text: it tells where each character
                    // is (link boxes, the text under the ink). Disabled: it
                    // takes no input, the page's pen and fingers stay as they are
                    TextEdit {
                        id: blockText
                        visible: !modelData.img
                        enabled: false
                        readOnly: true
                        selectByMouse: false
                        activeFocusOnPress: false
                        width: parent.width
                        text: modelData.img ? "" : Markdown.toHtml(modelData.md, true)
                        textFormat: TextEdit.RichText
                        wrapMode: TextEdit.Wrap
                        font.pixelSize: 28
                        color: "#333333"
                    }
                    // a finger on a link chooses it; elsewhere the page scrolls
                    MouseArea {
                        anchors.fill: blockText
                        enabled: !modelData.img
                        onPressed: mouse => mouse.accepted = mouse.source !== Qt.MouseEventNotSynthesized && !root.erasingTool
                                                              && blockText.linkAt(mouse.x, mouse.y) !== ""
                        onClicked: mouse => root.tapLink(ci.idx, blockText.linkAt(mouse.x, mouse.y))
                    }
                    Rectangle {
                        id: pic
                        visible: !!modelData.img
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: size ? Math.min(parent.width, size.w) : 0
                        height: size && size.w ? width * size.h / size.w : 0
                        color: "white"
                        border.color: shot.status === Image.Ready ? "#dddddd" : "#999999"
                        border.width: 1
                        Image {
                            id: shot
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectFit
                            // off screen, the picture is let go
                            source: modelData.img && ci.visible ? root.imageData(modelData.img, root.imagesVersion) : ""
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: shot.status !== Image.Ready
                            text: modelData.alt || "picture"
                            font.pixelSize: 22
                            color: "#777777"
                        }
                    }
                }
            }
            Rectangle {
                id: moreMark
                objectName: "continueMark"
                visible: ci.webState === "more"
                width: moreText.implicitWidth + 60
                height: visible ? 76 : 0
                radius: 12
                color: "white"
                border.color: "black"
                border.width: 2
                Text {
                    id: moreText
                    anchors.centerIn: parent
                    text: root.webBusy ? "Loading…" : "Continue: tick or tap here"
                    font.pixelSize: 26
                }
                MouseArea {
                    anchors.fill: parent
                    onPressed: mouse => mouse.accepted = mouse.source !== Qt.MouseEventNotSynthesized && !root.erasingTool
                    onClicked: root.continueWeb(ci.idx)
                }
            }
            Text {
                visible: ci.webState === "continued" || ci.webState === "end"
                text: ci.webState === "continued" ? "Continued below" : "End of the page"
                font.pixelSize: 22
                font.italic: true
                color: "#555555"
            }
        }

        Text {
            id: txt
            visible: ci.kind === "markdown" || ci.kind === "failed"
            width: parent.width
            // a page that did not open: a short grey line
            text: ci.kind === "markdown" ? Markdown.toHtml(ci.content) : ci.kind === "failed" ? ci.content : ""
            textFormat: ci.kind === "failed" ? Text.PlainText : Text.RichText
            wrapMode: Text.Wrap
            font.pixelSize: ci.kind === "failed" ? 22 : ci.small ? 24 : 30
            font.italic: ci.kind === "failed"
            color: ci.kind === "failed" ? "#888888" : "#555555"
            opacity: ci.overlay ? 0.7 : 1
        }
        Image {
            visible: ci.kind === "svg"
            anchors.fill: parent
            fillMode: ci.overlay ? Image.Stretch : Image.PreserveAspectFit
            sourceSize.width: width
            sourceSize.height: height
            opacity: ci.overlay ? 0.45 : 0.6
            source: ci.kind === "svg" ? "data:image/svg+xml;utf8," + encodeURIComponent(ci.content) : ""
        }
        Rectangle {
            id: card
            visible: ci.kind === "change"
            width: parent.width
            height: ci.kind === "change" ? changeCol.height + 36 : 0
            color: "white"
            border.color: "#555555"
            border.width: 2
            radius: 12
            Column {
                id: changeCol
                x: 18
                y: 18
                width: parent.width - 36
                spacing: 12
                Text {
                    width: parent.width
                    text: {
                        switch (ci.changeState) {
                        case "building": return "Building this change to the app";
                        case "ready": return "Version " + ci.changeVersion + " is ready";
                        case "review": return "Built: waiting for a person to review it";
                        case "installed": return "Version " + ci.changeVersion + " is installed";
                        case "failed": return "The change could not be built";
                        default: return "Proposed change to the app";
                        }
                    }
                    font.pixelSize: 26
                    font.bold: true
                    wrapMode: Text.Wrap
                    color: "#333333"
                }
                Text {
                    width: parent.width
                    text: ci.content
                    font.pixelSize: 24
                    wrapMode: Text.Wrap
                    color: "#555555"
                }
                Text {
                    width: parent.width
                    visible: ci.changeNote !== ""
                    text: ci.changeNote
                    font.pixelSize: 22
                    font.italic: true
                    wrapMode: Text.Wrap
                    color: "#555555"
                }
                Button {
                    visible: ci.changeState === "proposed" || ci.changeState === "failed"
                    label: ci.changeState === "failed" ? "Try again" : "Build it"
                    onClicked: root.buildChange(ci.idx)
                }
                Button {
                    visible: ci.changeState === "building" && ci.changeJob !== ""
                    label: "Show progress"
                    onClicked: root.openActivity(ci.changeJob)
                }
                Button {
                    visible: ci.changeState === "ready"
                    label: "Install " + ci.changeVersion
                    primary: true
                    onClicked: root.installChange(ci.idx)
                }
            }
        }
    }

    // The toolbar: one slim row of large buttons at the top, nothing at the
    // bottom, where the palm rests. Only what the pen hand needs while writing;
    // the rest is in More. Close stands apart, so a slip from More does not
    // close the app.
    Item {
        id: topBar
        objectName: "toolbar"
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: root.barShown ? root.barHeight : 0
        visible: root.barShown

        Row {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            spacing: 8
            BarButton { width: root.barCell;
                id: askButton
                objectName: "askButton"
                label: root.busy ? "…" : "Ask"
                primary: true
                enabledState: (root.strokeCount > 0 || root.chosenLink !== null) && !root.busy
                onClicked: root.ask()
            }
            BarButton { width: root.barCell; objectName: "undoButton"; label: "Undo"; enabledState: !root.busy; onClicked: root.undoStroke() }
            BarButton { width: root.barCell;
                objectName: "eraserButton"
                label: "Erase"
                primary: root.erasingTool
                onClicked: { root.eraser = !root.eraser; if (root.eraser) root.lassoMode = false; }
            }
            BarButton { width: root.barCell;
                objectName: "lassoButton"
                label: "Lasso"
                primary: root.lassoMode
                onClicked: root.toggleLasso()
            }
            BarButton { width: root.barCell;
                objectName: "moreButton"
                label: "More"
                primary: root.notesOpen
                onClicked: { root.confirmClearNotes = false; root.confirmNew = false; root.notesOpen = !root.notesOpen; }
            }
        }
        BarButton { width: root.barCell;
            id: closeButton
            objectName: "closeButton"
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            label: ""
            onClicked: root.close()
            // the tablet's fonts have no ✕
            Repeater {
                model: [45, -45]
                Rectangle {
                    anchors.centerIn: parent
                    width: 30
                    height: 4
                    radius: 2
                    rotation: modelData
                    color: "black"
                }
            }
        }
        Rectangle { anchors { bottom: parent.bottom; left: parent.left; right: parent.right } height: 2; color: "black" }
    }

    // the hidden toolbar's tab: a small flap at the top edge
    Rectangle {
        id: barTab
        objectName: "barTab"
        visible: !root.barShown
        anchors { right: parent.right; rightMargin: 36 }
        y: -16
        width: 120
        height: 60
        radius: 16
        color: "white"
        border.color: "black"
        border.width: 2
        z: 8
        Canvas {
            x: (parent.width - width) / 2
            y: 16 + (44 - height) / 2
            width: 40
            height: 20
            onPaint: {
                const ctx = getContext("2d");
                ctx.strokeStyle = "black";
                ctx.lineWidth = 4;
                ctx.lineCap = "round";
                ctx.lineJoin = "round";
                ctx.beginPath();
                ctx.moveTo(4, 4); ctx.lineTo(20, 16); ctx.lineTo(36, 4);
                ctx.stroke();
            }
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -14
            onClicked: root.setBar(true)
        }
    }

    Flickable {
        id: page
        objectName: "page"
        anchors { top: topBar.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        clip: true
        contentWidth: width
        contentHeight: Math.max(height, root.pageBottom + height * 0.75)
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        onContentYChanged: if (markers.count) root.checkMarkers()

        Item {
            id: replyLayer
            objectName: "replyLayer"
            width: page.contentWidth
            height: page.contentHeight
            visible: root.layers !== "user"

            Repeater {
                id: replyItems
                model: items
                ReplyItem {
                    idx: index
                    x: model.px
                    y: model.py
                    width: model.pw
                    kind: model.kind
                    content: model.content
                    place: model.place
                    small: model.small
                    ph: model.ph
                    changeState: model.changeState
                    changeVersion: model.changeVersion
                    changeNote: model.changeNote
                    changeJob: model.changeJob || ""
                    url: model.url
                    title: model.title
                    site: model.site
                    mode: model.mode
                    part: model.part
                    parts: model.parts
                    imgs: model.imgs
                    webState: model.webState
                    visible: y + height > page.contentY - 400 && y < page.contentY + page.height + 400
                    onHeightChanged: if (kind !== "svg" && height > 0 && Math.abs(height - model.ph) > 1) {
                        items.setProperty(index, "ph", height);
                        root.updateBottom();
                    }
                }
            }
        }

        // The user layer. Tiles, not one Canvas: the software renderer redraws
        // a whole Canvas image every frame, so a pad-sized one held frames at
        // ~45 ms. 128 px tiles repaint only where the pen is, at ~6 ms a
        // frame. The tiles cover the screen, not the page: a tile row that
        // scrolls out comes back in on the other side and repaints.
        Item {
            id: inkLayer
            objectName: "inkLayer"
            width: page.contentWidth
            height: page.contentHeight
            visible: root.layers !== "replies"
            readonly property int tile: Ink.ROW
            readonly property int cols: Math.ceil(width / tile)
            readonly property int band: Math.ceil(page.height / tile) + 1
            readonly property int first: Math.max(0, Math.floor(page.contentY / tile))

            function tileAt(row, col) {
                const t = tiles.itemAt((row % band) * cols + col);
                return t && t.row === row ? t : null;
            }

            function route(seg) {
                const [a, b] = seg, m = 4;
                const x0 = Math.max(0, Math.floor((Math.min(a.x, b.x) - m) / tile));
                const x1 = Math.min(cols - 1, Math.floor((Math.max(a.x, b.x) + m) / tile));
                const y0 = Math.max(0, Math.floor((Math.min(a.y, b.y) - m) / tile));
                const y1 = Math.floor((Math.max(a.y, b.y) + m) / tile);
                for (let ty = y0; ty <= y1; ty++)
                    for (let tx = x0; tx <= x1; tx++) {
                        const t = tileAt(ty, tx);
                        if (t) t.add(seg);
                    }
            }

            function redrawBox(b) {
                if (!b) return;
                for (let ty = Math.max(0, Math.floor((b.y0 - 4) / tile)); ty <= Math.floor((b.y1 + 4) / tile); ty++)
                    for (let tx = Math.max(0, Math.floor((b.x0 - 4) / tile)); tx <= Math.min(cols - 1, Math.floor((b.x1 + 4) / tile)); tx++) {
                        const t = tileAt(ty, tx);
                        if (t) t.redraw();
                    }
            }

            function redrawAll() {
                for (let i = 0; i < tiles.count; i++) tiles.itemAt(i).redraw();
            }

            Repeater {
                id: tiles
                model: inkLayer.cols * inkLayer.band
                Canvas {
                    readonly property int slot: Math.floor(index / inkLayer.cols)
                    readonly property int row: inkLayer.first + ((slot - inkLayer.first) % inkLayer.band + inkLayer.band) % inkLayer.band
                    x: (index % inkLayer.cols) * inkLayer.tile
                    y: row * inkLayer.tile
                    width: inkLayer.tile
                    height: inkLayer.tile
                    renderStrategy: Canvas.Immediate
                    renderTarget: Canvas.Image
                    property var segs: []
                    property bool full: true
                    onRowChanged: redraw()

                    function add(seg) {
                        segs = segs.concat([seg]);
                        requestPaint();
                    }
                    function redraw() {
                        full = true;
                        segs = [];
                        requestPaint();
                    }

                    onPaint: {
                        const ctx = getContext("2d");
                        if (full) {
                            full = false;
                            ctx.clearRect(0, 0, width, height);
                            root.drawStrokes(ctx, root.shown(Ink.inRow(row)), x, y);
                            root.drawLoop(ctx, Ink.lasso, x, y, width, height);
                            root.drawLoop(ctx, Ink.loop, x, y, width, height);
                        } else {
                            // ink, and the dashes of a lasso being drawn
                            for (const dashed of [false, true]) {
                                const list = segs.filter(s => !!s[2] === dashed);
                                if (!list.length) continue;
                                if (dashed) root.lassoStyle(ctx);
                                else root.inkStyle(ctx);
                                ctx.beginPath();
                                for (const [a, b] of list) {
                                    ctx.moveTo(a.x - x, a.y - y);
                                    ctx.lineTo(b.x - x, b.y - y);
                                }
                                ctx.stroke();
                            }
                        }
                        segs = [];
                    }
                }
            }

            // the handwriting the assistant read, as type over its (hidden) ink. A
            // finger tap on a word opens the pad to write it again.
            Repeater {
                id: typedWords
                model: typed
                TypedWord {
                    objectName: "typedWord"
                    wx: model.x
                    wy: model.y
                    ww: model.w
                    wh: model.h
                    size: model.size
                    text: model.text
                    visible: root.showType && model.alive && y + height > page.contentY - 200 && y < page.contentY + page.height + 200
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -6
                        visible: root.fixIndex === index
                        color: "transparent"
                        border.color: "black"
                        border.width: 2
                        radius: 6
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -8
                        onPressed: mouse => mouse.accepted = mouse.source !== Qt.MouseEventNotSynthesized && !root.erasingTool
                        onClicked: root.tapWord(index)
                    }
                }
            }
        }

        Text {
            objectName: "padHint"
            x: root.margin
            width: page.width - 2 * root.margin
            y: root.pageBottom > 0 ? root.pageBottom + 120 : page.height / 2 - 30
            horizontalAlignment: Text.AlignHCenter
            visible: root.strokeCount === 0 && !root.busy
            text: "Write here with the pen"
            font.pixelSize: 36
            color: "#bbbbbb"
        }

        // xochitl delivers the pen as a plain mouse, with no pressure and no
        // eraser. A PointHandler (passive grab) gets the press but no moves.
        // Touch arrives synthesized: it scrolls the page and taps the buttons.
        MouseArea {
            id: pen
            width: page.contentWidth
            height: page.contentHeight
            preventStealing: true
            onPressed: mouse => {
                if (mouse.source !== Qt.MouseEventNotSynthesized) {
                    root.fingerTap(mouse.x, mouse.y);
                    mouse.accepted = false;
                    return;
                }
                root.penDown(mouse.x, mouse.y);
            }
            onPositionChanged: mouse => root.penMove(mouse.x, mouse.y)
            onReleased: root.penUp()
            onCanceled: root.penUp()
        }
    }

    // UFast is xochitl's Pen screen mode, the one notebooks write in; Fast is
    // Mono, a slower waveform. Content keeps the assistant's greys while reading.
    DisplayMethodArea {
        anchors.fill: page
        displayMethod: root.inking ? DisplayMethodArea.UFast : DisplayMethodArea.Content
    }

    Rectangle {
        id: statusStrip
        objectName: "statusStrip"
        // at the top, under the toolbar: the bottom of the page is for writing
        anchors { left: page.left; right: page.right; top: page.top }
        height: visible ? statusText.height + 16 : 0
        visible: root.status !== "" && !root.notesOpen
        color: "white"
        Rectangle { anchors { bottom: parent.bottom; left: parent.left; right: parent.right } height: 1; color: "#bbbbbb" }
        Text {
            id: statusText
            anchors { left: parent.left; right: parent.right; leftMargin: 36; verticalCenter: parent.verticalCenter }
            // beside the tab of the hidden toolbar
            anchors.rightMargin: root.barShown ? 36 : 36 + barTab.width + 16
            text: root.status
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.pixelSize: 24
            font.bold: root.status.indexOf("Failed") === 0
            color: root.status.indexOf("Failed") === 0 ? "black" : "#444444"
        }
    }

    // the assistant placed something off screen: tap to go there
    Rectangle {
        id: marker
        objectName: "marker"
        anchors { horizontalCenter: page.horizontalCenter; top: statusStrip.bottom; topMargin: 16 }
        visible: markers.count > 0 && !root.notesOpen
        width: markerRow.width + 56
        height: 64
        radius: 32
        color: "white"
        border.color: "black"
        border.width: 2
        property bool up: markers.count > 0 && markers.get(markers.count - 1).up
        Row {
            id: markerRow
            anchors.centerIn: parent
            spacing: 12
            Canvas {
                width: 24
                height: 30
                anchors.verticalCenter: parent.verticalCenter
                rotation: marker.up ? 0 : 180
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.strokeStyle = "black";
                    ctx.lineWidth = 3;
                    ctx.lineCap = "round";
                    ctx.beginPath();
                    ctx.moveTo(12, 28); ctx.lineTo(12, 3);
                    ctx.moveTo(3, 12); ctx.lineTo(12, 3); ctx.lineTo(21, 12);
                    ctx.stroke();
                }
            }
            Text {
                objectName: "markerText"
                anchors.verticalCenter: parent.verticalCenter
                text: markers.count > 0 ? root.markerLabel(markers.count - 1) : ""
                font.pixelSize: 26
            }
        }
        MouseArea { anchors.fill: parent; anchors.margins: -10; onClicked: root.goToMarker() }
    }

    // back to the newest part of the page, only while it is off screen
    Rectangle {
        id: latestButton
        objectName: "latestButton"
        anchors { right: page.right; top: statusStrip.bottom; topMargin: 16 }
        // beside the tab of the hidden toolbar
        anchors.rightMargin: root.barShown ? 36 : 36 + barTab.width + 16
        // the marker already leads down to a new reply
        visible: !root.notesOpen && !root.activityOpen && !(marker.visible && !marker.up) && root.pageBottom > page.contentY + page.height
        width: latestText.implicitWidth + 64
        height: 64
        radius: 32
        color: "white"
        border.color: "black"
        border.width: 2
        z: 4
        Text {
            id: latestText
            anchors.centerIn: parent
            text: "Latest"
            font.pixelSize: 26
        }
        MouseArea { anchors.fill: parent; anchors.margins: -10; onClicked: root.jumpToLatest() }
    }

    // More: everything that is not needed while writing, one section per
    // row, each with its title on the left. Close at the top right, as in
    // Activity; New page far from it and behind a confirm.
    component SheetTitle: Text {
        width: 250
        font.pixelSize: 30
        font.bold: true
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    }
    component SheetHelp: Text {
        width: notesPanel.width - 72
        wrapMode: Text.Wrap
        font.pixelSize: 24
        color: "#444444"
    }
    component SheetRule: Rectangle { width: notesPanel.width - 72; height: 1; color: "#bbbbbb" }

    Rectangle {
        id: notesPanel
        objectName: "morePanel"
        anchors.fill: page
        visible: root.notesOpen
        color: "white"
        z: 5
        MouseArea { anchors.fill: parent; z: -1 }

        Text {
            id: moreTitle
            anchors { top: parent.top; topMargin: 36; left: parent.left; leftMargin: 36 }
            text: "More"
            font.pixelSize: 38
            font.bold: true
        }
        Button {
            objectName: "moreClose"
            anchors { verticalCenter: moreTitle.verticalCenter; right: parent.right; rightMargin: 36 }
            label: "Close"
            onClicked: root.notesOpen = false
        }

        Column {
            id: sheet
            anchors { top: moreTitle.bottom; topMargin: 36; left: parent.left; leftMargin: 36; right: parent.right; rightMargin: 36 }
            spacing: 22

            Row {
                spacing: 14
                SheetTitle { text: "Page" }
                Button {
                    objectName: "newButton"
                    label: root.confirmNew ? "Tap again: clear the page" : "New page"
                    primary: root.confirmNew
                    enabledState: !root.busy
                    onClicked: {
                        if (!root.confirmNew) { root.confirmNew = true; newTimeout.restart(); return; }
                        root.confirmNew = false;
                        root.notesOpen = false;
                        root.newPage();
                    }
                }
                Button {
                    objectName: "hideButton"
                    label: "Hide toolbar"
                    onClicked: { root.notesOpen = false; root.setBar(false); }
                }
            }
            SheetRule {}

            Row {
                objectName: "viewPanel"
                spacing: 14
                SheetTitle { text: "Show" }
                Column {
                    spacing: 14
                    Button {
                        objectName: "userLayerButton"
                        width: 420
                        label: "Your writing: " + (root.layers !== "replies" ? "shown" : "hidden")
                        onClicked: root.toggleUserLayer()
                    }
                    Button {
                        objectName: "replyLayerButton"
                        width: 420
                        label: "Replies: " + (root.layers !== "user" ? "shown" : "hidden")
                        onClicked: root.toggleReplyLayer()
                    }
                    Button {
                        objectName: "typeButton"
                        width: 420
                        label: "Your text: " + (root.showType ? "typed" : "as written")
                        onClicked: root.setShowType(!root.showType)
                    }
                }
            }
            SheetHelp { text: root.showType ? "Tap a typed word with a finger to correct it." : "Your ink as you wrote it." }
            SheetRule {}

            Row {
                spacing: 14
                SheetTitle { text: "Assistant" }
                Button {
                    objectName: "modelButton"
                    label: root.models[root.modelIndex].label
                    enabledState: !root.busy
                    onClicked: { root.modelIndex = (root.modelIndex + 1) % root.models.length; root.saveSettings(); }
                }
                Button {
                    objectName: "effortButton"
                    label: root.efforts[root.effortIndex].label
                    enabledState: !root.busy
                    onClicked: { root.effortIndex = (root.effortIndex + 1) % root.efforts.length; root.saveSettings(); }
                }
            }
            Row {
                id: sendRow
                spacing: 14
                SheetTitle { text: "Send with" }
                Button {
                    objectName: "sendModeButton"
                    label: root.sendModes.find(m => m.id === root.sendMode).label
                    onClicked: {
                        const i = root.sendModes.findIndex(m => m.id === root.sendMode);
                        root.sendMode = root.sendModes[(i + 1) % root.sendModes.length].id;
                        root.saveSettings();
                    }
                }
                Button {
                    visible: root.sendMode === "pause"
                    label: root.pauseSecs + " s"
                    onClicked: {
                        const i = root.pauseChoices.indexOf(root.pauseSecs);
                        root.pauseSecs = root.pauseChoices[(i + 1) % root.pauseChoices.length];
                        root.saveSettings();
                    }
                }
            }
            SheetHelp { text: root.sendModes.find(m => m.id === root.sendMode).help + " The Ask button always works." }
            SheetRule {}

            Row {
                spacing: 14
                SheetTitle { text: "Agents" }
                Button {
                    objectName: "activityButton"
                    label: "Activity"
                    onClicked: root.openActivity("", "more")
                }
            }
            SheetRule {}

            Row {
                id: notesHead
                spacing: 14
                SheetTitle { text: "Folio's notes" }
                Button {
                    label: root.confirmClearNotes ? "Tap again: clear them" : "Clear notes"
                    primary: root.confirmClearNotes
                    enabledState: root.notes !== "" && !root.busy
                    onClicked: {
                        if (!root.confirmClearNotes) { root.confirmClearNotes = true; return; }
                        root.notes = "";
                        root.saveNotes();
                        root.confirmClearNotes = false;
                    }
                }
            }
        }

        Flickable {
            anchors { top: sheet.bottom; topMargin: 18; left: parent.left; right: parent.right; bottom: versionRule.top; bottomMargin: 16 }
            contentHeight: notesText.height + 40
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Text {
                id: notesText
                x: 36
                width: parent.width - 72
                wrapMode: Text.Wrap
                font.pixelSize: 28
                textFormat: root.notes ? Text.RichText : Text.PlainText
                color: root.notes ? "black" : "#666666"
                text: root.notes
                    ? Markdown.toHtml(root.notes)
                    : "No notes yet. Folio writes notes here when it learns how you like answers, or facts you ask it to keep. They go into every request."
            }
        }

        Rectangle {
            id: versionRule
            anchors { bottom: versionRow.top; bottomMargin: 20; left: parent.left; right: parent.right; leftMargin: 36; rightMargin: 36 }
            height: 1
            color: "#bbbbbb"
        }
        Row {
            id: versionRow
            anchors { bottom: parent.bottom; bottomMargin: 28; left: parent.left; leftMargin: 36 }
            spacing: 20
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "App version: " + (root.version || "built-in")
                font.pixelSize: 26
                color: "#444444"
            }
            Button {
                visible: root.latestVersion !== "" && root.latestVersion !== root.version
                label: "Install " + root.latestVersion
                primary: true
                onClicked: root.installVersion(root.latestVersion, err => {
                    root.status = err || ("Installed " + root.latestVersion + ". Close and reopen the app to use it.");
                })
            }
            Button {
                visible: root.slot !== ""
                label: "Use built-in"
                onClicked: root.useBuiltIn()
            }
        }
    }

    // what the agents are doing: the server's builds and notes searches, and the
    // log of one of them
    Rectangle {
        id: activityPanel
        objectName: "activityPanel"
        anchors.fill: page
        visible: root.activityOpen
        color: "white"
        z: 7
        MouseArea { anchors.fill: parent }

        readonly property var entry: root.activityJob ? root.activityEntry(root.activityJob) : null

        Row {
            id: actTitle
            anchors { top: parent.top; topMargin: 24; left: parent.left; leftMargin: 36 }
            spacing: 24
            BackButton {
                objectName: "allJobsButton"
                visible: root.activityJob !== ""
                label: "All jobs"
                onClicked: root.showJob("")
            }
            BackButton {
                objectName: "backToMore"
                visible: root.activityJob === "" && root.activityFrom === "more"
                label: "More"
                onClicked: { root.activityOpen = false; root.notesOpen = true; }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.activityJob !== "" ? "Job" : "Activity"
                font.pixelSize: 38
                font.bold: true
            }
        }
        Button {
            objectName: "activityClose"
            anchors { verticalCenter: actTitle.verticalCenter; right: parent.right; rightMargin: 36 }
            label: "Close"
            onClicked: { root.activityOpen = false; root.notesOpen = false; }
        }
        Column {
            id: actHead
            anchors { top: actTitle.bottom; topMargin: 24; left: parent.left; leftMargin: 36; right: parent.right; rightMargin: 36 }
            spacing: 10
            Text {
                width: parent.width
                visible: root.pending !== null
                text: root.pending ? "Your question: waiting for the answer, " + root.since(root.pending.started) + " (" + root.pending.who + ")" : ""
                wrapMode: Text.Wrap
                font.pixelSize: 24
            }
            Text {
                width: parent.width
                visible: root.activityError !== ""
                text: "Cannot read the server's jobs: " + root.activityError
                wrapMode: Text.Wrap
                font.pixelSize: 22
                font.italic: true
                color: "#555555"
            }
            Text {
                width: parent.width
                visible: activityPanel.entry !== null
                text: activityPanel.entry ? root.jobLabel(activityPanel.entry) : ""
                font.pixelSize: 26
                font.bold: true
            }
            Text {
                width: parent.width
                visible: activityPanel.entry !== null
                text: activityPanel.entry ? activityPanel.entry.request : ""
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                font.pixelSize: 22
                color: "#444444"
            }
            Rectangle { width: parent.width; height: 1; color: "#bbbbbb" }
        }

        ListView {
            id: jobList
            objectName: "jobList"
            visible: root.activityJob === ""
            anchors { top: actHead.bottom; topMargin: 12; left: parent.left; leftMargin: 36; right: parent.right; rightMargin: 36; bottom: parent.bottom; bottomMargin: 24 }
            clip: true
            spacing: 12
            boundsBehavior: Flickable.StopAtBounds
            model: root.activityJobs
            delegate: Rectangle {
                width: jobList.width
                height: jobCol.height + 28
                border.color: "black"
                border.width: 2
                radius: 12
                Column {
                    id: jobCol
                    x: 18
                    y: 14
                    width: parent.width - 36
                    spacing: 6
                    Text { text: root.jobLabel(modelData); font.pixelSize: 24; font.bold: true }
                    Text {
                        width: parent.width
                        text: modelData.request
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        font.pixelSize: 22
                        color: "#444444"
                    }
                }
                MouseArea { anchors.fill: parent; onClicked: root.showJob(modelData.id) }
            }
            Text {
                anchors.centerIn: parent
                width: parent.width
                visible: jobList.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "Nothing yet. Builds of app changes and searches in your notes show up here, with what the agent does step by step."
                font.pixelSize: 24
                color: "#666666"
            }
        }

        ListView {
            id: logList
            objectName: "logList"
            visible: root.activityJob !== ""
            anchors { top: actHead.bottom; topMargin: 12; left: parent.left; leftMargin: 36; right: parent.right; rightMargin: 36; bottom: parent.bottom; bottomMargin: 24 }
            clip: true
            spacing: 6
            boundsBehavior: Flickable.StopAtBounds
            model: root.activityLines
            onCountChanged: Qt.callLater(positionViewAtEnd)
            delegate: Row {
                spacing: 14
                Text {
                    width: 90
                    horizontalAlignment: Text.AlignRight
                    text: activityPanel.entry ? root.since(activityPanel.entry.started, modelData.t) : ""
                    font.pixelSize: 20
                    color: "#666666"
                }
                Text {
                    width: logList.width - 104
                    text: modelData.text
                    wrapMode: Text.Wrap
                    font.pixelSize: 22
                }
            }
            Text {
                anchors.centerIn: parent
                visible: logList.count === 0
                text: "No steps yet."
                font.pixelSize: 24
                color: "#666666"
            }
        }
    }

    // the pad to write a typeset word again, when the assistant misread it
    Rectangle {
        id: fixPanel
        objectName: "fixPanel"
        visible: root.fixIndex >= 0
        anchors { left: page.left; right: page.right }
        // away from the word
        y: root.fixBelow ? page.y + page.height - height : page.y
        height: fixCol.height + 48
        color: "white"
        z: 5
        Rectangle { anchors { top: parent.top; left: parent.left; right: parent.right } height: 2; color: "black" }
        Rectangle { anchors { bottom: parent.bottom; left: parent.left; right: parent.right } height: 2; color: "black" }
        MouseArea { anchors.fill: parent }
        Column {
            id: fixCol
            x: 36
            y: 24
            width: parent.width - 72
            spacing: 16
            Text {
                width: parent.width
                text: root.fixIndex >= 0 && root.fixIndex < typed.count
                    ? "Write “" + typed.get(root.fixIndex).text + "” again" : ""
                elide: Text.ElideRight
                font.pixelSize: 30
                font.bold: true
            }
            // above the pad, not under the palm
            Row {
                spacing: 14
                Button { objectName: "fixCancel"; label: "Cancel"; onClicked: root.closeFix() }
                Button {
                    label: "Clear"
                    enabledState: root.fixStrokes > 0 && !root.fixBusy
                    onClicked: { Ink.fixClear(); root.fixStrokes = 0; fixPad.redraw(); }
                }
                Button {
                    objectName: "fixDone"
                    label: root.fixBusy ? "Reading…" : "Done"
                    primary: true
                    enabledState: root.fixStrokes > 0 && !root.fixBusy && !root.exporting
                    onClicked: root.sendFix()
                }
            }
            Rectangle {
                width: parent.width
                height: 280
                border.color: "#555555"
                border.width: 2
                radius: 8
                Text {
                    anchors.centerIn: parent
                    visible: root.fixStrokes === 0
                    text: "Write here with the pen"
                    font.pixelSize: 30
                    color: "#bbbbbb"
                }
                Canvas {
                    id: fixPad
                    objectName: "fixPad"
                    anchors.fill: parent
                    renderStrategy: Canvas.Immediate
                    renderTarget: Canvas.Image
                    property var segs: []
                    property bool full: true
                    function add(seg) { segs = segs.concat([seg]); requestPaint(); }
                    function redraw() { full = true; segs = []; requestPaint(); }
                    onPaint: {
                        const ctx = getContext("2d");
                        if (full) {
                            full = false;
                            ctx.clearRect(0, 0, width, height);
                            root.drawStrokes(ctx, Ink.fix, 0, 0);
                        } else {
                            root.inkStyle(ctx);
                            ctx.beginPath();
                            for (const [a, b] of segs) { ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); }
                            ctx.stroke();
                        }
                        segs = [];
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    preventStealing: true
                    onPressed: mouse => {
                        if (mouse.source !== Qt.MouseEventNotSynthesized || root.fixBusy) { mouse.accepted = false; return; }
                        root.inking = true;
                        inkIdle.stop();
                        Ink.fixBegin(mouse.x, mouse.y);
                    }
                    onPositionChanged: mouse => {
                        const seg = Ink.fixAdd(mouse.x, mouse.y);
                        if (seg) fixPad.add(seg);
                    }
                    onReleased: { Ink.fixEnd(); root.fixStrokes = Ink.fix.length; inkIdle.restart(); }
                    onCanceled: { Ink.fixEnd(); root.fixStrokes = Ink.fix.length; inkIdle.restart(); }
                }
            }
        }
    }

    // Drawn only for Ask: the new ink alone, or a picture of the page (both
    // layers) grabbed from `scene`, as a PNG.
    Canvas {
        id: sink
        objectName: "exportPad"
        opacity: 0
        renderStrategy: Canvas.Immediate
        renderTarget: Canvas.Image
        property var job: null
        property string src: ""
        property bool drew: false
        onImageLoaded: if (job && src) requestPaint()
        onPaint: {
            drew = false;
            if (!job) return;
            const ctx = getContext("2d");
            ctx.fillStyle = "white";
            ctx.fillRect(0, 0, width, height);
            if (job.ink) {
                root.drawStrokes(ctx, job.strokes, job.box.x, job.box.y);
                if (job.loop) root.drawLoop(ctx, job.loop, job.box.x, job.box.y, width, height);
                drew = true;
            } else if (src && isImageLoaded(src)) {
                ctx.drawImage(src, 0, 0);
                drew = true;
            }
        }
        // toDataURL paints again, and so emits painted again. Not from inside
        // painted: painted comes from the canvas's flush, and toDataURL
        // flushes again, which frees the command buffer being replayed (heap
        // corruption, then a crash)
        onPainted: {
            if (!drew || !job) return;
            drew = false;
            job = null;
            Qt.callLater(sink.exportNow);
        }
        function exportNow() { root.exported(toDataURL("image/png").split(",")[1]); }
    }

    // Makes a web picture grey, a band of rows a frame (paused while the pen
    // writes), then gives it as a JPEG. Not from inside painted: toDataURL
    // there crashes (see sink).
    Canvas {
        id: greyPad
        objectName: "greyPad"
        opacity: 0
        width: 8
        height: 8
        renderStrategy: Canvas.Immediate
        renderTarget: Canvas.Image
        property var job: null
        property string src: ""
        property int band: -1
        property int tw: 0
        property int th: 0
        property real dark: 0
        property bool finished: false
        readonly property int rows: 48

        function start(j, url) {
            job = j;
            src = url;
            band = -1;
            finished = false;
            greyWatch.restart();
            loadImage(url);
            if (isImageLoaded(url) || isImageError(url)) Qt.callLater(greyPad.loaded);
        }
        onImageLoaded: if (job && src) loaded()
        function loaded() {
            if (!job || band >= 0 || !src) return;
            if (!isImageLoaded(src)) { fail("the picture could not be read"); return; }
            const im = getContext("2d").createImageData(src);
            const w = im ? im.width : 0, h = im ? im.height : 0;
            if (w < 48 && h < 48) { fail("no picture, or a tiny one"); return; }
            const s = Math.min(1, job.opts.w / w, job.opts.h / h);
            tw = Math.max(1, Math.round(w * s));
            th = Math.max(1, Math.round(h * s));
            width = tw;
            height = th;
            dark = 0;
            band = 0;
            requestPaint();
        }
        onPaint: {
            if (!job || band < 0 || finished) return;
            if (root.inking) { greyWait.restart(); return; }
            const ctx = getContext("2d");
            if (band === 0) {
                ctx.fillStyle = "white";
                ctx.fillRect(0, 0, tw, th);
                ctx.drawImage(src, 0, 0, tw, th);
            }
            const n = Math.min(rows, th - band);
            const id = ctx.getImageData(0, band, tw, n);
            const d = id.data, len = tw * n * 4;
            let k = 0;
            for (let i = 0; i < len; i += 4) {
                const g = (d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8;
                d[i] = g;
                d[i + 1] = g;
                d[i + 2] = g;
                if (g < 200) k++;
            }
            // Qt ignores putImageData with fewer than 7 arguments
            ctx.putImageData(id, 0, band, 0, 0, tw, n);
            dark += k;
            band += n;
            // a paint asked for from inside onPaint is dropped: the next band
            // and the end come after it
            if (band >= th) finished = true;
            Qt.callLater(finished ? greyPad.done : greyPad.requestPaint);
        }
        function done() {
            if (!finished || !job) return;
            const r = { data: toDataURL("image/jpeg"), w: tw, h: th, blank: dark / (tw * th) < 0.003 };
            reset();
            root.finishGrey(r);
        }
        function fail(why) {
            reset();
            root.finishGrey({ error: why });
        }
        function reset() {
            greyWatch.stop();
            if (src) unloadImage(src);
            src = "";
            job = null;
            band = -1;
            finished = false;
        }
    }
    Timer { id: greyWait; interval: 400; onTriggered: greyPad.requestPaint() }
    Timer { id: greyWatch; interval: 30000; onTriggered: if (greyPad.job) greyPad.fail("the picture took too long") }

    // a part of the page with both layers, off screen, for grabToImage
    Loader {
        id: scene
        x: -root.pageWidth - 100
        active: false
        property var box: ({ x: 0, y: 0, w: 960, h: 100 })
        property var list: []
        property var words: []
        sourceComponent: Item {
            width: scene.box.w
            height: scene.box.h
            Rectangle { anchors.fill: parent; color: "white" }
            Repeater {
                model: scene.list
                ReplyItem {
                    x: modelData.px
                    y: modelData.py - scene.box.y
                    width: modelData.pw
                    kind: modelData.kind
                    content: modelData.content
                    place: modelData.place
                    small: modelData.small
                    ph: modelData.ph
                    changeState: modelData.changeState
                    changeVersion: modelData.changeVersion
                    changeNote: modelData.changeNote
                }
            }
            Repeater {
                model: scene.words
                TypedWord {
                    wx: modelData.x
                    wy: modelData.y - scene.box.y
                    ww: modelData.w
                    wh: modelData.h
                    size: modelData.size
                    text: modelData.text
                }
            }
            Canvas {
                anchors.fill: parent
                renderStrategy: Canvas.Immediate
                renderTarget: Canvas.Image
                onPaint: root.drawStrokes(getContext("2d"), root.shown(root.strokesIn(scene.box.y, scene.box.y + scene.box.h)), 0, scene.box.y)
                property bool grabbed: false
                onPainted: if (!grabbed) { grabbed = true; Qt.callLater(root.grabScene); }
                Component.onCompleted: requestPaint()
            }
        }
    }
}

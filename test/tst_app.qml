import QtQuick
import QtTest
import "../ui/markdown.js" as Markdown
import "../ui/ink.js" as Ink

Item {
    width: 960
    height: 1696

    // decodes the PNGs the app sends, above the app
    Image { id: probe; z: 10 }

    // paints the pictures the fake web serves
    Canvas {
        id: painter
        width: 400
        height: 200
        renderStrategy: Canvas.Immediate
        renderTarget: Canvas.Image
        property bool ready: false
        onPaint: {
            const ctx = getContext("2d");
            ctx.fillStyle = "#ff0000";
            ctx.fillRect(0, 0, 200, 200);
            ctx.fillStyle = "#0000ff";
            ctx.fillRect(200, 0, 200, 200);
            ready = true;
        }
    }

    Loader {
        id: app
        anchors.fill: parent
        source: "../ui/main.qml"
    }

    Loader {
        id: boot
        visible: false
        width: 960
        height: 1696
        source: "../ui/loader.qml"
    }

    TestCase {
        name: "loader"
        when: windowShown

        // run.sh prepares code-none/ (no pointer), code-good/ (current = v2, a
        // copy of ui/) and code-bad/ (current = v3, broken QML)
        function test_versions() {
            const dir = name => Qt.resolvedUrl(".").toString() + "tmp/" + name + "/";
            const b = boot.item;

            b.codeDir = dir("code-none");
            b.boot();
            tryVerify(() => b.version === "" && b.app.status === Loader.Ready);

            b.codeDir = dir("code-good");
            b.boot();
            tryVerify(() => b.slot === "v2" && b.app.status === Loader.Ready);
            compare(b.app.item.version, "v7");
            compare(b.app.item.slot, "v2");

            b.codeDir = dir("code-bad");
            b.boot();
            tryVerify(() => b.version === "" && b.app.status === Loader.Ready);
            compare(b.app.item.version, "built-in");
        }
    }

    TestCase {
        name: "app"
        when: windowShown

        // the page starts below the 84 px toolbar
        readonly property int bar: 84

        function stroke(r, points) {
            mousePress(r, points[0][0], points[0][1]);
            for (const [x, y] of points) mouseMove(r, x, y);
            const last = points[points.length - 1];
            mouseRelease(r, last[0], last[1]);
        }

        function init() {
            const r = app.item;
            // an ask a test left open would keep newPage() from clearing the page
            r.failed("test");
            r.pagesOpen = false;
            if (r.pageId !== "main") { r.showPage("main"); tryVerify(() => r.pageLoaded, 3000); }
            r.pagesIndex = [{ id: "main", kind: "main", title: "Conversation", state: "" }];
            r.barShown = true;
            r.status = "";
            r.dataDir = Qt.resolvedUrl("tmp").toString();
            r.newPage();
            r.eraser = false;
            r.layers = "both";
            r.disarmAsk();
            r.apiKey = "";
            r.baseUrl = "";
            r.status = "";
            r.showType = true;
            r.typingDelay = 50;
            r.closeFix();
            r.fetcher = null;
            r.jobPoster = null;
            r.postTries = 0;
            r.partChars = 5000;
            r.chosenLink = null;
            r.barShown = true;
            r.lassoMode = false;
            r.roomDelay = 600;
            r.notesOpen = false;
            r.pageTimeout = 60000;
            r.shotTimeout = 90000;
            fetched = [];
        }

        // ---- a fake web: address -> { type, text } or { type, png: true }
        // or { error } or { hang: true } (no answer ever); what the app
        // fetched is in `fetched`
        property var web: ({})
        property var fetched: []

        function pngBuffer() {
            painter.requestPaint();
            tryVerify(() => painter.ready);
            const b64 = painter.toDataURL("image/png").split(",")[1];
            const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            const clean = b64.replace(/=+$/, ""), out = new Uint8Array(Math.floor(clean.length * 3 / 4));
            let bits = 0, n = 0, k = 0;
            for (const c of clean) {
                bits = (bits << 6) | abc.indexOf(c);
                n += 6;
                if (n >= 8) { n -= 8; out[k++] = (bits >> n) & 255; }
            }
            return out.buffer;
        }

        function fakeWeb(r, pages) {
            web = pages;
            const png = pngBuffer();
            r.fetcher = (url, opts, done) => {
                fetched.push(url);
                const p = web[url] || Object.keys(web).filter(k => k.endsWith("*") && url.indexOf(k.slice(0, -1)) === 0).map(k => web[k])[0];
                Qt.callLater(() => {
                    if (p && p.hang) return;
                    if (!p) done("example.org answered HTTP 404", null);
                    else if (p.error) done(p.error, null);
                    else if (p.png) done("", { status: 200, type: "image/png", text: "", data: png });
                    else done("", { status: 200, type: p.type || "text/html; charset=utf-8", text: p.text, data: null });
                });
            };
        }

        readonly property string articleHtml: '<html><head><title>A test article</title>' +
            '<meta property="og:site_name" content="Example News"></head><body>' +
            '<header class="masthead"><nav><a href="/">Home</a> <a href="/about">About us</a></nav></header>' +
            '<div class="cookie-banner">We use cookies. <button>Accept cookies</button></div>' +
            '<div class="ad-slot">Buy now! Great offer</div>' +
            '<article><h1>A test article</h1>' +
            '<p>The first paragraph of the article is long enough to count as the main text of the page. ' +
            'It goes on for a while, so that the reader view picks it as the content and not the menus.</p>' +
            '<h2>Section two</h2><ul><li>First point</li><li>Second point</li></ul>' +
            '<table><tr><th>City</th><th>Rain</th></tr><tr><td>Lyon</td><td>2 mm</td></tr></table>' +
            '<p>Read <a href="/next">the next page</a> for more. Another paragraph, with enough words in it to be ' +
            'real content on this page, about the weather in the south of France in September.</p>' +
            '<img src="/pic.png" alt="A picture" width="400" height="200"></article>' +
            '<aside class="newsletter">Subscribe to our newsletter</aside><footer>Copyright Example</footer></body></html>'

        // the answer to an ask: the assistant calls these tools
        function toolCalls(calls) {
            return { content: calls.map(c => ({ type: "tool_use", name: c[0], input: c[1] })) };
        }

        // two words, a dot over the first, and a box drawn round them
        function writeWords(r) {
            stroke(r, [[100, 400], [120, 450], [140, 400]]);
            stroke(r, [[145, 400], [160, 450]]);
            mouseClick(r, 130, 370);
            stroke(r, [[300, 400], [340, 450], [380, 400]]);
            stroke(r, [[60, 330], [420, 330], [420, 500], [60, 500], [60, 330]]);
        }

        // the screen y of page y
        function screenY(r, y) { return y + bar - r.pageView().contentY; }

        function test_ink() {
            const r = app.item;
            stroke(r, [[300, 1150], [300, 1250], [300, 1350]]);
            stroke(r, [[420, 1150], [420, 1250], [420, 1350]]);
            wait(200);
            compare(r.strokeCount, 2);
            const g = grabImage(r);
            verify(g.pixel(300, 1300) !== g.pixel(600, 1300), "ink on the page");
            r.undoStroke();
            compare(r.strokeCount, 1);
            r.clearInk();
            compare(r.strokeCount, 0);
            wait(100);
            const g2 = grabImage(r);
            compare(g2.pixel(300, 1300), g2.pixel(600, 1300), "ink gone");
        }

        function test_pad_hint() {
            const r = app.item;
            const hint = findChild(r, "padHint");
            verify(hint, "hint on the page");
            compare(hint.text, "Write here with the pen");
            verify(hint.visible);
            stroke(r, [[300, 1150], [300, 1250]]);
            verify(!hint.visible, "hint hides once there is ink");
            r.clearInk();
            verify(hint.visible);
        }

        function test_pickers_cycle() {
            const r = app.item;
            compare(r.models[r.modelIndex].id, "sonnet");
            compare(r.efforts[r.effortIndex].id, "medium");
            // in the More panel now: the toolbar is slim
            r.notesOpen = true;
            for (let i = 0; i < r.models.length; i++) mouseClick(findChild(r, "modelButton"));
            r.notesOpen = false;
            compare(r.models[r.modelIndex].id, "sonnet");
        }

        function test_notes() {
            const r = app.item;
            verify(r.fullSystemPrompt().indexOf("(none yet)") > 0);
            r.notes = "- likes tea";
            verify(r.fullSystemPrompt().endsWith("Your notes:\n- likes tea"));
            r.notes = "";
            const req = r.replyTool.input_schema.required;
            compare(req.indexOf("items"), 1);
            compare(req.indexOf("notes"), 2);
            compare(req.indexOf("app_change"), 3);
            compare(req.indexOf("notes_query"), 4);
            compare(req.indexOf("typeset"), 5);
        }

        function test_reply_below_the_newest_ink() {
            const r = app.item;
            stroke(r, [[100, 300], [400, 350], [700, 300]]);
            stroke(r, [[100, 500], [400, 560], [700, 500]]);
            const ctx = r.context();
            compare(ctx.sent.length, 2);
            r.receive({ heard: "hi", items: [
                { kind: "markdown", content: "Hello **there**", place: "below" },
                { kind: "svg", content: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 400"><circle cx="400" cy="200" r="150" stroke="black" fill="none"/></svg>', place: "below" }
            ] }, ctx);
            compare(r.strokeCount, 0, "the ink is sent, and kept");
            compare(r.replyCount(), 2);
            const a = r.itemBox(0), b = r.itemBox(1);
            verify(a.y > ctx.newest.y1, "text below the newest ink: " + JSON.stringify(a));
            verify(a.h > 20);
            verify(b.y >= a.y + a.h, "the drawing stacks under the text");
            compare(Math.round(b.h), Math.round(b.w / 2));
        }

        function test_margin_note_keeps_off_ink() {
            const r = app.item;
            // a line of ink across most of the page, then a note on the left
            stroke(r, [[60, 400], [300, 520], [560, 400]]);
            r.receive({ heard: "a", items: [{ kind: "markdown", content: "first", place: "below" }] }, r.context());
            stroke(r, [[60, 900], [100, 950]]);
            const ctx = r.context();
            r.receive({ heard: "b", items: [
                { kind: "markdown", content: "a note next to it", place: "margin", ref: "i1" },
                { kind: "svg", content: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><circle cx="50" cy="50" r="40" stroke="black" fill="none"/></svg>', place: "over", ref: "c0" }
            ] }, ctx);
            const ink = ctx.regions[0];
            const note = r.itemBox(1);
            verify(note.x >= ink.x1, "beside the ink: " + JSON.stringify(note) + " " + JSON.stringify(ink));
            verify(note.y < ink.y1, "next to it, not below it");
            const c0 = r.itemBox(0), over = r.itemBox(2);
            verify(over.x <= c0.x && over.y <= c0.y && over.x + over.w >= c0.x + c0.w, "the circle is over c0");
        }

        function test_below_slides_past_content() {
            const r = app.item;
            stroke(r, [[100, 300], [300, 320]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "long\n\nanswer\n\nhere", place: "below" }] }, r.context());
            const first = r.itemBox(0);
            // annotate just above the answer: the next reply goes below it
            stroke(r, [[600, 250], [700, 260]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "second", place: "below" }] }, r.context());
            const second = r.itemBox(1);
            verify(second.y >= first.y + first.h, JSON.stringify([first, second]));
        }

        function test_marker_for_offscreen_item() {
            const r = app.item;
            stroke(r, [[100, 300], [300, 320]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "far below", place: "at", x: 36, y: 5000, width: 600 }] }, r.context());
            const m = findChild(r, "marker");
            verify(m.visible, "a marker for the item off screen");
            verify(findChild(r, "markerText").text.indexOf("below") >= 0);
            mouseClick(m);
            verify(!m.visible);
            const p = r.pageView();
            verify(p.contentY + p.height > 5000 && p.contentY < 5000, "scrolled to it: " + p.contentY);
            // and one above
            stroke(r, [[100, 700], [300, 720]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "up there", place: "margin", ref: "i1" }] }, r.context());
            verify(m.visible);
            verify(findChild(r, "markerText").text.indexOf("added above") >= 0, findChild(r, "markerText").text);
        }

        function test_layers_and_eraser() {
            const r = app.item;
            stroke(r, [[300, 400], [300, 600]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "kept", place: "below" }] }, r.context());
            const ink = findChild(r, "inkLayer"), claude = findChild(r, "replyLayer");
            verify(ink.visible && claude.visible);
            mouseClick(findChild(r, "moreButton"));
            verify(findChild(r, "viewPanel").visible, "Show is in More");
            const user = findChild(r, "userLayerButton"), cl = findChild(r, "replyLayerButton");
            mouseClick(cl);
            verify(ink.visible && !claude.visible, "user only");
            mouseClick(user);
            verify(!ink.visible && claude.visible, "Claude only");
            mouseClick(user);
            verify(ink.visible && claude.visible, "both");
            mouseClick(findChild(r, "moreClose"));
            verify(!findChild(r, "viewPanel").visible);

            mouseClick(findChild(r, "eraserButton"));
            verify(r.eraser);
            const c = r.itemBox(0);
            // erase across the ink and across Claude's text
            stroke(r, [[200, 500], [400, 500], [400, c.y + bar + 10 - r.pageView().contentY], [100, c.y + bar + 10 - r.pageView().contentY]]);
            compare(r.inkCount(), 0, "the ink is erased");
            compare(r.replyCount(), 1, "Claude's text is not");
            r.undoStroke();
            compare(r.inkCount(), 1, "undo brings the ink back");
            mouseClick(findChild(r, "eraserButton"));
        }

        // pieces by the lines of the strokes: the box round the words is its
        // own piece, the dot joins its word
        function test_pieces() {
            const r = app.item;
            writeWords(r);
            const ps = r.context().pieces;
            compare(ps.length, 3, JSON.stringify(ps.map(p => [p.x0, p.y0, p.x1, p.y1])));
            compare(ps[0].x0, 60, "the box, first in reading order");
            compare(ps[1].strokes.length, 3, "the first word with its dot");
            compare(ps[2].x0, 300);
            verify(r.pieceList(r.context()).indexOf("n3: x 300–380") >= 0, r.pieceList(r.context()));
        }

        // after Claude has read the ink, its text shows as type; the drawing
        // stays ink; the ink is kept under the type
        function test_handwriting_becomes_type() {
            const r = app.item;
            writeWords(r);
            r.receive({ heard: "hi there", items: [{ kind: "markdown", content: "ok", place: "below" }],
                        typeset: [{ ids: ["n2"], text: "hi" }, { ids: ["n3"], text: "there" }, { ids: ["n9"], text: "bad" }] },
                      r.context());
            tryVerify(() => r.typedCount() === 2, 2000);
            compare(r.typedWord(0).text, "hi");
            compare(r.typedWord(1).text, "there");
            verify(r.typedWord(0).size >= 22 && r.typedWord(0).size <= 96);
            compare(r.inkCount(), 5, "the ink is kept");
            compare(r.shownInk(), 1, "only the box shows as ink");
            const word = findChild(r, "typedWord");
            verify(word.visible && word.text === "hi");
            wait(100);
            let g = grabImage(r);
            verify(!Qt.colorEqual(g.pixel(240, screenY(r, 330 - bar)), "white"), "the box is drawn");

            // the page map tells Claude the typed text
            verify(r.pageMap(r.context()).indexOf("text: \"hi there\"") >= 0, r.pageMap(r.context()));

            mouseClick(findChild(r, "moreButton"));
            mouseClick(findChild(r, "typeButton"));
            mouseClick(findChild(r, "moreClose"));
            verify(!r.showType);
            compare(r.shownInk(), 5, "as written");
            verify(!word.visible);
            wait(100);
            g = grabImage(r);
            verify(!Qt.colorEqual(g.pixel(340, screenY(r, 450 - bar) - 2), "white"), "the ink of the second word");
            mouseClick(findChild(r, "moreButton"));
            mouseClick(findChild(r, "typeButton"));
            mouseClick(findChild(r, "moreClose"));
            verify(r.showType && word.visible);
        }

        function test_conversion_waits_for_the_pen() {
            const r = app.item;
            r.typingDelay = 400;
            stroke(r, [[100, 400], [200, 450]]);
            const ctx = r.context();
            mousePress(r, 500, 900);
            mouseMove(r, 520, 950);
            r.receive({ heard: "x", items: [], typeset: [{ ids: ["n1"], text: "x" }] }, ctx);
            wait(600);
            compare(r.typedCount(), 0, "not while the pen is writing");
            mouseMove(r, 540, 990);
            mouseRelease(r, 540, 990);
            wait(150);
            compare(r.typedCount(), 0, "not right after it lifts");
            tryVerify(() => r.typedCount() === 1, 2000);
            compare(r.strokeCount, 1, "the new stroke stays ink");
        }

        function test_activity_panel() {
            const r = app.item;
            r.openActivity("");
            verify(findChild(r, "activityPanel").visible);
            const t0 = new Date(Date.now() - 125000).toISOString();
            r.activityJobs = [
                { id: "b1", kind: "build", request: "Make the buttons bigger", state: "running", started: t0, lines: 2 },
                { id: "n1", kind: "notes", request: "What about Slack?", state: "done", started: t0, finished: new Date(Date.now() - 100000).toISOString(), lines: 3 }
            ];
            compare(findChild(r, "jobList").count, 2);
            verify(r.jobLabel(r.activityJobs[0]).indexOf("Build · running for 2 min") === 0, r.jobLabel(r.activityJobs[0]));
            verify(r.jobLabel(r.activityJobs[1]).indexOf("Notes search · done in 25 s") === 0, r.jobLabel(r.activityJobs[1]));
            r.showJob("b1");
            verify(findChild(r, "logList").visible);
            r.activityLines = [{ n: 1, t: t0, text: "Fetching the newest code" }, { n: 2, t: new Date().toISOString(), text: "Read ui/main.qml" }];
            compare(findChild(r, "logList").count, 2);
            wait(50); // the Row lays the new button out on the next frame
            mouseClick(findChild(r, "allJobsButton"));
            compare(r.activityJob, "");
            r.activityOpen = false;
        }

        // Back goes one level up, Close always back to the page
        function test_navigation() {
            const r = app.item;
            mouseClick(findChild(r, "moreButton"));
            verify(r.notesOpen);
            mouseClick(findChild(r, "activityButton"));
            verify(r.activityOpen && !r.notesOpen);
            const back = findChild(r, "backToMore");
            verify(back.visible, "Back to More");
            wait(50); // the Row lays the button out on the next frame
            mouseClick(back);
            verify(r.notesOpen && !r.activityOpen, "back in More");
            mouseClick(findChild(r, "activityButton"));
            r.activityJobs = [{ id: "b1", kind: "build", request: "x", state: "running", started: new Date().toISOString(), lines: 0 }];
            r.showJob("b1");
            wait(50);
            verify(!back.visible && findChild(r, "allJobsButton").visible, "from a job, Back goes to the list");
            mouseClick(findChild(r, "allJobsButton"));
            compare(r.activityJob, "");
            mouseClick(findChild(r, "activityClose"));
            verify(!r.activityOpen && !r.notesOpen, "Close goes to the page");

            r.openActivity("b1");
            wait(50);
            verify(!back.visible, "from a change card there is no More to go back to");
            mouseClick(findChild(r, "activityClose"));
            verify(!r.activityOpen && !r.notesOpen);
        }

        function test_latest_only_when_off_screen() {
            const r = app.item;
            const latest = findChild(r, "latestButton");
            verify(!latest.visible, "an empty page: nothing below");
            r.receive({ heard: "", items: [{ kind: "markdown", content: "far down", place: "at", x: 36, y: 6000, width: 600 }] }, r.context());
            const p = r.pageView();
            verify(!latest.visible, "the marker leads to the new reply, not Latest");
            p.contentY = 5800;
            r.checkMarkers();
            p.contentY = 0;
            verify(latest.visible, "the newest part is below the screen");
            mouseClick(latest);
            verify(!latest.visible, "it is on screen now");
        }

        function test_background_ask() {
            const r = app.item;
            r.clearInk();
            stroke(r, [[300, 400], [300, 600]]);
            stroke(r, [[400, 400], [400, 600]]);
            const ctx = r.context();
            compare(ctx.sent.length, 2);
            const saved = JSON.parse(JSON.stringify(r.saveCtx(ctx)));
            const back = r.loadCtx(saved);
            compare(back.sent.length, 2);
            verify(back.sent[0] === ctx.sent[0] && back.sent[1] === ctx.sent[1], "the same live strokes");

            // the app closed while the job ran; it opens again
            const st = JSON.parse(JSON.stringify(r.pageState()));
            st.ask = { id: "job1", started: Date.now(), who: "Sonnet, medium", ctx: saved };
            r.restorePage(st);
            verify(r.busy, "waits for the answer");
            verify(r.pending && r.pending.id === "job1");
            compare(r.pending.ctx.sent.length, 2);
            const before = r.replyCount();
            r.answered({ content: [{ type: "tool_use", input: { heard: "two lines", items: [{ kind: "markdown", content: "an answer", place: "below" }] } }] }, r.pending);
            verify(!r.busy);
            verify(r.pending === null);
            compare(r.replyCount(), before + 1, "the answer is on the page");
            compare(r.strokeCount, 0, "the ink counts as sent");
            compare(r.pageState().ask, null);
            r.clearInk();
        }

        function test_ask_retries_unreachable_bridge() {
            const r = app.item;
            r.clearInk();
            stroke(r, [[300, 400], [300, 600]]);
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            r.postTries = 1;
            r.ask();
            tryVerify(() => r.status.indexOf("Trying again (1 of 1)") >= 0, 5000);
            verify(r.busy);
            tryVerify(() => !r.busy, 8000);
            verify(r.status.indexOf("cannot reach") >= 0, r.status);
            r.clearInk();
        }

        function test_ask_never_grabs() {
            const r = app.item;
            r.clearInk();
            r.receive({ heard: "", items: [{ kind: "markdown", content: "a reply", place: "below" }] }, r.context());
            stroke(r, [[300, 400], [300, 600]]);
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            r.ask();
            verify(r.askCtx.jobs.length > 1, "the page views are there");
            for (const j of r.askCtx.jobs) verify(j.ink, "no grabToImage job: it crashes xochitl");
            tryVerify(() => !r.busy, 5000);
            r.clearInk();
        }

        function test_eraser_end() {
            const r = app.item;
            r.clearInk();
            r.eraser = false;
            stroke(r, [[300, 400], [300, 600]]);
            const n = r.inkCount();
            verify(n > 0);
            const backend = findChild(r, "backend");
            backend.messageReceived(101, "rubber");
            verify(r.erasingTool);
            verify(findChild(r, "eraserButton").primary, "the Erase button shows the eraser end");
            stroke(r, [[200, 500], [400, 500]]);
            compare(r.inkCount(), 0, "the eraser end erases");
            backend.messageReceived(101, "pen");
            verify(!r.erasingTool);
            stroke(r, [[300, 700], [300, 800]]);
            verify(r.inkCount() > 0, "the tip writes again");
            r.clearInk();
        }

        // the digitizer's word comes after the eraser end touched: what it
        // drew so far is no ink, it erases, and nothing new is left to send
        function test_eraser_end_reported_late() {
            const r = app.item;
            r.clearInk();
            const backend = findChild(r, "backend");
            backend.messageReceived(101, "pen");
            stroke(r, [[300, 400], [300, 600]]);
            stroke(r, [[500, 400], [500, 600]]);
            compare(r.inkCount(), 2);
            mousePress(r, 200, 500);
            mouseMove(r, 250, 500);
            mouseMove(r, 320, 500);
            compare(r.inkCount(), 3);
            backend.messageReceived(101, "rubber");
            compare(r.inkCount(), 1, "its stroke so far erases, and is gone");
            mouseMove(r, 420, 500);
            mouseMove(r, 520, 500);
            mouseRelease(r, 520, 500);
            compare(r.inkCount(), 0);
            compare(r.strokeCount, 0, "nothing to send");
            verify(r.selfReport().indexOf("the backend reports it") > 0, r.selfReport());
            backend.messageReceived(101, "pen");
            r.undoStroke();
            compare(r.inkCount(), 2, "one undo brings the erased ink back");
            r.clearInk();
        }

        function test_erase_and_restore_typed_words() {
            const r = app.item;
            writeWords(r);
            r.receive({ heard: "", items: [], typeset: [{ ids: ["n2"], text: "hi" }, { ids: ["n3"], text: "there" }] }, r.context());
            tryVerify(() => r.typedCount() === 2, 2000);
            r.savePage();
            wait(100);
            r.restorePage({ strokes: [], items: [], turns: [] });
            compare(r.typedCount(), 0);
            r.loadPage();
            tryVerify(() => r.typedCount() === 2);
            compare(r.inkCount(), 5);
            compare(r.shownInk(), 1, "restored as type");
            verify(r.typedWord(1).alive);

            r.eraser = true;
            const w = r.typedWord(1);
            const y = screenY(r, w.y + w.h / 2);
            stroke(r, [[w.x + 4, y], [w.x + 10, y]]);
            verify(!r.typedWord(1).alive, "the whole word is erased");
            compare(r.inkCount(), 4);
            verify(r.typedWord(0).alive, "not the other one");
            r.undoStroke();
            verify(r.typedWord(1).alive, "undo brings it back");
            compare(r.inkCount(), 5);
            r.eraser = false;
        }

        // a finger tap on a typed word opens the pad to write it again
        function test_correct_a_word() {
            const r = app.item;
            writeWords(r);
            r.receive({ heard: "hl there", items: [], typeset: [{ ids: ["n2"], text: "hl" }, { ids: ["n3"], text: "there" }] }, r.context());
            tryVerify(() => r.typedCount() === 2, 2000);
            const p = r.pageView();
            const w = r.typedWord(0);
            const t = touchEvent(p);
            t.press(0, p, w.x + w.w / 2, w.y + w.h / 2 - p.contentY).commit();
            t.release(0, p, w.x + w.w / 2, w.y + w.h / 2 - p.contentY).commit();
            tryVerify(() => r.fixIndex === 0, 1000, "tapped: " + r.fixIndex);
            const panel = findChild(r, "fixPanel");
            verify(panel.visible);
            compare(r.inkCount(), 5, "the tap wrote nothing");

            // pen strokes on the pad are the pad's, not the page's
            const pad = findChild(r, "fixPad");
            stroke(pad, [[40, 80], [80, 200], [120, 80]]);
            compare(r.fixStrokes, 1);
            compare(r.inkCount(), 5);
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            r.sendFix();
            verify(r.fixBusy);
            tryVerify(() => !r.fixBusy, 5000);
            verify(r.status.indexOf("Failed") === 0, r.status);
            compare(r.fixIndex, 0, "failed: the pad stays open");

            r.setWord(0, "hi");
            compare(r.typedWord(0).text, "hi");
            compare(r.transcript().indexOf("hl"), -1, "the transcript is corrected too");
            mouseClick(findChild(r, "fixCancel"));
            verify(!panel.visible);
        }

        function test_page_saved_and_restored() {
            const r = app.item;
            stroke(r, [[300, 400], [350, 600]]);
            r.receive({ heard: "saved", items: [{ kind: "markdown", content: "Kept **text**", place: "below" }] }, r.context());
            stroke(r, [[500, 900], [600, 950]]);
            r.savePage();
            wait(100);
            r.restorePage({ strokes: [], items: [], turns: [] });
            compare(r.inkCount(), 0);
            r.loadPage();
            tryVerify(() => r.inkCount() === 2);
            compare(r.replyCount(), 1);
            compare(r.strokeCount, 1, "the unsent ink is still new");
            verify(r.transcript().indexOf("saved") > 0);
            verify(r.transcript().indexOf("Kept **text**") > 0);
        }

        function test_fingers_scroll() {
            const r = app.item;
            stroke(r, [[200, 400], [500, 420]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "far", place: "at", x: 36, y: 4000, width: 600 }] }, r.context());
            const p = r.pageView();
            p.contentY = 0;
            const ink = r.inkCount();
            const t = touchEvent(p);
            t.press(0, p, 480, 1200).commit();
            for (let y = 1180; y >= 400; y -= 40) t.move(0, p, 480, y).commit();
            t.release(0, p, 480, 400).commit();
            tryVerify(() => p.contentY > 300, 2000, "a finger scrolls the page: " + p.contentY);
            compare(r.inkCount(), ink, "and does not write");
            tryVerify(() => !p.moving, 3000);
            // ink written down the page, and the first ink after scrolling back
            stroke(r, [[700, 300], [700, 700]]);
            wait(100);
            let g = grabImage(r);
            verify(!Qt.colorEqual(g.pixel(700, 500), "white"), "ink where the page scrolled to");
            const y0 = p.contentY;
            p.contentY = 0;
            wait(100);
            g = grabImage(r);
            verify(!Qt.colorEqual(g.pixel(350, 410), "white"), "the first ink, repainted");
            verify(Qt.colorEqual(g.pixel(700, 500), "white"), "no ink from further down");
            p.contentY = y0;
            wait(100);
            g = grabImage(r);
            verify(!Qt.colorEqual(g.pixel(700, 500), "white"), "and back again");
        }


        // the request carries the new ink alone, then the page around it
        // with both layers
        function test_ask_exports_page() {
            const r = app.item;
            stroke(r, [[200, 300], [400, 350]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "# BIG GREY TITLE", place: "below" }] }, r.context());
            const c = r.itemBox(0);
            const sy = c.y + c.h + bar - r.pageView().contentY;
            stroke(r, [[200, sy + 60], [400, sy + 120], [600, sy + 60]]);
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            r.ask();
            verify(r.busy);
            tryVerify(() => !r.busy, 5000);
            // the new ink, the page around it, and the earlier ink not read yet
            compare(r.lastImages.length, r.askCtx.jobs.length);
            verify(r.askCtx.jobs[0].fresh && r.askCtx.jobs.some(j => j.unread), JSON.stringify(r.askCtx.jobs.map(j => Object.keys(j))));
            const job = r.askCtx.jobs[1].box;
            verify(job.y <= c.y && job.y + job.h >= c.y + c.h, "the page view spans the reply");

            probe.source = "data:image/png;base64," + r.lastImages[1];
            tryVerify(() => probe.status === Image.Ready);
            compare(probe.implicitHeight, job.h);
            const g = grabImage(probe);
            let grey = 0;
            for (let x = c.x; x < c.x + 400; x += 3)
                for (let y = c.y - job.y; y < c.y - job.y + c.h; y += 3) {
                    const p = g.pixel(x, y);
                    if (!Qt.colorEqual(p, "white") && !Qt.colorEqual(p, "black")) grey++;
                }
            // ink only: drawing the replies meant grabToImage, which crashes xochitl
            compare(grey, 0, "the reply is not drawn in the page view");
            let ink = 0;
            for (let x = 0; x < g.width; x += 4)
                for (let y = 0; y < g.height; y += 4)
                    if (!Qt.colorEqual(g.pixel(x, y), "white")) ink++;
            verify(ink > 5, "the user's ink is in the page view: " + ink);

            probe.source = "data:image/png;base64," + r.lastImages[0];
            tryVerify(() => probe.status === Image.Ready);
            verify(probe.implicitWidth > 380 && probe.implicitWidth < 500, "the new ink alone: " + probe.implicitWidth);
            probe.source = "";
        }

        // a build that changed more than the app is a proposal: no Install
        function test_proposal_card() {
            const r = app.item;
            r.receive({ heard: "", items: [], app_change: "Let the server keep builds for a week." }, r.context());
            r.setChange(0, { changeState: "review", changeVersion: "", changeNote: "A proposal for review, on the branch proposal/x." });
            verify(r.changeLabel(r.replyItem(0)).indexOf("waiting for a person to review") > 0);
            verify(r.fullSystemPrompt().indexOf("How Folio is built") > 0, "the assistant knows its parts");
        }

        function test_change_card() {
            const r = app.item;
            stroke(r, [[200, 300], [400, 350]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "Tap Build it.", place: "below" }], app_change: "Make the buttons bigger." }, r.context());
            compare(r.replyCount(), 2);
            const it = r.replyItem(1);
            compare(it.kind, "change");
            compare(it.content, "Make the buttons bigger.");
            compare(it.changeState, "proposed");
            verify(r.itemBox(1).y >= r.itemBox(0).y + r.itemBox(0).h);
        }

        function test_close_button() {
            const r = app.item;
            let closed = 0;
            r.close.connect(() => closed++);
            const b = findChild(r, "closeButton");
            verify(b.mapToItem(r, 0, 0).y < bar, "in the toolbar at the top");
            mouseClick(b);
            compare(closed, 1);
        }

        // a zigzag stroke filling the box: a handwritten word
        function word(r, x0, y0, x1, y1) {
            stroke(r, [[x0, y0], [x0 + (x1 - x0) / 3, y1], [x0 + (x1 - x0) * 2 / 3, y0], [x1, y1]]);
        }

        // Two lines of handwriting whose words sit at different heights: a
        // short word is lower than a tall one. The type and the page map read
        // by line, then left to right, whatever order the typeset came in.
        function test_typeset_reading_order() {
            const r = app.item;
            word(r, 60, 400, 180, 470);    // That's
            word(r, 210, 420, 330, 490);   // useful,
            word(r, 360, 400, 440, 460);   // but
            word(r, 470, 415, 560, 440);   // also: x-height only, the highest middle
            word(r, 590, 395, 600, 465);   // I
            word(r, 60, 540, 180, 590);    // want
            word(r, 210, 530, 260, 590);   // to
            word(r, 290, 520, 350, 590);   // be
            const ctx = r.context();
            compare(ctx.pieces.length, 8);
            const xs = ctx.pieces.map(p => p.x0);
            compare(JSON.stringify(xs), JSON.stringify([60, 210, 360, 470, 590, 60, 210, 290]), "pieces in reading order");
            r.receive({ heard: "That's useful, but also I want to be", items: [], typeset: [
                { ids: ["n5"], text: "I" }, { ids: ["n8"], text: "be" }, { ids: ["n2"], text: "useful," },
                { ids: ["n6", "n7"], text: "want to" }, { ids: ["n4"], text: "also" }, { ids: ["n1"], text: "That's" },
                { ids: ["n3"], text: "but" }
            ] }, ctx);
            tryVerify(() => r.typedCount() === 7, 2000);
            const words = [];
            for (let k = 0; k < 7; k++) words.push(r.typedWord(k).text);
            compare(words.join(" "), "That's useful, but also I want to be");
            const map = r.pageMap(r.context());
            verify(map.indexOf("text: \"That's useful, but also I want to be\"") >= 0, map);
            // the rewrite pad's context is the word's own line
            compare(r.lineOf(3), "That's useful, but also I");
        }

        // Two lines that slope up to the right, as handwriting across the
        // page does, with short and tall words: each line stays one line.
        function test_typeset_sloping_lines() {
            const r = app.item;
            const want = [];
            for (let line = 0; line < 2; line++) {
                for (let k = 0; k < 7; k++) {
                    const x = 40 + 130 * k, base = 460 + 120 * line - 12 * k;
                    const top = k % 2 ? base - 26 : base - 60;   // x-height only, or with ascenders
                    word(r, x, top, x + 100, base);
                    want.push(x + "," + (top - bar));
                }
            }
            const ps = r.context().pieces;
            compare(ps.length, 14);
            compare(ps.map(p => Math.round(p.x0) + "," + Math.round(p.y0)).join(" "), want.join(" "), "pieces in reading order");
        }

        // "you" and "show" touch: one piece, which the assistant names in two
        // entries. Both words show, as one run. Ink that no word covers stays.
        function test_typeset_shared_piece() {
            const r = app.item;
            word(r, 60, 400, 180, 470);    // you
            word(r, 150, 400, 290, 470);   // show, across its end
            word(r, 400, 400, 480, 470);   // me
            word(r, 600, 400, 700, 470);   // a
            word(r, 800, 400, 880, 470);   // not in the typeset
            const ctx = r.context();
            compare(ctx.pieces.length, 4);
            r.receive({ heard: "you show me a", items: [], typeset: [
                { ids: ["n1"], text: "you" }, { ids: ["n1"], text: "show" }, { ids: ["n2", "n9"], text: "me" },
                { ids: ["n8"], text: "lost" }, { ids: ["n3"], text: "a" }, { ids: ["n3"], text: "a" }
            ] }, ctx);
            tryVerify(() => r.typedCount() === 3, 2000);
            compare([0, 1, 2].map(k => r.typedWord(k).text).join(" / "), "you show / me / a");
            compare(r.shownInk(), 1, "the last word stays ink");
            r.receive({ heard: "", items: [], typeset: [{ ids: ["n1", "n4"], text: "again" }] }, ctx);
            tryVerify(() => r.typedCount() === 4, 2000);
            compare(r.typedWord(3).text, "again", "only over the ink not yet shown as type");
            compare(r.shownInk(), 0);
            compare(r.typedWord(3).x, r.typedWord(2).x + 200);
        }

        // lines of boxes: a comma, a dot and a piece that touches the line
        // below go with their own line
        function test_lines_marks_and_tall_pieces() {
            const b = (x0, y0, x1, y1, t) => ({ x0: x0, y0: y0, x1: x1, y1: y1, t: t });
            const ls = Ink.lines([
                b(60, 520, 180, 580, "want"), b(470, 405, 560, 585, "also+to"), b(60, 400, 180, 460, "That's"),
                b(186, 450, 194, 470, ","), b(210, 400, 330, 460, "useful"), b(360, 420, 440, 460, "but"),
                b(210, 540, 330, 580, "be"), b(340, 575, 346, 582, "."), b(600, 385, 700, 440, "I")
            ]);
            compare(ls.map(l => l.map(w => w.t).join(" ")).join(" / "), "That's , useful but also+to I / want be .");
            compare(Ink.lines([]).length, 0);
            compare(Ink.lines([b(0, 0, 10, 10, "a")]).length, 1);
        }

        // each request tells the assistant how the recent builds went
        function test_build_status() {
            const r = app.item;
            stroke(r, [[200, 300], [400, 350]]);
            r.receive({ heard: "", items: [], app_change: "Make the buttons bigger." }, r.context());
            r.receive({ heard: "", items: [], app_change: "Add a clock." }, r.context());
            r.receive({ heard: "", items: [], app_change: "Add a dark mode." }, r.context());
            r.setChange(0, { changeState: "building", changeJob: "b1" });
            r.setChange(1, { changeState: "failed", changeJob: "b2",
                             changeNote: "test/run.sh failed:   3 tests failed\n in tst_app.qml " + "and more. ".repeat(60) });
            const t0 = new Date(Date.now() - 200000).toISOString(), t1 = new Date(Date.now() - 60000).toISOString();
            r.buildJobs = [
                { id: "b3", kind: "build", request: "Show the time", state: "queued", started: t0 },
                { id: "b1", kind: "build", request: "Make the buttons bigger.", state: "running", started: t0 },
                { id: "b2", kind: "build", request: "Add a clock.", state: "failed", started: t0, finished: t1, error: "test/run.sh failed: 3 tests failed" },
                { id: "b0", kind: "build", request: "Bigger text", state: "done", version: "v9", started: t0, finished: t1 },
                { id: "n1", kind: "notes", request: "What about Slack?", state: "done", started: t0 }
            ];
            const s = r.buildStatus();
            const ls = s.split("\n");
            compare(ls.length, 5, s);
            verify(ls[0].indexOf("queued: \"Show the time\"") >= 0, ls[0]);
            verify(ls[1].indexOf("building for 3 min") >= 0 && ls[1].indexOf("(the change card c0)") > 0, ls[1]);
            verify(ls[2].indexOf("failed after 2 min: test/run.sh failed: 3 tests failed") >= 0, ls[2]);
            verify(ls[3].indexOf("done, built version v9") >= 0, ls[3]);
            verify(ls[4].indexOf("c2: proposed, not built yet") >= 0, ls[4]);
            verify(s.indexOf("Slack") < 0, "builds only");
            // a card whose job the server no longer lists: its own state, the error short
            r.buildJobs = [];
            const t = r.transcript();
            verify(t.indexOf("(app change, failed: test/run.sh failed: 3 tests failed in tst_app.qml and more.") >= 0, t);
            verify(r.buildStatus().split("\n")[1].length < 300, r.buildStatus());
            // and it goes with the request
            const bodies = [];
            r.jobPoster = (body, p) => bodies.push(body);
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            stroke(r, [[200, 1200], [500, 1220]]);
            r.ask();
            tryVerify(() => bodies.length === 1, 5000);
            const text = JSON.stringify(bodies[0].messages);
            verify(text.indexOf("Recent builds of app changes") >= 0 && text.indexOf("c2: proposed, not built yet") >= 0, text.slice(0, 1500));
            verify(bodies[0].system.indexOf("queued, building, done or failed") >= 0);
            r.pending = null;
            r.busy = false;
        }

        // an app change can be long; one that is cut short says so, on its
        // card and to the assistant
        function test_long_change() {
            const r = app.item;
            stroke(r, [[200, 300], [400, 350]]);
            let long = "";
            while (long.length < 5000) long += "Every sentence of this request matters to the developer. ";
            r.receive({ heard: "", items: [], app_change: long }, r.context());
            compare(r.replyItem(0).content, long.trim());
            compare(r.replyItem(0).changeNote, "");
            verify(r.transcript().indexOf(long.trim()) >= 0, "the whole request goes back to the assistant");
            verify(r.transcript().indexOf("cut short") < 0);
            r.receive({ heard: "", items: [], app_change: "Make the pad bigger and also make the" }, r.context());
            verify(r.replyItem(1).changeNote.indexOf("mid-sentence") >= 0, r.replyItem(1).changeNote);
            verify(r.transcript().indexOf("This app change request is cut short") >= 0);
            r.receive({ heard: "", items: [], app_change: long.repeat(3) }, r.context());
            compare(r.replyItem(2).content.length, r.changeChars);
            verify(r.replyItem(2).changeNote.indexOf("longer than") >= 0);
            r.receive({ heard: "", items: [], app_change: "- a list\n- ending in an item" }, r.context());
            compare(r.replyItem(3).changeNote, "");
        }

        // the assistant's live calls: run by the app, their results sent back
        // in the next request, at most 5 a reply
        function test_live_calls() {
            const r = app.item;
            fakeWeb(r, {
                "https://html.duckduckgo.com/html/*": { text: '<div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=' +
                    encodeURIComponent("https://example.org/tides") + '&rut=x">Tides of Brittany</a>' +
                    '<a class="result__snippet">High tide at 14:02 in Brest.</a></div>' },
                "https://example.org/article": { text: articleHtml },
                "https://geocoding-api.open-meteo.com/*": { type: "application/json",
                    text: JSON.stringify({ results: [{ name: "Lyon", admin1: "Auvergne-Rhône-Alpes", country: "France", latitude: 45.75, longitude: 4.85 }] }) },
                "https://api.open-meteo.com/*": { type: "application/json", text: JSON.stringify({
                    current: { time: "2026-09-20T10:00", temperature_2m: 18.5, apparent_temperature: 18, relative_humidity_2m: 60,
                               precipitation: 0, weather_code: 2, wind_speed_10m: 9 },
                    daily: { time: ["2026-09-20", "2026-09-21"], weather_code: [2, 61], temperature_2m_max: [22, 19],
                             temperature_2m_min: [12, 11], precipitation_probability_max: [5, 80], precipitation_sum: [0, 6],
                             wind_speed_10m_max: [15, 25] } }) },
                "https://example.org/down": { error: "no connection to example.org" }
            });
            const bodies = [];
            r.jobPoster = (body, p) => bodies.push({ body: body, p: p });
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            stroke(r, [[200, 400], [500, 420]]);
            r.ask();
            tryVerify(() => bodies.length === 1, 5000);
            const first = bodies[0].body;
            verify(first.max_tokens >= 16000, "room for long items: " + first.max_tokens);
            compare(first.tools.map(t => t.name).join(","), "reply,web_search,fetch_url,weather,screenshot_url");
            verify(first.system.indexOf("web_search(query)") >= 0 && first.system.indexOf("live access failed") >= 0,
                   "the prompt tells the assistant about its tools");

            const p = bodies[0].p;
            r.answered(toolCalls([["web_search", { query: "tides Brest" }], ["weather", { place: "Lyon, France" }]]), p);
            verify(r.busy, "still answering");
            tryVerify(() => bodies.length === 2, 5000);
            let text = JSON.stringify(bodies[1].body.messages);
            verify(text.indexOf("Tides of Brittany") >= 0 && text.indexOf("https://example.org/tides") >= 0 &&
                   text.indexOf("High tide at 14:02") >= 0, "title, URL and snippet: " + text.slice(-800));
            verify(text.indexOf("Weather for Lyon") >= 0 && text.indexOf("rain chance 80 %") >= 0, "the forecast");
            verify(text.indexOf("3 more live calls") >= 0, "2 of 5 used");

            // a failure, an email address and more calls than are left
            r.answered(toolCalls([["fetch_url", { url: "https://example.org/down" }],
                                  ["web_search", { query: "reply to someone@example.com" }],
                                  ["fetch_url", { url: "https://example.org/article" }],
                                  ["fetch_url", { url: "https://example.org/other" }]]), p);
            tryVerify(() => bodies.length === 3, 5000);
            verify(!fetched.some(u => u.indexOf("example.com") >= 0 || u.indexOf("someone") >= 0), "the email address is not sent: " + fetched);
            verify(fetched.indexOf("https://example.org/other") < 0, "the sixth call is not run");
            const last = bodies[2].body;
            text = JSON.stringify(last.messages);
            verify(text.indexOf("ERROR: live access failed: no connection to example.org") >= 0, "the failure is said");
            verify(text.indexOf("ERROR: not sent: it has an email address") >= 0);
            verify(text.indexOf("The first paragraph of the article") >= 0 && text.indexOf("Accept cookies") < 0, "the page's readable text");
            verify(text.indexOf("No live calls are left") >= 0);
            compare(last.tools.length, 1, "only the reply tool now");

            r.answered({ content: [{ type: "tool_use", name: "reply", input: { heard: "tides", items: [
                { kind: "markdown", content: "High tide is at 14:02 (example.org).", place: "below" }] } }] }, p);
            verify(!r.busy);
            compare(r.replyCount(), 1);
            verify(r.status.indexOf("5 live calls") > 0, r.status);
        }

        // a web page on the paper: reader view, grey pictures, links with
        // their boxes, annotations
        function test_web_page_reader() {
            const r = app.item;
            fakeWeb(r, { "https://example.org/article": { text: articleHtml }, "https://example.org/pic.png": { png: true } });
            stroke(r, [[200, 300], [400, 320]]);
            r.receive({ heard: "show me the article", items: [
                { kind: "markdown", content: "Here is the article:", place: "below" },
                { kind: "web", content: "https://example.org/article", place: "below" }] }, r.context());
            tryVerify(() => r.replyCount() === 2, 5000);
            const it = r.replyItem(1);
            compare(it.kind, "web");
            compare(it.mode, "reader");
            compare(it.title, "A test article");
            compare(it.site, "Example News");
            const md = it.content;
            verify(md.indexOf("## Section two") >= 0 && md.indexOf("- First point") >= 0, md);
            verify(md.indexOf("| City | Rain |") >= 0 && md.indexOf("| Lyon | 2 mm |") >= 0, md);
            verify(md.indexOf("[the next page](https://example.org/next)") >= 0, md);
            for (const junk of ["Home", "About us", "cookies", "Buy now", "Subscribe", "Copyright"])
                verify(md.indexOf(junk) < 0, "no " + junk + ": " + md);
            compare(it.webState, "end");

            // the picture: grey, at most 888 px wide
            const imgs = JSON.parse(it.imgs);
            compare(imgs.length, 1);
            compare(imgs[0].src, "https://example.org/pic.png");
            verify(imgs[0].w <= 888 && imgs[0].w > 0);
            const grey = r.greyCached(imgs[0].src);
            verify(grey && grey.data.indexOf("data:image/") === 0);
            probe.source = grey.data;
            tryVerify(() => probe.status === Image.Ready);
            const g = grabImage(probe);
            for (const x of [50, 350]) {
                const c = g.pixel(x, 100);
                verify(Math.abs(c.r - c.g) < 0.05 && Math.abs(c.g - c.b) < 0.05, "grey: " + c);
            }
            probe.source = "";

            // the page's title and source show; the link has its box
            const box = r.itemBox(1);
            verify(box.h > 300, "the page is laid out: " + box.h);
            const links = r.linksOf(it);
            const next = links.find(l => l.href === "https://example.org/next");
            verify(next, JSON.stringify(links));
            verify(next.x1 - next.x0 > 60 && next.y1 - next.y0 > 20 && next.y0 > 100, JSON.stringify(next));

            // a circle round the link: the next ask has its address
            const p = r.pageView();
            p.contentY = Math.max(0, box.y + next.y0 - 400);
            wait(50);
            const sx0 = box.x + next.x0 - 14, sx1 = box.x + next.x1 + 14;
            const sy0 = screenY(r, box.y + next.y0 - 10), sy1 = screenY(r, box.y + next.y1 + 10);
            stroke(r, [[sx0, sy0], [sx1, sy0], [sx1, sy1], [sx0, sy1], [sx0, sy0 + 4]]);
            const sent = r.context().sent;
            const marked = r.markedLinks(sent);
            compare(marked.length, 1, JSON.stringify(marked));
            compare(marked[0].href, "https://example.org/next");
            compare(marked[0].text, "the next page");
            const under = r.markedText(sent);
            verify(under.length === 1 && under[0].text.indexOf("the next page") >= 0, JSON.stringify(under));
            verify(r.linkText(marked, under).indexOf("The new ink marks the link \"the next page\" (https://example.org/next) on c1") >= 0);
            r.clearInk();

            // an underline marks it too
            const uy = screenY(r, box.y + next.y1 + 2);
            stroke(r, [[box.x + next.x0 + 4, uy], [box.x + next.x1 - 4, uy + 3]]);
            compare(r.markedLinks(r.context().sent).map(l => l.href).join(), "https://example.org/next");
            r.clearInk();

            // a finger tap on the link chooses it for the next ask
            const tx = box.x + (next.x0 + next.x1) / 2, ty = box.y + (next.y0 + next.y1) / 2 - p.contentY;
            const t = touchEvent(p);
            t.press(0, p, tx, ty).commit();
            t.release(0, p, tx, ty).commit();
            tryVerify(() => r.chosenLink !== null, 1000);
            compare(r.chosenLink.href, "https://example.org/next");
            compare(r.inkCount(), 1, "the tap wrote nothing");

            // the page is kept with the page
            r.savePage();
            wait(100);
            r.restorePage({ strokes: [], items: [], turns: [] });
            r.loadPage();
            tryVerify(() => r.replyCount() === 2);
            compare(r.linksOf(r.replyItem(1)).length, links.length);
            verify(r.transcript().indexOf("web page \"A test article\", https://example.org/article") > 0, r.transcript());
        }

        // a long page shows its first part and a Continue mark; a tick on it
        // loads the next part below
        function test_web_page_continue() {
            const r = app.item;
            let html = "<html><head><title>Long read</title></head><body><article><h1>Long read</h1>";
            for (let k = 1; k <= 12; k++) html += "<p>Paragraph " + k + " of the long read, with some words to make it a real paragraph of text.</p>";
            fakeWeb(r, { "https://example.org/long": { text: html + "</article></body></html>" } });
            r.partChars = 400;
            stroke(r, [[200, 300], [400, 320]]);
            r.receive({ heard: "", items: [{ kind: "web", content: "example.org/long", place: "below" }] }, r.context());
            tryVerify(() => r.replyCount() === 1, 5000);
            const it = r.replyItem(0);
            compare(it.webState, "more");
            verify(it.content.indexOf("Paragraph 1 ") >= 0 && it.content.indexOf("Paragraph 12") < 0, it.content);
            const mark = r.webDelegate(0).markBox();
            verify(mark, "the Continue mark shows");
            const p = r.pageView();
            p.contentY = Math.max(0, mark.y0 - 600);
            wait(50);
            // a tick on the mark: not kept as ink, not an ask
            const x = mark.x0 + 30, y = screenY(r, mark.y0 + 10);
            const asks = r.asks;
            stroke(r, [[x, y], [x + 15, y + 15], [x + 30, y + 30], [x + 60, y - 10], [x + 90, y - 50], [x + 120, y - 90]]);
            compare(r.inkCount(), 1, "the tick is not kept");
            compare(r.asks, asks);
            tryVerify(() => r.replyCount() === 2, 5000);
            compare(r.replyItem(0).webState, "continued");
            const two = r.replyItem(1);
            compare(two.kind, "web");
            compare(two.part, 1);
            verify(two.content.indexOf("Paragraph 1 ") < 0 && two.content.length > 50, two.content);
            verify(r.itemBox(1).y >= r.itemBox(0).y + r.itemBox(0).h, "below the first part");
        }

        // screenshot mode: a grey picture of the page, from the screenshot
        // service
        function test_web_page_screenshot() {
            const r = app.item;
            fakeWeb(r, { "https://api.microlink.io/*": { png: true } });
            stroke(r, [[200, 300], [400, 320]]);
            r.receive({ heard: "", items: [{ kind: "web", mode: "screenshot", content: "https://example.org/map", place: "below" }] }, r.context());
            tryVerify(() => r.replyCount() === 1, 5000);
            const it = r.replyItem(0);
            compare(it.mode, "screenshot");
            verify(fetched[0].indexOf("url=" + encodeURIComponent("https://example.org/map")) > 0, fetched[0]);
            const imgs = JSON.parse(it.imgs);
            compare(imgs.length, 1);
            verify(r.greyCached(imgs[0].src).data.length > 100);
            // a page that cannot be opened says so, and makes nothing up
            fakeWeb(r, {});
            r.receive({ heard: "", items: [{ kind: "web", content: "https://example.org/gone", place: "below" }] }, r.context());
            tryVerify(() => r.replyCount() === 2, 5000);
            compare(r.replyItem(1).kind, "failed");
            verify(r.replyItem(1).content.indexOf("Couldn't open this page") === 0, r.replyItem(1).content);
            verify(r.replyItem(1).failure.indexOf("HTTP 404") >= 0, r.replyItem(1).failure);
        }

        // a page that fails or never answers: a grey line in its place, the
        // other items all the same, and the next request says why
        function test_web_item_fails_alone() {
            const r = app.item;
            fakeWeb(r, { "https://example.org/article": { text: articleHtml }, "https://example.org/pic.png": { png: true },
                         "https://example.org/slow": { hang: true }, "https://example.org/down": { error: "no connection to example.org" } });
            r.pageTimeout = 1500;
            stroke(r, [[200, 300], [400, 320]]);
            r.receive({ heard: "three pages", items: [
                { kind: "markdown", content: "Three pages:", place: "below" },
                { kind: "web", content: "https://example.org/slow", place: "below" },
                { kind: "web", content: "https://example.org/down", place: "below" },
                { kind: "markdown", content: "And a last word.", place: "below" },
                { kind: "web", content: "https://example.org/article", place: "below" }] }, r.context());
            compare(r.replyCount(), 1, "the text before the first page shows at once");
            tryVerify(() => r.replyCount() === 5, 6000);
            compare(r.replyItem(1).kind, "failed");
            compare(r.replyItem(1).content, "Couldn't open this page (example.org/slow)");
            verify(r.replyItem(1).failure.indexOf("did not open within 2 s") >= 0, r.replyItem(1).failure);
            compare(r.replyItem(2).kind, "failed");
            compare(r.replyItem(2).failure, "no connection to example.org");
            compare(r.replyItem(3).content, "And a last word.");
            // two pages a reply: the third is not opened, and says so
            compare(r.replyItem(4).kind, "failed");
            verify(r.replyItem(4).failure.indexOf("at most 2 pages") >= 0, r.replyItem(4).failure);
            verify(fetched.indexOf("https://example.org/article") < 0);
            // a short line, in order, below one another
            for (let i = 1; i < 5; i++) verify(r.itemBox(i).y >= r.itemBox(i - 1).y + r.itemBox(i - 1).h, "item " + i);
            verify(r.itemBox(1).h > 10 && r.itemBox(1).h < 50, "one line: " + r.itemBox(1).h);
            verify(!r.webBusy);

            // the next request tells the assistant which and why
            verify(r.transcript().indexOf("a web page that did not open: https://example.org/down, reader view, because no connection") > 0,
                   r.transcript());
            const bodies = [];
            r.jobPoster = (body, p) => bodies.push({ body: body, p: p });
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            stroke(r, [[200, 1200], [400, 1220]]);
            r.ask();
            tryVerify(() => bodies.length === 1, 5000);
            const text = JSON.stringify(bodies[0].body.messages);
            verify(text.indexOf("Items of your last reply that failed") >= 0, text.slice(0, 3000));
            verify(text.indexOf("- c2: the web page https://example.org/down (reader view) did not open: no connection to example.org.") >= 0);
            verify(bodies[0].body.system.indexOf("If a page does not open") >= 0);
            r.answered(toolCalls([["reply", { heard: "", items: [{ kind: "markdown", content: "The page did not answer.", place: "below" }] }]]), bodies[0].p);
            verify(!r.busy);
            compare(r.replyCount(), 6);

            // an error in the app's reader fails that page at once
            r.pageTimeout = 60000;
            web["https://example.org/broken"] = { text: null };
            r.receive({ heard: "", items: [{ kind: "web", content: "https://example.org/broken", place: "below" }] }, r.context());
            tryVerify(() => r.replyCount() === 7, 2000);
            compare(r.replyItem(6).kind, "failed");
            verify(r.replyItem(6).failure.indexOf("the app could not read it") === 0, r.replyItem(6).failure);
        }

        // a Folio closed while a reply's pages open opens them again
        function test_web_item_after_reopen() {
            const r = app.item;
            fakeWeb(r, { "https://example.org/article": { hang: true } });
            stroke(r, [[200, 300], [400, 320]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "The article:", place: "below" },
                                           { kind: "web", content: "https://example.org/article", place: "below" }] }, r.context());
            compare(r.replyCount(), 1);
            const st = JSON.parse(JSON.stringify(r.pageState()));
            compare(st.opening.length, 1);
            r.restorePage({ strokes: [], items: [], turns: [] });
            fakeWeb(r, { "https://example.org/article": { text: articleHtml }, "https://example.org/pic.png": { png: true } });
            r.restorePage(st);
            tryVerify(() => r.replyCount() === 2, 5000);
            compare(r.replyItem(1).kind, "web");
            compare(r.replyItem(1).title, "A test article");
            compare(r.pageState().opening.length, 0);
        }

        // a reply cut off at the output limit says so; a long change request
        // shows whole
        function test_cut_off_reply() {
            const r = app.item;
            stroke(r, [[200, 300], [400, 320]]);
            const ctx = r.context();
            let long = "";
            for (let k = 1; k <= 30; k++) long += "Sentence " + k + " of the change request, which is long. ";
            r.pending = { id: "j", started: Date.now(), who: "Sonnet, medium", ctx: ctx, calls: [] };
            r.answered({ stop_reason: "max_tokens", content: [{ type: "tool_use", name: "reply", input: {
                heard: "change", items: [{ kind: "markdown", content: "Here is the request.", place: "below" }], app_change: long } }] }, r.pending);
            compare(r.replyCount(), 3);
            verify(r.replyItem(1).content.indexOf("cut off") >= 0, r.replyItem(1).content);
            const card = r.replyItem(2);
            compare(card.kind, "change");
            compare(card.content, long.trim());
            verify(card.changeNote.indexOf("cut off") >= 0);
            verify(r.status.indexOf("cut off at the output limit") > 0, r.status);
            // all 30 sentences show: no elided lines
            verify(r.itemBox(2).h > 600, "the whole request, not 12 lines: " + r.itemBox(2).h);
        }

        // one slim row at the top, nothing in the lower part of the screen;
        // Hide leaves a tab that brings it back
        function test_toolbar_hides() {
            const r = app.item;
            const bar_ = findChild(r, "toolbar"), tab = findChild(r, "barTab"), p = r.pageView();
            for (const name of ["askButton", "undoButton", "eraserButton", "moreButton", "closeButton"]) {
                const b = findChild(r, name);
                verify(b && b.visible, name);
                verify(b.height >= 60 && b.width >= 60, name + " is large enough");
                const y = b.mapToItem(r, 0, 0).y;
                verify(y >= 0 && y + b.height <= bar, name + " is in the bar at the top");
                verify(b.mapToItem(r, 0, 0).x + b.width <= r.width, name + " fits on the screen");
            }
            compare(p.y + p.height, r.height, "the page runs to the bottom of the screen");
            mouseClick(findChild(r, "moreButton"));
            mouseClick(findChild(r, "hideButton"));
            verify(!r.barShown && !bar_.visible);
            verify(tab.visible, "a tab at the top edge");
            compare(p.y, 0, "the page takes the room");
            verify(tab.mapToItem(r, 0, 0).y + tab.height <= 60);
            mouseClick(tab, tab.width / 2, tab.height - 10);
            verify(r.barShown && bar_.visible);
            compare(p.y, bar);
        }

        // Latest goes to the end of the page
        function test_jump_to_latest() {
            const r = app.item;
            stroke(r, [[100, 300], [300, 320]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "far down", place: "at", x: 36, y: 6000, width: 600 }] }, r.context());
            const p = r.pageView();
            // seen once, so the marker is gone and Latest shows
            p.contentY = 5800;
            r.checkMarkers();
            p.contentY = 0;
            mouseClick(findChild(r, "latestButton"));
            verify(p.contentY < 6000 && p.contentY + p.height > 6100, "the newest part is on screen: " + p.contentY);
        }

        // a stroke that ends near the bottom of the screen scrolls the page
        // up a third of a screen, never while the pen touches it
        function test_room_to_write() {
            const r = app.item;
            const p = r.pageView();
            r.roomDelay = 150;
            stroke(r, [[200, 1100], [400, 1120]]);
            wait(400);
            compare(p.contentY, 0, "far from the bottom: the page stays");
            stroke(r, [[200, 1560], [400, 1590]]);
            // the pen touches again before the pause is over, and stays down
            mousePress(r, 450, 1570);
            wait(500);
            compare(p.contentY, 0, "not while the pen touches the screen");
            mouseMove(r, 470, 1580);
            mouseMove(r, 490, 1590);
            mouseRelease(r, 490, 1590);
            compare(p.contentY, 0, "not right as it lifts");
            tryVerify(() => Math.abs(p.contentY - Math.round(p.height / 3)) < 2, 3000, "a third of a screen: " + p.contentY);
            compare(r.inkCount(), 3);
            verify(p.contentY + p.height <= p.contentHeight, "blank paper below");
            // the pen lands while the page moves: it stops
            stroke(r, [[200, 1560], [400, 1590]]);
            tryVerify(() => p.contentY > Math.round(p.height / 3) + 5, 3000);
            mousePress(r, 450, 1500);
            const y = p.contentY;
            wait(300);
            compare(p.contentY, y, "the page does not move under the pen");
            mouseRelease(r, 450, 1500);
        }

        // a loop round a reply, then a question: the request is about it, and
        // the dashed loop goes once the reply is placed
        // Ask arms the lasso; the loop is the request, sent when it closes
        function test_loop_is_the_request() {
            const r = app.item;
            stroke(r, [[100, 300], [300, 340]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "The capital of France is Paris.", place: "below" }] }, r.context());
            const c = r.itemBox(0);
            const n = r.inkCount();
            const loop = () => [[c.x - 20, screenY(r, c.y - 20)], [c.x + 420, screenY(r, c.y - 20)], [c.x + 420, screenY(r, c.y + c.h + 20)],
                                [c.x - 20, screenY(r, c.y + c.h + 20)], [c.x - 20, screenY(r, c.y - 10)]];
            const dashes = () => {
                const g = grabImage(r);
                let k = 0;
                for (let x = c.x; x < c.x + 400; x += 2) if (!Qt.colorEqual(g.pixel(x, screenY(r, c.y - 20)), "white")) k++;
                return k;
            };
            const bodies = [];
            r.jobPoster = (body, p) => bodies.push({ body: body, p: p });
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            const ask = findChild(r, "askButton");
            verify(ask.enabledState, "Ask works with no new ink");
            // Undo cancels an armed Ask
            mouseClick(ask);
            verify(r.askArmed && r.lassoMode);
            compare(ask.label, "Whole page");
            r.undoStroke();
            verify(!r.askArmed && !r.lassoMode);
            compare(r.inkCount(), n, "and takes no ink");

            mouseClick(ask);
            stroke(r, loop());
            compare(r.inkCount(), n, "the loop is not ink");
            tryVerify(() => bodies.length === 1, 5000, "sent when the loop closes");
            verify(!r.askArmed && r.lassoId > 0);
            wait(100);
            const k = dashes();
            verify(k > 40 && k < 180, "a dashed outline: " + k);
            const content = bodies[0].body.messages[0].content;
            const text = content[0].text;
            const at = text.indexOf("The request: the user drew a loop");
            verify(at >= 0, text);
            const part = text.slice(at);
            verify(part.indexOf("c0: your markdown") >= 0 && part.indexOf("\"The capital of France is Paris.\"") >= 0, part);
            verify(part.indexOf("It holds no new ink") >= 0, part);
            verify(part.indexOf("i1") < 0, "not the ink outside the loop: " + part);
            verify(text.indexOf("There is no new ink since your last answer.") >= 0, text);
            verify(r.askCtx.jobs.some(j => j.loop), "an image of what the loop holds");
            compare(content.filter(x => x.type === "image").length, r.askCtx.jobs.length);
            verify(bodies[0].body.system.indexOf("The page is paper") >= 0, "the prompt explains the requests");
            r.answered({ content: [{ type: "tool_use", name: "reply", input: { heard: "", items: [
                { kind: "markdown", content: "It has been since 987.", place: "below" }] } }] }, bodies[0].p);
            compare(r.replyCount(), 2);
            verify(r.itemBox(1).y > c.y + c.h, "the answer goes below the loop: " + JSON.stringify(r.itemBox(1)));
            compare(r.lassoId, 0, "the loop goes once the answer is placed");
            wait(100);
            compare(dashes(), 0, "and its outline");
        }

        // new ink inside the loop is the question about the rest of it
        function test_question_inside_the_loop() {
            const r = app.item;
            r.receive({ heard: "", items: [{ kind: "markdown", content: "Water boils at 100 °C.", place: "below" }] }, r.context());
            const c = r.itemBox(0);
            // "why?" written under the reply, inside the loop
            stroke(r, [[c.x + 20, screenY(r, c.y + c.h + 30)], [c.x + 120, screenY(r, c.y + c.h + 60)]]);
            const bodies = [];
            r.jobPoster = (body, p) => bodies.push({ body: body, p: p });
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            r.armAsk();
            stroke(r, [[c.x - 20, screenY(r, c.y - 20)], [c.x + 500, screenY(r, c.y - 20)], [c.x + 500, screenY(r, c.y + c.h + 100)],
                       [c.x - 20, screenY(r, c.y + c.h + 100)], [c.x - 20, screenY(r, c.y - 10)]]);
            tryVerify(() => bodies.length === 1, 5000);
            const text = bodies[0].body.messages[0].content[0].text;
            verify(text.indexOf("The new ink inside it") >= 0 && text.indexOf("is the question") >= 0, text.slice(text.indexOf("The request")));
            verify(r.askCtx.jobs.some(j => j.fresh) && r.askCtx.jobs.some(j => j.loop), "the new ink and the loop");
        }

        // read once: what the agent saw in a drawing stays, also after a reopen
        function test_seen_is_kept() {
            const r = app.item;
            stroke(r, [[100, 300], [300, 500], [100, 500], [100, 300]]);
            let ctx = r.context();
            r.receive({ heard: "", items: [], seen: [{ id: "i1", text: "a triangle" }] }, ctx);
            verify(r.pageMap(r.context()).indexOf("i1: ink, turn 1, x 100–300, y 216–416, seen as: a triangle") >= 0, r.pageMap(r.context()));
            r.savePage();
            wait(100);
            gc();
            r.restorePage({ strokes: [], items: [], turns: [] });
            r.loadPage();
            tryVerify(() => r.pageMap(r.context()).indexOf("seen as: a triangle") >= 0, 3000, r.pageMap(r.context()));
        }

        // since your last answer: new ink, marks on items, erased ink
        function test_changes_since_last_answer() {
            const r = app.item;
            stroke(r, [[100, 300], [300, 340]]);
            r.receive({ heard: "", items: [{ kind: "markdown", content: "An answer.", place: "below" }] }, r.context());
            const c = r.itemBox(0);
            // erase the old ink, mark the answer
            r.eraser = true;
            stroke(r, [[100, 300], [200, 320], [300, 340]]);
            r.eraser = false;
            verify(r.erasedSince.length > 0, "the erase is recorded");
            stroke(r, [[c.x + 10, screenY(r, c.y + c.h / 2)], [c.x + 200, screenY(r, c.y + c.h / 2)]]);
            const ctx = r.context();
            ctx.erased = r.erasedSince;
            const t = r.changesText(ctx);
            verify(t.indexOf("- new ink i") >= 0, t);
            verify(t.indexOf("the new ink touches your items c0") >= 0, t);
            verify(t.indexOf("the user erased earlier ink at x") >= 0, t);
            // an ask takes the list with it
            r.jobPoster = (body, p) => {};
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            r.ask();
            tryVerify(() => r.erasedSince.length === 0, 3000);
            verify(r.askCtx.erased.length > 0);
        }

        // the page map is the whole page, and older turns are the summary
        function test_whole_page_map_and_summary() {
            const r = app.item;
            for (let k = 0; k < 14; k++)
                r.receive({ heard: "q" + k, items: [{ kind: "markdown", content: "Answer " + k + ".", place: "at", x: 36, y: 200 + k * 800, width: 600 }],
                            summary: k === 13 ? "Fourteen answers, numbered." : "" }, r.context());
            const map = r.pageMap(r.context());
            verify(map.indexOf("\"Answer 0.\"") >= 0 && map.indexOf("\"Answer 13.\"") >= 0, "the whole page: " + map);
            const tr = r.transcript();
            verify(tr.indexOf("Your summary of the page and of turns 1 to 2:\nFourteen answers, numbered.") === 0, tr.slice(0, 200));
            verify(tr.indexOf("Turn 1.") < 0 && tr.indexOf("Turn 14.") >= 0, "the recent turns follow");
        }

        // a reading: sent from the computer, read and marked, Done for the digest
        function test_reading_page() {
            const r = app.item;
            stroke(r, [[100, 300], [300, 340]]);
            const mainInk = r.inkCount();
            verify(!findChild(r, "titleRow").visible, "one page: no title row");
            r.mergeInbox([{ id: "d1abcdef01", title: "Rollout plan", from: "laptop", state: "new" }, { id: "d2old00000", title: "Old", state: "done" }]);
            compare(r.pagesIndex.length, 2, "a done document is not added");
            compare(r.toRead, 1);
            verify(findChild(r, "titleRow").visible, "the title row shows");
            r.pagesOpen = true;
            wait(50);
            compare(findChild(r, "pageList").count, 2);
            r.showPage("d1abcdef01");
            verify(r.readingPage && !r.pagesOpen);
            verify(!r.barShown, "no toolbar while reading");
            compare(r.inkCount(), 0, "a page of its own");
            // the server is not there in the tests: place the document by hand
            tryVerify(() => r.pageLoaded, 3000);
            r.placeDocument({ id: "d1abcdef01", title: "Rollout plan", from: "laptop", kind: "markdown",
                              content: "# Rollout\n\nShip the API first, then migrate the users.\n\n## Risks\n\nThe migration may be slow." });
            verify(r.replyCount() >= 1);
            const it = r.replyItem(0);
            compare(it.kind, "web");
            compare(it.url, "folio:doc/d1abcdef01");
            verify(r.pageMap(r.context()).indexOf("the document \"Rollout plan\" the user reads (sent from laptop)") >= 0, r.pageMap(r.context()));
            verify(findChild(r, "doneButton").visible, "Done is in the title row");
            verify(!findChild(r, "newButton").enabledState, "New page keeps the document");
            // a mark over the text
            wait(200);
            const d = r.webDelegate(0);
            const b = r.itemBox(0);
            const ty = b.y + b.h * 0.5;
            stroke(r, [[b.x + 20, screenY(r, ty)], [b.x + 400, screenY(r, ty)]]);
            const marks = r.docMarks(r.context());
            verify(marks.length === 1 && marks[0].indexOf("is over: \"") > 0, JSON.stringify(marks));
            // Done: the digest
            const bodies = [];
            r.jobPoster = (body, p) => bodies.push({ body: body, p: p });
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            r.doneReading();
            tryVerify(() => bodies.length === 1, 5000);
            const text = bodies[0].body.messages[0].content[0].text;
            verify(text.indexOf("The request: the user finished reading \"Rollout plan\" (sent from laptop)") >= 0, text.slice(text.indexOf("The request")));
            verify(text.indexOf("Ship the API first") > 0 && text.indexOf("Their marks over the document:\n- i1") > 0, "the document and the marks");
            r.answered({ content: [{ type: "tool_use", name: "reply", input: { heard: "", items: [], digest: "**Decision:** ship the API first." } }] }, bodies[0].p);
            const last = r.replyItem(r.replyCount() - 1);
            verify(last.kind === "markdown" && last.content.indexOf("## Your notes") === 0, last.content);
            compare(r.currentPage.state, "done");
            verify(!findChild(r, "doneButton").visible);
            // back to the conversation, as it was
            r.showPage("main");
            verify(!r.readingPage && r.barShown);
            tryVerify(() => r.inkCount() === mainInk, 3000, "the conversation's ink is back");
        }

        // on a reading page a finger tap at an edge turns a screen; the pages
        // are kept across a reopen
        function test_reading_edges_and_pages_kept() {
            const r = app.item;
            r.mergeInbox([{ id: "d3abcdef01", title: "Long read", state: "new" }]);
            r.showPage("d3abcdef01");
            tryVerify(() => r.pageLoaded, 3000);
            let md = "";
            for (let k = 0; k < 60; k++) md += "Paragraph " + k + " of a long read, with enough words to wrap on the page.\n\n";
            r.placeDocument({ id: "d3abcdef01", title: "Long read", kind: "markdown", content: md });
            wait(200);
            const p = r.pageView();
            p.contentY = 0;
            const down = findChild(r, "edgeDown");
            verify(down.visible);
            const t = touchEvent(down);
            t.press(0, down, down.width / 2, down.height / 2).commit();
            t.release(0, down, down.width / 2, down.height / 2).commit();
            tryVerify(() => p.contentY > p.height * 0.5, 2000, "a screen down: " + p.contentY);
            const y = p.contentY;
            const up = findChild(r, "edgeUp");
            const u = touchEvent(up);
            u.press(0, up, up.width / 2, up.height / 2).commit();
            u.release(0, up, up.width / 2, up.height / 2).commit();
            tryVerify(() => p.contentY < y, 2000, "and back up");
            // the list of pages, and which one is open, come back
            r.savePages();
            wait(100);
            gc();
            r.pagesIndex = [{ id: "main", kind: "main", title: "Conversation", state: "" }];
            r.loadPages(() => {});
            tryVerify(() => r.pagesIndex.length === 2 && r.pageId === "d3abcdef01", 3000, JSON.stringify(r.pagesIndex));
        }

        // a PDF to read: its pages as pictures from the server, and a mark on a
        // page read as the words under it
        function test_pdf_pages() {
            const r = app.item;
            r.serverToken = "st0k";
            const src = r.serverUrl + "/v1/inbox/pdf0000001/page/1";
            const pages = {};
            pages[src] = { png: true };
            fakeWeb(r, pages);
            let heads = null;
            const serve = r.fetcher;
            r.fetcher = (url, opts, done) => { heads = opts.headers; serve(url, opts, done); };
            r.mergeInbox([{ id: "pdf0000001", title: "Plan", state: "new" }]);
            r.showPage("pdf0000001");
            tryVerify(() => r.pageLoaded, 3000);
            r.placeDocument({ id: "pdf0000001", title: "Plan", kind: "pdf", pages: [{ w: 400, h: 200, words: [
                { t: "Ship", x0: 10, y0: 10, x1: 60, y1: 40 }, { t: "now", x0: 70, y0: 10, x1: 120, y1: 40 },
                { t: "later", x0: 10, y0: 150, x1: 80, y1: 180 }] }] });
            tryVerify(() => r.replyCount() === 1, 5000, "the page, placed");
            compare(heads && heads["x-api-key"], "st0k", "the page picture is fetched with the server's token");
            wait(200);
            const ib = r.webDelegate(0).imageBoxes()[0];
            verify(ib && ib.w > 0, JSON.stringify(ib));
            const s = ib.w / 400;
            // an underline under "Ship now" (no toolbar on a reading page)
            const pv = r.pageView(), top = pv.mapToItem(r, 0, 0).y - pv.contentY;
            const y = ib.y + 44 * s + top;
            stroke(r, [[ib.x + 8 * s, y], [ib.x + 124 * s, y]]);
            const marks = r.docMarks(r.context());
            verify(marks.length === 1 && marks[0].indexOf("is over: \"Ship now\"") > 0, JSON.stringify(marks));
            verify(r.docText().indexOf("Page 1: Ship now later") >= 0, r.docText());
            r.serverToken = "";
        }

        // Ask twice: the whole page; a tap cancels
        function test_whole_page_and_cancel() {
            const r = app.item;
            const bodies = [];
            r.jobPoster = (body, p) => bodies.push({ body: body, p: p });
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            const ask = findChild(r, "askButton");
            mouseClick(ask);
            verify(r.askArmed);
            r.fingerTap(400, 900);
            verify(!r.askArmed, "a finger tap cancels");
            compare(bodies.length, 0);
            stroke(r, [[100, 400], [300, 440]]);
            mouseClick(ask);
            mouseClick(ask);
            tryVerify(() => bodies.length === 1, 5000);
            compare(r.askCtx.request, "whole");
            const text = bodies[0].body.messages[0].content[0].text;
            verify(text.indexOf("The request: the user tapped Whole page") >= 0, text);
        }

        // a loop round the user's typed words: their text goes with it
        // a loop round the user's typed words: their text goes with it
        function test_lasso_round_ink() {
            const r = app.item;
            writeWords(r);
            r.receive({ heard: "hi there", items: [], typeset: [{ ids: ["n2"], text: "hi" }, { ids: ["n3"], text: "there" }] }, r.context());
            tryVerify(() => r.typedCount() === 2, 2000);
            const bodies = [];
            r.jobPoster = (body, p) => bodies.push({ body: body, p: p });
            r.apiKey = "test";
            r.baseUrl = "http://127.0.0.1:9";
            r.armAsk();
            // a tap is no loop: still armed
            mouseClick(r, 600, 900);
            verify(r.askArmed && bodies.length === 0);
            // round the second word only (page x 300–380, y 316–366)
            stroke(r, [[280, screenY(r, 300)], [400, screenY(r, 300)], [400, screenY(r, 390)], [280, screenY(r, 390)], [280, screenY(r, 305)]]);
            tryVerify(() => bodies.length === 1, 5000);
            const parts = r.askCtx.lasso.parts;
            compare(parts.length, 1, JSON.stringify(parts));
            compare(parts[0].id, "i1");
            compare(parts[0].text, "there");
            verify(parts[0].part, "a part of the region");
            // saved with the page until the answer comes
            const id = r.lassoId;
            verify(id > 0);
            r.savePage();
            wait(100);
            r.restorePage({ strokes: [], items: [], turns: [] });
            compare(r.lassoId, 0);
            r.loadPage();
            tryVerify(() => r.lassoId === id);
        }

        function test_markdown() {
            const h = Markdown.toHtml("The `a*b` x.\n\nUsage:\n```\n$ hostname\nmy-machine\n```\n\nAfter.\n\n- `hostname -f` → fqdn\n  - nested **bold**\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |");
            verify(h.indexOf("a*b") > 0, h);
            verify(h.indexOf("<pre") > 0 && h.indexOf("my-machine") > 0, h);
            verify(h.indexOf("<p>After.</p>") > 0, h);
            verify(h.indexOf("hostname&nbsp;-f</span> → fqdn") > 0, h);
            verify(h.indexOf("<ul><li>nested <b>bold</b>") > 0, h);
            verify(h.indexOf("<td>2</td>") > 0, h);
            verify(h.indexOf("`") < 0, h);
            compare(Markdown.toHtml("a <b> & c"), "<p>a &lt;b&gt; &amp; c</p>");
        }

        // Folio closed in the second it opened: its empty page must not
        // replace the saved one
        function test_no_save_before_load() {
            const r = app.item;
            r.receive({ heard: "", items: [{ kind: "markdown", content: "kept", place: "below" }] }, r.context());
            r.savePage();
            wait(100);
            gc();
            r.pageLoaded = false;
            r.newPage();
            r.savePage();
            wait(100);
            gc();
            let text = "";
            r.fileGet(r.dataDir + "/page.json", t => text = t);
            tryVerify(() => text !== "", 3000);
            verify(text.indexOf("kept") > 0, "the saved page stays: " + text.slice(0, 120));
            r.pageLoaded = true;
        }

        function test_server_config() {
            const r = app.item;
            const f = r.dataDir + "/folio.env";
            r.filePut(f, "ANTHROPIC_API_KEY=k\nANTHROPIC_BASE_URL=http://b:1/\nexport FOLIO_SERVER_URL='http://s:2/'\nFOLIO_SERVER_TOKEN=\"t0k\"\n");
            wait(100);
            gc();
            r.loadConfig(f);
            tryVerify(() => r.serverToken === "t0k", 3000, r.serverToken);
            compare(r.serverUrl, "http://s:2");
            compare(r.baseUrl, "http://b:1");
            r.serverUrl = "http://127.0.0.1:18082";
            r.serverToken = "";
        }

        // ink stays ink: an old "typed" setting does not come back, a new one does
        function test_type_setting_migration() {
            const r = app.item;
            r.showType = false;
            r.filePut(r.dataDir + "/settings.json", JSON.stringify({ type: true, send: "pause", pause: 4 }));
            wait(100);
            gc();
            r.loadSettings();
            wait(300);
            verify(!r.showType, "settings before v2: ink stays ink");
            r.filePut(r.dataDir + "/settings.json", JSON.stringify({ v: 2, type: true }));
            wait(100);
            gc();
            r.loadSettings();
            tryVerify(() => r.showType, 3000, "a choice made since");
            r.showType = true;
        }

        // settings saved before the layer value was renamed still load
        function test_old_layer_setting() {
            const r = app.item;
            r.filePut(r.dataDir + "/settings.json", JSON.stringify({ layers: "claude" }));
            // a PUT reads back empty until its request is collected
            wait(100);
            gc();
            r.loadSettings();
            tryVerify(() => r.layers === "replies", 3000, r.layers);
            r.layers = "both";
        }

        // the backend passes Folio's log lines on; each ask reports them
        function test_self_report() {
            const r = app.item;
            // the tablet writes +00:00, other journals +0000
            const now = new Date(Date.now() - 60000).toISOString().slice(0, 19) + "+00:00";
            const old = new Date(Date.now() - 3 * 24 * 3600 * 1000).toISOString().slice(0, 19) + "+0000";
            verify(r.selfReport().indexOf("no errors") > 0, r.selfReport());
            const backend = findChild(r, "backend");
            backend.messageReceived(102, now + " imx93-chiappa xochitl[4702]: 21:28:52.039 default                  " +
                "file:///home/root/.local/share/claude-app/code/v15/markdown.js:263: TypeError: Cannot read property 'role' of undefined " +
                "(file:///home/root/.local/share/claude-app/code/v15/markdown.js:263)");
            backend.messageReceived(102, now + " imx93-chiappa xochitl[4702]: 21:28:52.039 default                  " +
                "file:///home/root/.local/share/claude-app/code/v15/markdown.js:263: TypeError: Cannot read property 'role' of undefined " +
                "(file:///home/root/.local/share/claude-app/code/v15/markdown.js:263)");
            backend.messageReceived(102, old + " imx93-chiappa systemd[1]: xochitl.service: Main process exited, code=dumped, status=6/ABRT");
            const s = r.selfReport();
            verify(s.indexOf("code/v15/markdown.js:263: TypeError: Cannot read property 'role' of undefined\n") > 0, s);
            compare(s.split("markdown.js:263").length, 2, "the backend's resend is not a second line");
            verify(s.indexOf("Main process exited") < 0, "older than a day");
            verify(s.indexOf("version ") > 0 && s.indexOf(" effort") > 0, s);
            backend.messageReceived(102, new Date(Date.now() - 30000).toISOString().slice(0, 19) + "+0000 imx93-chiappa xochitl[4702]: " +
                "21:30:00.000 qml                      Folio: version v99 failed to load, running the built-in copy (expression for onStatusChanged qrc:/ABCDEFGHIJ/ui/loader.qml:52)");
            const s2 = r.selfReport();
            verify(s2.indexOf(" UTC: Folio: version v99 failed to load, running the built-in copy\n") > 0, s2);
            verify(s2.indexOf("imx93") < 0, "parsed, not the raw line");
        }

        function test_install_rotates_slots() {
            const r = app.item;
            const keep = [r.dataDir, r.slot];
            r.dataDir = Qt.resolvedUrl(".").toString() + "tmp/data";
            r.slot = "s0";
            compare(r.nextSlot(), "s1", "never the slot that runs");
            gc();
            r.slot = "s1";
            compare(r.nextSlot(), "s0", "s2..s7 have no SLOT file, so they are skipped");
            r.dataDir = Qt.resolvedUrl(".").toString() + "tmp/code-none";
            r.slot = "a";
            compare(r.nextSlot(), "b", "without the slots, a and b as before");
            r.dataDir = keep[0];
            r.slot = keep[1];
        }

        function test_reader_page_without_article() {
            const para = "<p>" + "Sunrise over the hills, photographed at dawn. ".repeat(12) + "</p>";
            const page = Markdown.fromHtml("<html><head><title>Sunrise</title></head><body>loose text" +
                "<div>more loose text" + para + "<img src='/sun.jpg' width='800' height='600'></div></body></html>",
                "https://example.org/sunrise");
            verify(page, "a page without <article> or <main> is read");
        }

        // Wikipedia: JSON with ">" in attributes, an infobox with a portrait,
        // [edit] links and citation marks
        function test_reader_wikipedia() {
            const para = "<p><b>Marilyn Monroe</b> was an American actress<sup class=\"reference\"><a href=\"#cite_note-1\">[1]</a></sup>. " +
                "She was a model and a singer, and one of the most popular sex symbols of the 1950s and early 1960s. ".repeat(4) + "</p>";
            const page = Markdown.fromHtml("<html><head><title>Marilyn Monroe - Wikipedia</title></head><body>" +
                "<main id=\"content\"><div class=\"mw-body-content\"><div class=\"mw-parser-output\">" +
                "<table class=\"infobox\" data-mw='{\"parts\":[{\"x\":\"<ref>a</ref> > b\"}]}'><tr><th colspan=\"2\">Marilyn Monroe</th></tr>" +
                "<tr><td colspan=\"2\"><img src=\"//upload.example.org/Monroe.jpg\" width=\"250\" height=\"367\"></td></tr>" +
                "<tr><th>Born</th><td>June 1, 1926</td></tr></table>" + para +
                "<div class=\"mw-heading mw-heading2\"><h2>Life</h2><span class=\"mw-editsection\">[<a href=\"/w/index.php?action=edit\">edit</a>]</span></div>" +
                para + "</div></div></main></body></html>", "https://en.wikipedia.org/wiki/Marilyn_Monroe");
            const md = page.markdown;
            verify(md.indexOf("![](https://upload.example.org/Monroe.jpg)") >= 0, md);
            verify(md.indexOf("![](https://upload.example.org/Monroe.jpg)") < md.indexOf("| Born | June 1, 1926 |"), md);
            verify(md.indexOf("parts") < 0 && md.indexOf("ref>") < 0, "no attribute text: " + md);
            verify(md.indexOf("edit") < 0 && md.indexOf("[1]") < 0 && md.indexOf("cite_note") < 0, md);
            verify(md.indexOf("## Life") >= 0 && md.indexOf("**Marilyn Monroe** was an American actress.") >= 0, md);
        }
    }
}

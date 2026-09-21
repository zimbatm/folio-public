import QtQuick
import QtTest

// test/shots.sh: renders each screen of the app offscreen, at the tablet's
// size, to PNGs for reviewing the layout. Offscreen only: grabToImage crashes
// xochitl on the tablet.
Item {
    width: 960
    height: 1696

    Loader {
        id: app
        anchors.fill: parent
        source: "../ui/main.qml"
    }

    TestCase {
        name: "shots"
        when: windowShown

        function stroke(r, points) {
            mousePress(r, points[0][0], points[0][1]);
            for (const [x, y] of points) mouseMove(r, x, y);
            const last = points[points.length - 1];
            mouseRelease(r, last[0], last[1]);
        }

        // block capitals, as tools/penwrite draws them
        readonly property var glyphs: ({"W":[[[0,0],[0.25,1],[0.5,0.4],[0.75,1],[1,0]]],"H":[[[0,0],[0,1]],[[1,0],[1,1]],[[0,0.5],[1,0.5]]],"A":[[[0,1],[0.5,0],[1,1]],[[0.25,0.5],[0.75,0.5]]],"T":[[[0,0],[1,0]],[[0.5,0],[0.5,1]]],"I":[[[0.5,0],[0.5,1]],[[0.2,0],[0.8,0]],[[0.2,1],[0.8,1]]],"S":[[[1,0.1],[0.7,0],[0.3,0],[0,0.2],[0.3,0.5],[0.7,0.5],[1,0.8],[0.7,1],[0.3,1],[0,0.9]]],"B":[[[0,1],[0,0],[0.7,0],[0.9,0.2],[0.7,0.5],[0,0.5]],[[0.7,0.5],[1,0.75],[0.7,1],[0,1]]],"U":[[[0,0],[0,0.8],[0.3,1],[0.7,1],[1,0.8],[1,0]]],"M":[[[0,1],[0,0],[0.5,0.6],[1,0],[1,1]]],"L":[[[0,0],[0,1],[1,1]]],"E":[[[1,0],[0,0],[0,1],[1,1]],[[0,0.5],[0.7,0.5]]],"?":[[[0.1,0.2],[0.3,0],[0.7,0],[0.9,0.2],[0.5,0.5],[0.5,0.75]],[[0.5,0.95],[0.52,1]]]})
        function write(r, text, x0, y0) {
            let x = x0;
            for (const ch of text) {
                if (ch === " ") { x += 30; continue; }
                for (const s of glyphs[ch]) {
                    const pts = s.map(p => [Math.round(x + p[0] * 34), Math.round(y0 + p[1] * 54)]);
                    if (pts.length === 1) pts.push([pts[0][0] + 2, pts[0][1] + 2]);
                    stroke(r, pts);
                }
                x += 48;
            }
        }

        function shot(name) {
            wait(150);
            let done = false;
            app.item.grabToImage(res => { res.saveToFile(Qt.resolvedUrl("shots/" + name + ".png").toString().replace("file://", "")); done = true; });
            tryVerify(() => done, 5000);
        }

        function test_shots() {
            const r = app.item;
            r.dataDir = Qt.resolvedUrl("tmp").toString();
            r.newPage();
            r.sendMode = "button";
            shot("01-empty");

            write(r, "WHAT IS A", 60, 170);
            write(r, "BUMBLEBEE?", 60, 250);
            const bee = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 220'>" +
                "<ellipse cx='150' cy='70' rx='60' ry='38' fill='#eeeeee' stroke='#555' stroke-width='3'/>" +
                "<ellipse cx='240' cy='60' rx='55' ry='34' fill='#eeeeee' stroke='#555' stroke-width='3'/>" +
                "<ellipse cx='200' cy='140' rx='120' ry='62' fill='#cccccc' stroke='#333' stroke-width='4'/>" +
                "<rect x='150' y='80' width='30' height='120' fill='#333'/><rect x='220' y='80' width='30' height='120' fill='#333'/>" +
                "<circle cx='85' cy='140' r='34' fill='#555'/><circle cx='75' cy='130' r='7' fill='#fff'/>" +
                "<path d='M320 140 L350 140' stroke='#333' stroke-width='5'/></svg>";
            r.receive({ heard: "Wrote: \"what is a bumblebee?\"", items: [
                { kind: "markdown", place: "below", content: "**Bumblebees** are large, hairy bees of the genus *Bombus*.\n\n- About 250 species\n- They live in small colonies\n- They can fly in cold weather" },
                { kind: "svg", place: "below", content: bee }
            ], app_change: "Show the Latin name under each drawing of an animal." }, r.context());
            r.status = "12 s · Opus, high";
            shot("02-page");

            r.busy = true;
            r.status = "Asking Opus…";
            shot("03-busy");
            r.busy = false;
            r.status = "Failed: cannot reach the assistant at http://127.0.0.1:18081. The ink is kept: ask again.";
            shot("04-failed");
            r.status = "";

            r.notesOpen = true;
            r.notes = "- Likes short answers with a drawing.\n- Writes in English and French.\n- Prefers metric units.";
            shot("05-more");
            r.notesOpen = false;

            r.status = "";
            r.pageView().contentY = 0;
            r.receive({ heard: "", items: [{ kind: "markdown", content: "far down", place: "at", x: 36, y: 4000, width: 600 }] }, r.context());
            r.pageView().contentY = 0;
            shot("06-scrolled-up");

            r.openActivity("", "more");
            const t0 = new Date(Date.now() - 125000).toISOString();
            r.activityJobs = [
                { id: "b1", kind: "build", request: "Show the Latin name under each drawing of an animal.", state: "running", started: t0, lines: 2 },
                { id: "n1", kind: "notes", request: "When did I note the plumber's number?", state: "done", started: t0, finished: new Date(Date.now() - 100000).toISOString(), lines: 3 }
            ];
            wait(400);
            r.activityError = "";
            shot("07-activity");
            r.showJob("b1");
            r.activityLines = [{ n: 1, t: t0, text: "Fetching the newest code" }, { n: 2, t: t0, text: "The agent starts (opus, high effort)" }, { n: 3, t: t0, text: "Read ARCHITECTURE.md" }, { n: 4, t: new Date(Date.now() - 60000).toISOString(), text: "Search: kind === \"svg\"" }, { n: 5, t: new Date().toISOString(), text: "Edit ui/main.qml" }];
            wait(400);
            r.activityError = "";
            shot("08-activity-log");
            r.activityOpen = false;

            r.lassoMode = true;
            shot("09-lasso");
            r.lassoMode = false;

            r.setBar(false);
            shot("10-bar-hidden");
            r.setBar(true);
        }
    }
}

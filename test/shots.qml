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

            stroke(r, [[120, 260], [160, 330], [200, 260], [240, 330], [280, 260]]);
            r.receive({ heard: "Wrote: \"what is a bumblebee\"", items: [
                { kind: "markdown", place: "below", content: "**Bumblebees** are large, hairy bees of the genus *Bombus*.\n\n- About 250 species\n- They live in small colonies\n- They can fly in cold weather" }
            ], app_change: "Make the buttons bigger and move Ask next to the pen hand." }, r.context());
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
                { id: "b1", kind: "build", request: "Make the buttons bigger and move Ask next to the pen hand.", state: "running", started: t0, lines: 2 },
                { id: "n1", kind: "notes", request: "What about Slack?", state: "done", started: t0, finished: new Date(Date.now() - 100000).toISOString(), lines: 3 }
            ];
            shot("07-activity");
            r.showJob("b1");
            r.activityLines = [{ n: 1, t: t0, text: "Fetching the newest code" }, { n: 2, t: new Date().toISOString(), text: "Read ui/main.qml" }];
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

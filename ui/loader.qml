import QtQuick

// The fixed entry point. QML XHR cannot write binary files or create
// directories, so updates cannot replace resources.rcc from the tablet. They
// land as text in one of two slots that build.sh creates, code/a and code/b:
// main.qml (+ its .js) and VERSION. code/current names the slot to run; empty
// means the copy built into this rcc, and so does anything that fails to load.
Item {
    id: root
    anchors.fill: parent

    signal close
    function unloading() {
        if (app.item && app.item.unloading) app.item.unloading();
    }

    property string codeDir: "file:///home/root/.local/share/claude-app/code/"
    readonly property url builtIn: Qt.resolvedUrl("main.qml")
    property string slot: ""
    property string version: ""
    property alias app: app

    function readText(url) {
        try {
            const x = new XMLHttpRequest();
            x.open("GET", url, false);
            x.send();
            return x.responseText.trim();
        } catch (e) {
            return "";
        }
    }

    function boot() {
        const v = readText(codeDir + "current");
        if (/^[A-Za-z0-9._-]+$/.test(v)) {
            slot = v;
            version = readText(codeDir + v + "/VERSION") || v;
            app.source = codeDir + v + "/main.qml";
        } else {
            slot = "";
            version = "";
            app.source = builtIn;
        }
    }

    Loader {
        id: app
        anchors.fill: parent
        onStatusChanged: {
            if (status === Loader.Error && source !== root.builtIn) {
                console.log("Folio: version " + root.version + " failed to load, running the built-in copy");
                root.slot = "";
                root.version = "";
                source = root.builtIn;
            }
        }
        onLoaded: {
            if (item.version !== undefined) item.version = root.version || "built-in";
            if (item.slot !== undefined) item.slot = root.slot;
        }
    }

    Connections {
        target: app.item
        ignoreUnknownSignals: true
        function onClose() { root.close(); }
    }

    Component.onCompleted: boot()
}

import QtQuick

// one level up: More from Activity, the job list from a job's log. The
// chevron is drawn: the tablet's fonts lack most arrows
Rectangle {
    id: back
    property alias label: backLabel.text
    signal clicked
    width: backLabel.implicitWidth + 96
    height: 76
    radius: 38
    color: "white"
    border.color: "black"
    border.width: 3
    Canvas {
        x: 26
        anchors.verticalCenter: parent.verticalCenter
        width: 18
        height: 30
        onPaint: {
            const ctx = getContext("2d");
            ctx.strokeStyle = "black";
            ctx.lineWidth = 4;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            ctx.beginPath();
            ctx.moveTo(15, 3); ctx.lineTo(3, 15); ctx.lineTo(15, 27);
            ctx.stroke();
        }
    }
    Text {
        id: backLabel
        x: 60
        anchors.verticalCenter: parent.verticalCenter
        font.pixelSize: 30
    }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -10
        onClicked: back.clicked()
    }
}

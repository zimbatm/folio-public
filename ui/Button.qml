import QtQuick

Rectangle {
    id: btn
    property alias label: lbl.text
    property bool primary: false
    property bool enabledState: true
    signal clicked
    width: Math.max(150, lbl.implicitWidth + 60)
    height: 76
    radius: 38
    color: primary && enabledState ? "black" : "white"
    border.color: enabledState ? "black" : "#999999"
    border.width: 3
    Text {
        id: lbl
        anchors.centerIn: parent
        font.pixelSize: 30
        font.bold: btn.primary
        color: btn.primary && btn.enabledState ? "white" : (btn.enabledState ? "black" : "#999999")
    }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -10
        onClicked: if (btn.enabledState) btn.clicked()
    }
}

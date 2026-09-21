import QtQuick

// a button of the toolbar: slim, all of them the same width
Rectangle {
    id: bb
    property alias label: bl.text
    property bool primary: false
    property bool enabledState: true
    signal clicked
    height: 64
    radius: 32
    color: primary && enabledState ? "black" : "white"
    border.color: enabledState ? "black" : "#999999"
    border.width: 3
    Text {
        id: bl
        anchors.centerIn: parent
        width: parent.width - 14
        horizontalAlignment: Text.AlignHCenter
        font.pixelSize: 26
        fontSizeMode: Text.HorizontalFit
        minimumPixelSize: 16
        font.bold: bb.primary
        color: bb.primary && bb.enabledState ? "white" : (bb.enabledState ? "black" : "#999999")
    }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -4
        onClicked: if (bb.enabledState) bb.clicked()
    }
}

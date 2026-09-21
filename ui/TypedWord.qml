import QtQuick

// a word of the user's handwriting as type, where its ink was: centred on
// the ink, as wide as it at most
Text {
    property real wx
    property real wy
    property real ww
    property real wh
    property real size: 30
    x: wx
    y: wy + wh / 2 - height / 2
    width: Math.max(ww + size * 0.3, size)
    height: size * 1.3
    font.pixelSize: size
    fontSizeMode: Text.HorizontalFit
    minimumPixelSize: 14
    verticalAlignment: Text.AlignVCenter
    color: "black"
}

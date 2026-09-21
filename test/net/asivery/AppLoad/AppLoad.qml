import QtQuick

// stands in for AppLoad's C++ AppLoad type in tests
Item {
    property string applicationID
    signal messageReceived(int type, string contents)
    function sendMessage(type, contents) {}
    function terminate() {}
}

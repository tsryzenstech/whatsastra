// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick
import QtWebEngine
import Astra.Core
import Astra.Controls
import Astra.Animation

// WhatsAstra: WhatsApp for astraOS, on top of WhatsApp Web. Link the phone
// from WhatsApp › Linked devices on your main phone by scanning the QR code.
// Notifications (with the unread count), downloads to Files, attachments
// from your storage, zoom to fit the phone, dark mode, spell check.
// Not affiliated with WhatsApp or Meta.
Rectangle {
    id: app
    color: Theme.background

    readonly property string configPath: Files.appData + "/whatsastra.json"
    property real zoom: 0.62
    property bool notify: true
    property bool spellcheck: false
    property int unread: 0
    property bool ready: false
    property var pendingShare: null

    function loadConfig() {
        try {
            const c = JSON.parse(Files.readText(configPath) || "{}")
            zoom = c.zoom || 0.62
            notify = c.notify !== false
            spellcheck = !!c.spellcheck
        } catch (e) {}
    }
    function saveConfig() { Files.writeText(configPath, JSON.stringify({ zoom: zoom, notify: notify, spellcheck: spellcheck })) }

    Component.onCompleted: {
        loadConfig()
        Permissions.request("astra.permission.NOTIFICATIONS", function() {})
        handleShare(Application.args)
    }
    Connections {
        target: Application
        function onIntent(args) { app.handleShare(args) }
    }
    // Shared files and text: WhatsApp Web can't be filled in from outside,
    // so files wait in "Shared with WhatsAstra" at the top of the attach
    // picker, and text goes to the clipboard.
    function handleShare(args) {
        if (!args || args.action !== "share") return
        if (args.files && args.files.length) {
            pendingShare = args.files
            toast.show(qsTr("Open a chat and tap the clip to send what you shared."))
        } else if (args.text) {
            clip.text = args.text
            clip.selectAll()
            clip.copy()
            toast.show(qsTr("Copied: open a chat and paste it."))
        }
    }
    TextEdit { id: clip; visible: false }

    WebEngineProfile {
        id: profile
        storageName: "whatsastra"
        offTheRecord: false
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
        httpCacheType: WebEngineProfile.DiskHttpCache
        // WhatsApp Web serves only desktop browsers it knows.
        httpUserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        spellCheckEnabled: app.spellcheck
        spellCheckLanguages: [Qt.locale().name.replace("_", "-")]
        downloadPath: Files.home + "/Download"
        onDownloadRequested: (download) => {
            download.downloadDirectory = Files.home + "/Download"
            download.accept()
            toast.show(qsTr("Saving “%1” to Download").arg(download.downloadFileName))
        }
        onPresentNotification: (notification) => {
            if (app.notify && Qt.application.state !== Qt.ApplicationActive)
                Notifications.post(notification.title, notification.message)
            notification.show()
        }
    }

    WebEngineView {
        id: web
        anchors.fill: parent
        anchors.topMargin: Theme.statusBarHeight
        profile: profile
        url: "https://web.whatsapp.com/"
        zoomFactor: app.zoom
        backgroundColor: Theme.background
        settings.forceDarkMode: false
        settings.javascriptCanAccessClipboard: true
        settings.javascriptCanPaste: true
        settings.playbackRequiresUserGesture: false
        settings.focusOnNavigationEnabled: false
        onTitleChanged: {
            const m = /^\((\d+)\)/.exec(title)
            app.unread = m ? Number(m[1]) : 0
        }
        onLoadingChanged: (info) => {
            if (info.status === WebEngineView.LoadSucceededStatus) {
                app.ready = true
                // WhatsApp's own theme follows the system appearance.
                runJavaScript("try{localStorage.setItem('theme', '" + (Theme.light ? "\"light\"" : "\"dark\"") + "')}catch(e){}")
            }
        }
        onPermissionRequested: (permission) => {
            const t = permission.permissionType
            if (t === WebEnginePermission.PermissionType.Notifications) {
                permission.grant()
            } else if (t === WebEnginePermission.PermissionType.MediaAudioCapture) {
                Permissions.request("astra.permission.MICROPHONE", (ok) => ok ? permission.grant() : permission.deny())
            } else if (t === WebEnginePermission.PermissionType.MediaVideoCapture || t === WebEnginePermission.PermissionType.MediaAudioVideoCapture) {
                Permissions.request("astra.permission.CAMERA", (ok) => ok ? permission.grant() : permission.deny())
            } else if (t === WebEnginePermission.PermissionType.ClipboardReadWrite) {
                permission.grant()
            } else {
                permission.deny()
            }
        }
        onFileDialogRequested: (request) => {
            request.accepted = true
            picker.pick(request)
        }
        onNewWindowRequested: (request) => Packages.launch("com.astra.planet", { url: request.requestedUrl.toString() })
        onNavigationRequested: (request) => {
            // Links in chats open in Planet; WhatsApp itself stays here.
            const u = request.url.toString()
            if (request.isMainFrame && !/^https:\/\/(web\.)?whatsapp\.(com|net)\//.test(u) && !u.startsWith("blob:") && !u.startsWith("data:")) {
                request.reject()
                Packages.launch("com.astra.planet", { url: u })
            }
        }
        onRenderProcessTerminated: (status) => { if (status !== WebEngineView.NormalTerminationStatus) reloadTimer.start() }
        Timer { id: reloadTimer; interval: 1000; onTriggered: web.reload() }
    }

    // Splash while WhatsApp Web loads
    Rectangle {
        anchors.fill: parent
        visible: !app.ready
        color: "#0B141A"
        Column {
            anchors.centerIn: parent
            spacing: 18
            Image { anchors.horizontalCenter: parent.horizontalCenter; source: Qt.resolvedUrl("../icon.svg"); width: 96; height: 96; sourceSize: Qt.size(192, 192) }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "WhatsAstra"; font.family: Theme.fontFamily; font.pixelSize: 24; font.weight: Font.Bold; color: "white" }
            ProgressBar { anchors.horizontalCenter: parent.horizontalCenter; width: 160; value: web.loadProgress / 100 }
        }
    }

    // Menu button
    Rectangle {
        anchors.right: parent.right
        anchors.rightMargin: 10
        y: Theme.statusBarHeight + 6
        width: 34; height: 34; radius: 17
        visible: app.ready
        color: Qt.rgba(0, 0, 0, 0.35)
        Icon { anchors.centerIn: parent; name: "sliders"; size: 18 }
        MouseArea { anchors.fill: parent; onClicked: menu.open() }
    }

    Sheet {
        id: menu
        Column {
            width: parent.width
            spacing: 12
            Text { text: "WhatsAstra"; font.family: Theme.fontFamily; font.pixelSize: Theme.titleSize; font.weight: Font.Bold; color: Theme.text }
            Text { text: qsTr("Text size"); font.family: Theme.fontFamily; font.pixelSize: Theme.footnoteSize; color: Theme.textSecondary }
            Slider {
                width: parent.width
                from: 0.45; to: 1.0
                value: app.zoom
                onMoved: { app.zoom = value; app.saveConfig() }
            }
            ListGroup {
                width: parent.width
                ListItem { text: qsTr("Notifications"); showSwitch: true; checked: app.notify; onToggled: (on) => { app.notify = on; app.saveConfig() } }
                ListItem { text: qsTr("Spell check"); showSwitch: true; checked: app.spellcheck; onToggled: (on) => { app.spellcheck = on; app.saveConfig() } }
                ListItem { text: qsTr("Reload"); iconName: "refresh"; onClicked: { menu.close(); web.reload() } }
                ListItem {
                    text: qsTr("Log Out of This Phone")
                    destructive: true
                    separator: false
                    onClicked: Dialogs.show({ title: qsTr("Log out of WhatsAstra?"), message: qsTr("You'll need to scan the QR code again from your main phone."),
                                              buttons: [{ id: "c", label: qsTr("Cancel") }, { id: "out", label: qsTr("Log Out"), style: "destructive" }] },
                                            function(a) {
                                                if (a !== "out") return
                                                menu.close()
                                                web.runJavaScript("try{localStorage.clear();indexedDB.databases().then(l=>l.forEach(d=>indexedDB.deleteDatabase(d.name)))}catch(e){}",
                                                                  function() { profile.clearHttpCache(); web.reload() })
                                            })
                }
            }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: qsTr("WhatsAstra shows WhatsApp Web. It is not made by or affiliated with WhatsApp or Meta.")
                font.family: Theme.fontFamily
                font.pixelSize: Theme.footnoteSize
                color: Theme.textTertiary
            }
        }
    }

    // ---- attachment picker -----------------------------------------------------
    Sheet {
        id: picker
        property var request: null
        property var selected: []
        property string folder: Files.home
        readonly property var entries: Files.list(folder).filter(e => !e.name.startsWith("."))
        function pick(req) {
            request = req
            selected = []
            folder = Files.home
            Permissions.request("astra.permission.MEDIA", function() {})
            open()
        }
        onOpenedChanged: if (!opened && request) { request.dialogReject(); request = null }
        Column {
            width: parent.width
            spacing: 10
            Item {
                width: parent.width
                height: 40
                Text { anchors.verticalCenter: parent.verticalCenter; text: picker.folder === Files.home ? qsTr("Attach") : picker.folder.split("/").pop(); font.family: Theme.fontFamily; font.pixelSize: Theme.titleSize; font.weight: Font.Bold; color: Theme.text }
                Button {
                    anchors.right: parent.right
                    text: qsTr("Send %n", "", picker.selected.length)
                    enabled: picker.selected.length > 0
                    onClicked: {
                        const r = picker.request
                        picker.request = null
                        r.dialogAccept(picker.selected.map(p => "file://" + p))
                        picker.close()
                    }
                }
            }
            ListGroup {
                visible: !!app.pendingShare
                width: parent.width
                title: qsTr("Shared with WhatsAstra")
                Repeater {
                    model: app.pendingShare || []
                    delegate: ListItem {
                        required property string modelData
                        text: modelData.split("/").pop()
                        iconName: "share"
                        selected: picker.selected.indexOf(modelData) >= 0
                        onClicked: picker.toggle(modelData)
                    }
                }
            }
            ListGroup {
                width: parent.width
                ListItem {
                    visible: picker.folder !== Files.home
                    text: qsTr("Back")
                    iconName: "chevron-left"
                    onClicked: picker.folder = picker.folder.substring(0, picker.folder.lastIndexOf("/"))
                }
                Repeater {
                    model: picker.entries
                    delegate: ListItem {
                        required property var modelData
                        text: modelData.name
                        iconName: modelData.dir ? "folder" : modelData.mime.startsWith("image/") ? "image" : modelData.mime.startsWith("video/") ? "video" : "file"
                        chevron: modelData.dir
                        selected: picker.selected.indexOf(modelData.path) >= 0
                        onClicked: modelData.dir ? (picker.folder = modelData.path) : picker.toggle(modelData.path)
                    }
                }
            }
        }
        function toggle(path) {
            if (request && request.mode === FileDialogRequest.FileModeOpen)
                selected = [path]
            else
                selected = selected.indexOf(path) >= 0 ? selected.filter(p => p !== path) : selected.concat([path])
        }
    }

    Rectangle {
        id: toast
        function show(t) { toastText.text = t; opacity = 1; toastTimer.restart() }
        z: 90
        opacity: 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - 140
        width: Math.min(parent.width - 40, toastText.implicitWidth + 32)
        height: toastText.height + 20
        radius: 20
        color: "#3A3A42"
        Text { id: toastText; anchors.centerIn: parent; width: Math.min(implicitWidth, parent.parent.width - 72); wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; color: "white"; font.family: Theme.fontFamily; font.pixelSize: Theme.footnoteSize }
        Timer { id: toastTimer; interval: 3200; onTriggered: toast.opacity = 0 }
    }
}

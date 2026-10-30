// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick
import Astra.Core
import Astra.Controls

// WhatsAstra: WhatsApp on astraOS, a native app built from astraOS's own
// components. WhatsApp's protocol runs on the user's astraOS server (OpenWA,
// see astra-cloud); this app talks to it through AstraID
// (Account.request -> /api/app/com.astra.whatsastra/...).
Item {
    id: app

    readonly property color green: Application.accent.valid ? Application.accent : Theme.accent
    readonly property bool signedIn: Settings.values["account.signed_in"] === true
    property string status: "loading"     // loading, qr_ready, authenticating, ready, error, offline
    property string qr: ""
    property string error: ""
    property string myName: ""
    property string myPhone: ""
    property var chats: []
    property string openChat: ""
    property var openPage: null
    property real since: Date.now()

    // ---- the server ---------------------------------------------------------------
    function api(method, path, body, done) {
        Account.call("request", { method: method, path: "/api/app/com.astra.whatsastra/" + path, body: body || {} },
                     (r, err) => {
            if (!done)
                return
            if (err)
                return done(0, null, err)
            const ok = r.status >= 200 && r.status < 300
            done(r.status, r.body, ok ? "" : (r.body && r.body.error) || qsTr("WhatsApp error %1").arg(r.status))
        })
    }
    function refreshState() {
        if (!signedIn)
            return
        api("GET", "state", null, (code, body, err) => {
            if (err) {
                app.status = code === 503 || code === 0 ? "offline" : "error"
                app.error = err
                return
            }
            app.error = ""
            app.status = body.status === "ready" ? "ready" : body.status === "qr_ready" ? "qr_ready" : "authenticating"
            app.qr = body.qr || ""
            app.myName = body.name || ""
            app.myPhone = body.phone || ""
            if (app.status === "ready" && app.chats.length === 0)
                app.refreshChats()
        })
    }
    function refreshChats() {
        api("GET", "chats", null, (code, body, err) => { if (!err) app.chats = body || [] })
    }
    // New messages since the last look: the open conversation gets them at
    // once, the other chats a notification.
    function poll() {
        api("GET", "updates?since=" + Math.floor(since), null, (code, body, err) => {
            if (err || !body || !body.length)
                return
            for (const m of body) {
                app.since = Math.max(app.since, (m.timestamp || 0) * 1000 + 1)
                if (m.chatId === app.openChat && app.openPage)
                    app.openPage.add(m)
                else if (!m.fromMe)
                    Notifications.post(app.nameOf(m.chatId, m.name), m.body || app.typeLabel(m.type))
            }
            app.refreshChats()
        })
    }
    Timer {
        interval: app.status === "ready" ? 3000 : 2500
        repeat: true
        triggeredOnStart: true
        running: app.signedIn && Qt.application.state === Qt.ApplicationActive
        onTriggered: app.status === "ready" ? app.poll() : app.refreshState()
    }
    Timer { interval: 30000; repeat: true; running: app.status === "ready"; onTriggered: app.refreshChats() }
    onSignedInChanged: refreshState()
    Component.onCompleted: {
        Permissions.request("astra.permission.NOTIFICATIONS")
        refreshState()
    }

    function nameOf(chatId, fallback) {
        const c = chats.find(c => c.id === chatId)
        return c && c.name ? c.name : fallback || String(chatId).split("@")[0]
    }
    function initials(name) {
        const parts = String(name || "?").trim().split(/\s+/)
        return ((parts[0] || "?").charAt(0) + (parts.length > 1 ? parts[parts.length - 1].charAt(0) : "")).toUpperCase()
    }
    function typeLabel(type) {
        switch (type) {
        case "image": return qsTr("Photo")
        case "video": return qsTr("Video")
        case "audio": case "voice": return qsTr("Voice message")
        case "document": return qsTr("Document")
        case "sticker": return qsTr("Sticker")
        case "location": return qsTr("Location")
        case "contact": return qsTr("Contact")
        default: return ""
        }
    }
    function when(seconds) {
        if (!seconds)
            return ""
        const d = new Date(seconds * 1000), today = new Date()
        if (d.toDateString() === today.toDateString())
            return Qt.formatTime(d, "HH:mm")
        if (today - d < 6 * 86400000)
            return Qt.locale().dayName(d.getDay(), Locale.ShortFormat)
        return Qt.formatDate(d, "dd/MM/yy")
    }

    // ---- WhatsApp is linked: chats, conversations, settings -------------------------
    PageStack {
        id: stack
        anchors.fill: parent
        visible: app.signedIn && app.status === "ready"
        Component.onCompleted: open(chatsPage)
    }

    // ---- before that: AstraID, the QR code, the server -------------------------------
    Page {
        anchors.fill: parent
        visible: !stack.visible
        title: qsTr("WhatsAstra")

        EmptyState {
            visible: !app.signedIn
            iconName: "person"
            title: qsTr("Sign in to AstraID")
            message: qsTr("WhatsAstra connects to WhatsApp through your astraOS account.")
        }
        Button {
            visible: !app.signedIn
            width: parent.width
            text: qsTr("Open AstraID")
            onClicked: Packages.launch("com.astra.astraid")
        }

        Column {
            visible: app.signedIn && app.status === "qr_ready"
            width: parent.width
            spacing: 18
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: qsTr("Link WhatsApp")
                font.family: Theme.fontFamily
                font.pixelSize: Theme.titleSize
                font.weight: Font.Bold
                color: Theme.text
            }
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: qsTr("On your main phone open WhatsApp > Settings > Linked devices > Link a device, and scan this code.")
                font.family: Theme.fontFamily
                font.pixelSize: Theme.bodySize
                color: Theme.textSecondary
            }
            Card {
                Item {
                    width: parent.width
                    height: width
                    Image {
                        anchors.centerIn: parent
                        width: Math.min(parent.width, 300)
                        height: width
                        source: app.qr
                        smooth: false
                        fillMode: Image.PreserveAspectFit
                    }
                    Spinner { anchors.centerIn: parent; visible: app.qr === "" }
                }
            }
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: qsTr("WhatsApp does not support other apps officially: a linked account can be restricted by WhatsApp.")
                font.family: Theme.fontFamily
                font.pixelSize: Theme.captionSize
                color: Theme.textTertiary
            }
        }

        EmptyState {
            visible: app.signedIn && (app.status === "loading" || app.status === "authenticating")
            iconName: "message"
            title: app.status === "authenticating" ? qsTr("Connecting to WhatsApp…") : qsTr("WhatsAstra")
            message: qsTr("This can take a moment the first time.")
        }

        EmptyState {
            visible: app.signedIn && (app.status === "offline" || app.status === "error")
            iconName: "warning"
            title: app.status === "offline" ? qsTr("WhatsApp is not reachable") : qsTr("Something went wrong")
            message: app.error
        }
        Button {
            visible: app.signedIn && (app.status === "offline" || app.status === "error")
            width: parent.width
            primary: false
            text: qsTr("Try Again")
            onClicked: {
                app.status = "loading"
                app.refreshState()
            }
        }
    }

    // ---- chats --------------------------------------------------------------------
    Component {
        id: chatsPage
        Page {
            title: qsTr("Chats")
            actions: IconButton { iconName: "settings"; onClicked: stack.open(settingsPage) }

            TextField { id: search; width: parent.width; placeholder: qsTr("Search") }

            EmptyState {
                visible: app.chats.length === 0
                iconName: "message"
                title: qsTr("No chats yet")
                message: qsTr("Your WhatsApp chats show up here.")
            }

            Column {
                width: parent.width
                Repeater {
                    model: app.chats.filter(c => !search.text.trim() ||
                                            String(c.name || c.id).toLowerCase().includes(search.text.trim().toLowerCase()))
                    delegate: Item {
                        id: row
                        required property var modelData
                        width: parent.width
                        height: 74
                        Rectangle {
                            id: avatar
                            anchors.verticalCenter: parent.verticalCenter
                            width: 52
                            height: 52
                            radius: 26
                            color: Theme.surfaceRaised
                            Icon {
                                anchors.centerIn: parent
                                visible: row.modelData.isGroup === true
                                name: "person-add"
                                size: 24
                                color: Theme.textSecondary
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: row.modelData.isGroup !== true
                                text: app.initials(row.modelData.name || row.modelData.id)
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.headlineSize
                                font.weight: Font.DemiBold
                                color: Theme.textSecondary
                            }
                        }
                        Column {
                            anchors.left: avatar.right
                            anchors.leftMargin: 14
                            anchors.right: meta.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: row.modelData.name || String(row.modelData.id).split("@")[0]
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.headlineSize
                                font.weight: Font.DemiBold
                                color: Theme.text
                            }
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                text: row.modelData.lastMessage || app.typeLabel(row.modelData.lastMessageType)
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.captionSize
                                color: Theme.textSecondary
                            }
                        }
                        Column {
                            id: meta
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            Text {
                                anchors.right: parent.right
                                text: app.when(row.modelData.timestamp)
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.captionSize
                                color: row.modelData.unreadCount > 0 ? app.green : Theme.textTertiary
                            }
                            Rectangle {
                                anchors.right: parent.right
                                visible: row.modelData.unreadCount > 0
                                width: Math.max(22, unread.implicitWidth + 12)
                                height: 22
                                radius: 11
                                color: app.green
                                Text {
                                    id: unread
                                    anchors.centerIn: parent
                                    text: row.modelData.unreadCount
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.captionSize
                                    font.weight: Font.Bold
                                    color: Theme.accentText
                                }
                            }
                        }
                        Rectangle {
                            anchors.left: avatar.right
                            anchors.leftMargin: 14
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 1
                            color: Theme.separator
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: stack.open(conversationPage, { chat: row.modelData })
                        }
                    }
                }
            }
        }
    }

    // ---- a conversation -------------------------------------------------------------
    Component {
        id: conversationPage
        Item {
            id: page
            property var stack
            property var chat
            property var messages: []
            property string sendError: ""

            function add(m) {
                if (messages.some(x => x.id === m.id))
                    return
                messages = messages.concat([m])
                list.positionViewAtEnd()
            }
            function load() {
                app.api("GET", "messages?chatId=" + encodeURIComponent(chat.id) + "&limit=60", null, (code, body, err) => {
                    if (err)
                        return
                    page.messages = body || []
                    list.positionViewAtEnd()
                })
                app.api("POST", "read", { chatId: chat.id }, null)
            }
            function send() {
                const text = input.text.trim()
                if (!text)
                    return
                input.text = ""
                const pending = { id: "local-" + Date.now(), body: text, fromMe: true,
                                  timestamp: Math.floor(Date.now() / 1000), pending: true }
                add(pending)
                app.api("POST", "send", { chatId: chat.id, text: text }, (code, body, err) => {
                    page.messages = page.messages.map(m => m.id !== pending.id ? m
                        : Object.assign({}, m, { pending: false, failed: !!err, id: (body && body.id) || m.id }))
                    page.sendError = err || ""
                    app.refreshChats()
                })
            }
            Component.onCompleted: {
                app.openChat = chat.id
                app.openPage = page
                load()
            }
            Component.onDestruction: {
                if (app.openPage === page) {
                    app.openPage = null
                    app.openChat = ""
                }
            }

            ListView {
                id: list
                anchors.fill: parent
                anchors.topMargin: Theme.statusBarHeight + 60
                anchors.bottomMargin: composer.height + 40
                spacing: 4
                clip: true
                model: page.messages
                delegate: Item {
                    id: msg
                    required property var modelData
                    readonly property bool mine: modelData.fromMe === true
                    width: list.width
                    height: bubble.height + 4
                    Rectangle {
                        id: bubble
                        x: msg.mine ? parent.width - width - 12 : 12
                        width: Math.min(parent.width * 0.78, Math.max(body.implicitWidth, time.implicitWidth + 4) + 26)
                        height: body.implicitHeight + time.implicitHeight + 18
                        radius: 18
                        color: msg.mine ? app.green : Theme.surfaceRaised
                        opacity: msg.modelData.pending ? 0.7 : 1
                        Text {
                            id: body
                            x: 13
                            y: 8
                            width: Math.min(list.width * 0.78 - 26, implicitWidth)
                            text: msg.modelData.body || ("[" + (app.typeLabel(msg.modelData.type) || qsTr("Message")) + "]")
                            wrapMode: Text.Wrap
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.bodySize
                            color: msg.mine ? Theme.accentText : Theme.text
                        }
                        Text {
                            id: time
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.top: body.bottom
                            anchors.topMargin: 2
                            text: msg.modelData.failed ? qsTr("Not sent") : app.when(msg.modelData.timestamp)
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.footnoteSize
                            color: msg.modelData.failed ? Theme.danger : msg.mine ? Theme.accentText : Theme.textTertiary
                        }
                    }
                }
            }

            // Header
            Rectangle {
                width: parent.width
                height: Theme.statusBarHeight + 56
                color: Theme.background
                IconButton {
                    x: 12
                    y: Theme.statusBarHeight + 6
                    size: 40
                    iconName: "chevron-left"
                    onClicked: page.stack.pop()
                }
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: Theme.statusBarHeight + 8
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: page.chat ? (page.chat.name || String(page.chat.id).split("@")[0]) : ""
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.headlineSize
                        font.weight: Font.DemiBold
                        color: Theme.text
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: page.chat && page.chat.isGroup ? qsTr("Group") : qsTr("WhatsApp")
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.captionSize
                        color: Theme.textSecondary
                    }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
            }

            Text {
                visible: page.sendError !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: composer.top
                anchors.bottomMargin: 8
                width: parent.width - 32
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: page.sendError
                font.family: Theme.fontFamily
                font.pixelSize: Theme.captionSize
                color: Theme.danger
            }

            // Composer
            Row {
                id: composer
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 30
                x: 12
                spacing: 8
                height: 48
                TextField {
                    id: input
                    width: page.width - 24 - 56
                    height: 48
                    radius: 24
                    placeholder: qsTr("Message")
                    onAccepted: page.send()
                }
                IconButton {
                    size: 48
                    iconName: "send"
                    color: input.text.trim() ? app.green : Theme.surfaceRaised
                    iconColor: input.text.trim() ? Theme.accentText : Theme.textSecondary
                    onClicked: page.send()
                }
            }
        }
    }

    // ---- settings -------------------------------------------------------------------
    Component {
        id: settingsPage
        Page {
            title: qsTr("Settings")
            ListGroup {
                title: qsTr("WhatsApp")
                ListItem {
                    text: app.myName || qsTr("Linked")
                    subtitle: app.myPhone ? "+" + app.myPhone : ""
                    iconName: "person"
                }
                ListItem {
                    text: qsTr("Unlink This Phone")
                    destructive: true
                    separator: false
                    onClicked: Dialogs.show({ title: qsTr("Unlink WhatsApp?"),
                                              message: qsTr("You can link it again by scanning a new code."),
                                              buttons: [{ id: "cancel", label: qsTr("Cancel") },
                                                        { id: "unlink", label: qsTr("Unlink"), style: "destructive" }] },
                                            function(answer) {
                        if (answer !== "unlink")
                            return
                        app.api("POST", "logout", null, () => {
                            app.chats = []
                            app.status = "loading"
                            stack.pop(null)
                            app.refreshState()
                        })
                    })
                }
            }
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: qsTr("WhatsAstra reaches WhatsApp through your astraOS server. WhatsApp does not support other apps officially: a linked account can be restricted by WhatsApp. WhatsAstra is not made by or affiliated with WhatsApp or Meta.")
                font.family: Theme.fontFamily
                font.pixelSize: Theme.captionSize
                color: Theme.textTertiary
            }
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick
import QtMultimedia
import Astra.Core
import Astra.Controls
import Astra.Animation

// WhatsAstra: WhatsApp on astraOS, with WhatsApp's protocol on the phone.
//
// The connection lives in WhatsAstra's background service (bin/whatsastra-service,
// app.json "services"), which astraOS keeps running: it is linked to the user's
// WhatsApp as a companion device and keeps the chats. The app talks to it on
// 127.0.0.1 with the port and token it writes to files/service.json.
Rectangle {
    id: app
    color: Theme.background

    // WhatsAstra's colour is its accent (app.json); my bubbles are tinted with it.
    readonly property color green: Application.accent
    readonly property color bubbleMine: Qt.tint(Theme.surface, Qt.alpha(Application.accent, Theme.light ? 0.22 : 0.35))

    property string base: ""            // http://127.0.0.1:<port>
    property string token: ""
    property string status: "loading"   // loading starting qr_ready authenticating ready offline noservice
    property string error: ""
    property string qr: ""
    property string myName: ""
    property string myPhone: ""
    property var chats: []
    property var statuses: []
    property var channels: []
    property var contacts: []
    property int seq: 0
    property string openChat: ""
    property var openPage: null
    property bool showArchived: false
    property int tab: 0                 // 0 chats, 1 status, 2 channels

    // ---- the service ------------------------------------------------------------------
    function connect() {
        const text = Files.readText(Application.dataDir + "/files/service.json")
        let info = null
        try { info = JSON.parse(text) } catch (e) { info = null }
        if (!info || !info.port) {
            app.status = "noservice"
            return false
        }
        app.base = "http://127.0.0.1:" + info.port
        app.token = info.token
        return true
    }
    function api(method, path, body, done) {
        if (!app.base && !app.connect()) {
            if (done) done(0, null, qsTr("WhatsAstra's service is starting"))
            return
        }
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            if (xhr.status === 0 || xhr.status === 403) {
                // The service restarted: a new port and token.
                app.base = ""
                if (done) done(0, null, qsTr("WhatsAstra's service is starting"))
                return
            }
            let data = null
            try { data = JSON.parse(xhr.responseText) } catch (e) { data = null }
            if (!done)
                return
            if (xhr.status >= 200 && xhr.status < 300)
                done(xhr.status, data, "")
            else
                done(xhr.status, data, (data && data.error) || qsTr("Error %1").arg(xhr.status))
        }
        xhr.open(method, app.base + "/" + path)
        xhr.setRequestHeader("X-Token", app.token)
        if (body) {
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(JSON.stringify(body))
        } else {
            xhr.send()
        }
    }
    function mediaUrl(m) { return app.base + "/media?chatId=" + encodeURIComponent(m.chatId) + "&id=" + encodeURIComponent(m.id) + "&token=" + app.token }
    function avatarUrl(id) { return app.base && id ? app.base + "/avatar?chatId=" + encodeURIComponent(id) + "&token=" + app.token : "" }

    function refreshState() {
        api("GET", "state", null, (code, body, err) => {
            if (err) {
                app.status = "noservice"
                return
            }
            app.status = body.status
            app.error = body.error || ""
            app.qr = body.qr || ""
            app.myName = body.name || ""
            app.myPhone = body.phone || ""
            if (app.status === "ready") {
                app.refreshChats()
                app.refreshStatuses()
            }
        })
    }
    function refreshChats() { api("GET", "chats", null, (c, body, err) => { if (!err) app.chats = body || [] }) }
    function refreshStatuses() { api("GET", "status", null, (c, body, err) => { if (!err) app.statuses = body || [] }) }
    function refreshChannels() { api("GET", "channels", null, (c, body, err) => { if (!err) app.channels = body || [] }) }
    function refreshContacts() { api("GET", "contacts", null, (c, body, err) => { if (!err) app.contacts = body || [] }) }

    // Long poll: the service answers as soon as something changes.
    function listen() {
        api("GET", "events?since=" + app.seq, null, (code, body, err) => {
            if (err) {
                retry.start()
                return
            }
            const first = app.seq === 0
            app.seq = body.seq
            let chatsChanged = first
            for (const e of body.events) {
                switch (e.kind) {
                case "state": app.refreshState(); break
                case "chats": chatsChanged = true; break
                case "status": Qt.callLater(app.refreshStatuses); break
                case "message":
                    chatsChanged = true
                    if (app.openPage && e.message.chatId === app.openChat)
                        app.openPage.add(e.message)
                    break
                case "ack": case "reaction": case "deleted":
                    if (app.openPage && e.chatId === app.openChat)
                        app.openPage.change(e)
                    if (e.kind !== "reaction")
                        chatsChanged = true
                    break
                }
            }
            if (chatsChanged)
                Qt.callLater(app.refreshChats)
            app.listen()
        })
    }
    Timer { id: retry; interval: 2000; onTriggered: { app.refreshState(); app.listen() } }

    // The chat on screen: read, and no notification for it.
    function setFocus() {
        const chat = Qt.application.state === Qt.ApplicationActive && app.openPage && !app.openPage.channel ? app.openChat : ""
        api("POST", "focus", { chatId: chat }, null)
    }
    Connections {
        target: Qt.application
        function onStateChanged() { app.setFocus() }
    }

    function openChatById(chatId) {
        if (!chatId || app.status !== "ready")
            return
        const chat = app.chats.find(c => c.id === chatId) || { id: chatId, name: "" }
        stack.pop(null)
        stack.open(conversationPage, { chat: chat })
    }
    Connections {
        target: Application
        function onIntent(args) { if (args.chatId) app.openChatById(args.chatId) }
    }
    Component.onCompleted: {
        Permissions.request("astra.permission.NOTIFICATIONS")
        app.connect()
        app.refreshState()
        app.listen()
    }
    onStatusChanged: if (status === "ready" && Application.args.chatId && stack.depth === 1) openChatById(Application.args.chatId)

    // ---- helpers ------------------------------------------------------------------------
    function isGroup(id) { return String(id).endsWith("@g.us") }
    function nameOf(chat) {
        if (!chat)
            return ""
        return chat.name || chat.phone || "+" + String(chat.id).split("@")[0]
    }
    function initials(name) {
        const parts = String(name || "?").replace(/^\+/, "").trim().split(/\s+/)
        return ((parts[0] || "?").charAt(0) + (parts.length > 1 ? parts[parts.length - 1].charAt(0) : "")).toUpperCase()
    }
    function typeLabel(type) {
        switch (type) {
        case "image": return qsTr("Photo")
        case "video": return qsTr("Video")
        case "voice": return qsTr("Voice message")
        case "audio": return qsTr("Audio")
        case "document": return qsTr("Document")
        case "sticker": return qsTr("Sticker")
        case "location": return qsTr("Location")
        case "contact": return qsTr("Contact")
        case "deleted": return qsTr("This message was deleted")
        }
        return ""
    }
    function preview(c) {
        const t = app.typeLabel(c.lastMessageType)
        if (c.lastMessageType === "deleted")
            return t
        return c.lastMessage ? (t && c.lastMessageType !== "text" && c.lastMessageType !== "location" ? t + ": " : "") + c.lastMessage : t
    }
    function when(seconds) {
        if (!seconds)
            return ""
        const d = new Date(seconds * 1000), today = new Date()
        if (d.toDateString() === today.toDateString())
            return Qt.formatTime(d, "HH:mm")
        const yesterday = new Date(today.getTime() - 86400000)
        if (d.toDateString() === yesterday.toDateString())
            return qsTr("Yesterday")
        if (today - d < 6 * 86400000)
            return Qt.locale().dayName(d.getDay(), Locale.ShortFormat)
        return Qt.formatDate(d, "dd/MM/yy")
    }
    function duration(s) { return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2) }
    function ticks(ack) { return ack >= 2 ? "✓✓" : ack === 1 ? "✓" : ack < 0 ? "!" : "🕓" }

    // A round photo (the service makes it round), or the initials in a circle.
    component Avatar: Item {
        id: avatar
        property string chatId
        property string name
        property real size: 52
        property bool ring: false
        width: size
        height: size
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: avatar.ring ? "transparent" : Theme.surfaceRaised
            border.width: avatar.ring ? 3 : 0
            border.color: app.green
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: avatar.ring ? 5 : 0
            radius: width / 2
            color: Theme.surfaceRaised
            Text {
                anchors.centerIn: parent
                visible: photo.status !== Image.Ready
                text: app.isGroup(avatar.chatId) ? "👥" : app.initials(avatar.name)
                font.family: Theme.fontFamily
                font.pixelSize: parent.width * 0.36
                font.weight: Font.DemiBold
                color: Theme.textSecondary
            }
            Image {
                id: photo
                anchors.fill: parent
                source: app.avatarUrl(avatar.chatId)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: 160
                visible: status === Image.Ready
            }
        }
    }

    // ---- linked: chats, status, channels ----------------------------------------------------
    PageStack {
        id: stack
        anchors.fill: parent
        visible: app.status === "ready" || (depth > 1 && app.status === "authenticating")
        Component.onCompleted: open(homePage)
    }

    Component {
        id: homePage
        Item {
            property var stack
            Item {
                anchors.fill: parent
                anchors.bottomMargin: tabs.height

                // Chats
                Page {
                    id: chatsList
                    anchors.fill: parent
                    visible: app.tab === 0
                    title: app.showArchived ? qsTr("Archived") : qsTr("Chats")
                    actions: Row {
                        spacing: 8
                        IconButton { iconName: "edit"; onClicked: { app.refreshContacts(); newChat.start(false) } }
                        IconButton { iconName: "settings"; onClicked: stack.open(settingsPage) }
                    }

                    readonly property string query: search.text.trim().toLowerCase()
                    readonly property var visibleChats: app.chats.filter(c => chatsList.query
                        ? (String(app.nameOf(c)).toLowerCase().includes(chatsList.query) || String(c.phone || "").includes(chatsList.query))
                        : (c.archived === app.showArchived && !String(c.id).endsWith("@newsletter")))
                    readonly property int archivedCount: app.chats.filter(c => c.archived).length

                    TextField { id: search; width: parent.width; placeholder: qsTr("Search") }

                    ListItem {
                        visible: !app.showArchived && chatsList.archivedCount > 0 && !chatsList.query
                        width: parent.width
                        iconName: "archive"
                        text: qsTr("Archived")
                        value: String(chatsList.archivedCount)
                        chevron: true
                        onClicked: app.showArchived = true
                    }
                    ListItem {
                        visible: app.showArchived
                        width: parent.width
                        iconName: "chevron-left"
                        text: qsTr("All chats")
                        onClicked: app.showArchived = false
                    }
                    EmptyState {
                        visible: chatsList.visibleChats.length === 0
                        iconName: "message"
                        title: chatsList.query ? qsTr("No results") : qsTr("No chats yet")
                        message: chatsList.query ? "" : qsTr("Your WhatsApp chats show up here. Messages before linking arrive in a few minutes.")
                    }
                    Column {
                        width: parent.width
                        Repeater {
                            model: chatsList.visibleChats
                            delegate: Item {
                                id: row
                                required property var modelData
                                width: parent.width
                                height: 76
                                Avatar {
                                    id: avatar
                                    anchors.verticalCenter: parent.verticalCenter
                                    chatId: row.modelData.id
                                    name: app.nameOf(row.modelData)
                                    size: 54
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
                                        text: app.nameOf(row.modelData)
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.headlineSize
                                        font.weight: Font.DemiBold
                                        color: Theme.text
                                    }
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        text: (row.modelData.lastFromMe ? app.ticks(row.modelData.lastAck) + " " : "") + app.preview(row.modelData)
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.bodySize
                                        font.italic: row.modelData.lastMessageType === "deleted"
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
                                    Row {
                                        anchors.right: parent.right
                                        spacing: 6
                                        Icon { visible: row.modelData.pinned; name: "pin"; size: 16; color: Theme.textTertiary }
                                        Rectangle {
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
                                    onPressAndHold: Dialogs.show({ title: app.nameOf(row.modelData),
                                                                   buttons: [{ id: "cancel", label: qsTr("Cancel") },
                                                                             { id: "delete", label: qsTr("Delete Chat"), style: "destructive" }] },
                                                                 function(answer) {
                                        if (answer === "delete")
                                            app.api("POST", "deleteChat", { chatId: row.modelData.id }, null)
                                    })
                                }
                            }
                        }
                    }
                }

                // Status
                Page {
                    anchors.fill: parent
                    visible: app.tab === 1
                    title: qsTr("Status")
                    EmptyState {
                        visible: app.statuses.length === 0
                        iconName: "sparkles"
                        title: qsTr("No status updates")
                        message: qsTr("Your contacts' status updates of the last 24 hours show up here.")
                    }
                    ListGroup {
                        visible: app.statuses.length > 0
                        title: qsTr("Recent updates")
                        Repeater {
                            model: app.statuses
                            delegate: Item {
                                id: srow
                                required property var modelData
                                required property int index
                                width: parent.width
                                height: 72
                                Avatar {
                                    id: savatar
                                    x: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    chatId: srow.modelData.id
                                    name: srow.modelData.name || srow.modelData.phone
                                    size: 54
                                    ring: true
                                }
                                Column {
                                    anchors.left: savatar.right
                                    anchors.leftMargin: 14
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: srow.modelData.name || srow.modelData.phone || qsTr("Someone")
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.headlineSize
                                        font.weight: Font.DemiBold
                                        color: Theme.text
                                    }
                                    Text {
                                        text: app.when(srow.modelData.timestamp) + " · " + qsTr("%n update(s)", "", srow.modelData.items.length)
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.captionSize
                                        color: Theme.textSecondary
                                    }
                                }
                                MouseArea { anchors.fill: parent; onClicked: storyViewer.show(srow.index) }
                            }
                        }
                    }
                }

                // Channels
                Page {
                    anchors.fill: parent
                    visible: app.tab === 2
                    title: qsTr("Channels")
                    onVisibleChanged: if (visible) app.refreshChannels()
                    EmptyState {
                        visible: app.channels.length === 0
                        iconName: "globe"
                        title: qsTr("No channels")
                        message: qsTr("The channels you follow in WhatsApp show up here.")
                    }
                    Column {
                        width: parent.width
                        Repeater {
                            model: app.channels
                            delegate: Item {
                                id: crow
                                required property var modelData
                                width: parent.width
                                height: 76
                                Avatar {
                                    id: cavatar
                                    anchors.verticalCenter: parent.verticalCenter
                                    chatId: crow.modelData.id
                                    name: crow.modelData.name
                                    size: 54
                                }
                                Column {
                                    anchors.left: cavatar.right
                                    anchors.leftMargin: 14
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 3
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: crow.modelData.name + (crow.modelData.verified ? " ✓" : "")
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.headlineSize
                                        font.weight: Font.DemiBold
                                        color: Theme.text
                                    }
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: qsTr("%1 followers").arg(Number(crow.modelData.subscribers || 0).toLocaleString(Qt.locale(), "f", 0))
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.captionSize
                                        color: Theme.textSecondary
                                    }
                                }
                                Rectangle {
                                    anchors.left: cavatar.right
                                    anchors.leftMargin: 14
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: 1
                                    color: Theme.separator
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: stack.open(conversationPage, { chat: crow.modelData, channel: true })
                                }
                            }
                        }
                    }
                }
            }
            TabBar {
                id: tabs
                currentIndex: app.tab
                tint: app.green
                model: [{ icon: "message", label: qsTr("Chats") }, { icon: "sparkles", label: qsTr("Status") },
                        { icon: "globe", label: qsTr("Channels") }]
                onActivated: (index) => {
                    app.tab = index
                    if (index === 1)
                        app.refreshStatuses()
                }
            }
        }
    }

    // ---- not linked yet, or connecting ----------------------------------------------------
    Page {
        anchors.fill: parent
        visible: !stack.visible
        title: qsTr("WhatsAstra")

        Column {
            visible: app.status === "qr_ready"
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
                    Rectangle {
                        anchors.centerIn: parent
                        width: Math.min(parent.width, 300)
                        height: width
                        radius: 12
                        color: Theme.surface
                        Image {
                            anchors.fill: parent
                            anchors.margins: 8
                            source: app.qr
                            smooth: false
                            fillMode: Image.PreserveAspectFit
                        }
                    }
                    Spinner { anchors.centerIn: parent; visible: app.qr === "" }
                }
            }
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: qsTr("WhatsApp's protocol runs on this phone, end to end encrypted. WhatsApp does not support other apps officially: a linked account can be restricted by WhatsApp.")
                font.family: Theme.fontFamily
                font.pixelSize: Theme.captionSize
                color: Theme.textTertiary
            }
        }
        EmptyState {
            visible: app.status === "loading" || app.status === "starting" || app.status === "authenticating"
            iconName: "message"
            title: app.status === "authenticating" ? qsTr("Connecting to WhatsApp…") : qsTr("WhatsAstra")
            message: qsTr("This can take a moment the first time.")
        }
        EmptyState {
            visible: app.status === "offline" || app.status === "noservice"
            iconName: "warning"
            title: app.status === "noservice" ? qsTr("WhatsAstra is starting") : qsTr("WhatsApp is not reachable")
            message: app.status === "noservice" ? qsTr("Its service starts with the phone: wait a moment.") : app.error
        }
        Button {
            visible: app.status === "offline" || app.status === "noservice"
            width: parent.width
            primary: false
            text: qsTr("Try Again")
            onClicked: {
                app.base = ""
                app.status = "loading"
                app.refreshState()
            }
        }
    }

    // ---- a conversation, or a channel's posts ----------------------------------------------
    Component {
        id: conversationPage
        Item {
            id: page
            property var stack
            property var chat
            property bool channel: false
            property var messages: []
            property var replyTo: null
            property string sendError: ""
            property bool older: true
            readonly property bool group: app.isGroup(chat ? chat.id : "")
            readonly property var live: chat ? (app.chats.find(c => c.id === chat.id) || chat) : ({})

            function add(m) {
                const i = messages.findIndex(x => x.id === m.id)
                if (i >= 0) {
                    const copy = messages.slice()
                    copy[i] = m
                    messages = copy
                    return
                }
                const atEnd = list.atYEnd
                messages = messages.concat([m])
                if (atEnd || m.fromMe)
                    Qt.callLater(list.positionViewAtEnd)
            }
            function change(e) {
                messages = messages.map(m => {
                    if (!e.ids || e.ids.indexOf(m.id) < 0)
                        return m
                    if (e.kind === "ack")
                        return Object.assign({}, m, { ack: Math.max(m.ack, e.ack) })
                    if (e.kind === "reaction")
                        return Object.assign({}, m, { reaction: e.text })
                    return Object.assign({}, m, { type: "deleted", body: "", hasMedia: false })
                })
            }
            function load() {
                const path = channel ? "channelMessages?id=" + encodeURIComponent(chat.id)
                                     : "messages?chatId=" + encodeURIComponent(chat.id) + "&limit=60"
                app.api("GET", path, null, (code, body, err) => {
                    if (err) {
                        page.sendError = err
                        return
                    }
                    page.messages = body || []
                    page.older = !channel && page.messages.length >= 60
                    Qt.callLater(list.positionViewAtEnd)
                })
            }
            function loadOlder() {
                if (!older || messages.length === 0)
                    return
                older = false
                app.api("GET", "messages?chatId=" + encodeURIComponent(chat.id) + "&limit=60&before=" + messages[0].timestamp, null,
                        (code, body, err) => {
                    if (err || !body || body.length === 0)
                        return
                    page.older = body.length >= 60
                    page.messages = body.concat(page.messages.filter(m => !body.some(b => b.id === m.id)))
                    list.positionViewAtIndex(body.length, ListView.Beginning)
                })
            }
            function send() {
                const text = input.text.trim()
                if (!text)
                    return
                input.text = ""
                const quote = replyTo
                replyTo = null
                const pending = { id: "local-" + Date.now(), chatId: chat.id, body: text, fromMe: true, type: "text", ack: 0,
                                  timestamp: Math.floor(Date.now() / 1000),
                                  quote: quote ? { id: quote.id, body: quote.body, type: quote.type, senderName: quote.senderName } : null }
                add(pending)
                app.api("POST", "send", { chatId: chat.id, text: text, quoteId: quote ? quote.id : "" }, (code, body, err) => {
                    page.messages = err ? page.messages.map(m => m.id === pending.id ? Object.assign({}, m, { ack: -1 }) : m)
                                        : page.messages.filter(m => m.id !== pending.id && m.id !== body.id).concat([body])
                    page.sendError = err || ""
                })
            }
            function sendFile(path) {
                attach.close()
                page.sendError = ""
                app.api("POST", "sendFile", { chatId: chat.id, path: path, caption: "" }, (code, body, err) => {
                    page.sendError = err || ""
                })
            }
            function messageMenu(m) {
                const buttons = []
                if (!channel)
                    buttons.push({ id: "reply", label: qsTr("Reply") })
                if (m.body)
                    buttons.push({ id: "copy", label: qsTr("Copy") })
                if (m.hasMedia)
                    buttons.push({ id: "save", label: qsTr("Save to Files") })
                if (!channel)
                    for (const e of ["👍", "❤️", "😂", "😮", "😢", "🙏"])
                        buttons.push({ id: "react:" + e, label: e })
                if (!channel && m.fromMe && m.type !== "deleted" && Date.now() / 1000 - m.timestamp < 2 * 86400)
                    buttons.push({ id: "revoke", label: qsTr("Delete for Everyone"), style: "destructive" })
                buttons.push({ id: "cancel", label: qsTr("Cancel") })
                Dialogs.show({ title: m.body ? m.body.substring(0, 80) : app.typeLabel(m.type), buttons: buttons }, function(answer) {
                    if (answer === "reply") {
                        page.replyTo = m
                        input.forceActiveFocus()
                    } else if (answer === "copy") {
                        copier.text = m.body
                        copier.selectAll()
                        copier.copy()
                    } else if (answer === "save") {
                        Permissions.request("astra.permission.MEDIA", function(granted) {
                            app.api("POST", "save", { chatId: m.chatId, id: m.id }, (code, body, err) => {
                                page.sendError = err ? err : qsTr("Saved in Download/WhatsAstra")
                            })
                        })
                    } else if (answer === "revoke") {
                        app.api("POST", "revoke", { chatId: m.chatId, id: m.id }, null)
                    } else if (answer && answer.indexOf("react:") === 0) {
                        const emoji = answer.substring(6)
                        app.api("POST", "react", { chatId: m.chatId, id: m.id, emoji: m.reaction === emoji ? "" : emoji }, null)
                    }
                })
            }
            Component.onCompleted: {
                app.openChat = chat.id
                app.openPage = page
                app.setFocus()
                load()
            }
            Component.onDestruction: {
                if (app.openPage === page) {
                    app.openPage = null
                    app.openChat = ""
                    app.setFocus()
                }
            }
            TextEdit { id: copier; visible: false }

            Rectangle { anchors.fill: parent; color: Theme.background }

            ListView {
                id: list
                anchors.fill: parent
                anchors.topMargin: Theme.statusBarHeight + 64
                anchors.bottomMargin: page.channel ? 24 : composer.height + 36 + (replyBar.visible ? replyBar.height + 6 : 0)
                spacing: 4
                clip: true
                model: page.messages
                onAtYBeginningChanged: if (atYBeginning && contentHeight > height) page.loadOlder()
                delegate: Item {
                    id: msg
                    required property var modelData
                    required property int index
                    readonly property bool mine: modelData.fromMe === true
                    readonly property bool newDay: index === 0 || new Date(page.messages[index - 1].timestamp * 1000).toDateString()
                                                                   !== new Date(modelData.timestamp * 1000).toDateString()
                    readonly property real maxWidth: list.width * 0.78
                    readonly property bool picture: modelData.hasMedia && (modelData.type === "image" || modelData.type === "sticker")
                    readonly property bool mediaRow: modelData.hasMedia && ["video", "voice", "audio", "document"].indexOf(modelData.type) >= 0
                    readonly property string bodyText: modelData.type === "deleted" ? "🚫 " + app.typeLabel("deleted")
                        : modelData.body || (!modelData.hasMedia ? app.typeLabel(modelData.type) : "")
                    readonly property string mediaLabel: modelData.type === "document" ? (modelData.fileName || qsTr("Document"))
                        : app.typeLabel(modelData.type) + (modelData.seconds ? " · " + app.duration(modelData.seconds) : "")
                    readonly property bool showSender: page.group && !mine
                    readonly property string senderText: modelData.senderName || ("+" + String(modelData.sender || "").split("@")[0])
                    width: list.width
                    height: (newDay ? 34 : 0) + bubble.height + (modelData.reaction ? 16 : 4)

                    // The natural size of what the bubble holds, unwrapped: the
                    // bubble takes it, up to maxWidth, and the text wraps inside.
                    Text { id: measureBody; visible: false; text: msg.bodyText; textFormat: Text.PlainText
                           font.family: Theme.fontFamily; font.pixelSize: Theme.bodySize }
                    Text { id: measureSender; visible: false; text: msg.showSender ? msg.senderText : ""
                           font.family: Theme.fontFamily; font.pixelSize: Theme.captionSize; font.weight: Font.DemiBold }
                    Text { id: measureMedia; visible: false; text: msg.mediaRow ? msg.mediaLabel : ""
                           font.family: Theme.fontFamily; font.pixelSize: Theme.bodySize }
                    readonly property real naturalWidth: Math.max(msg.bodyText ? measureBody.implicitWidth : 0,
                                                                  measureSender.implicitWidth,
                                                                  msg.mediaRow ? measureMedia.implicitWidth + 50 : 0,
                                                                  msg.picture ? 240 : 0,
                                                                  modelData.quote ? 160 : 0,
                                                                  footer.implicitWidth + 4)

                    Rectangle {
                        visible: msg.newDay
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 6
                        width: dayText.implicitWidth + 20
                        height: 22
                        radius: 8
                        color: Theme.surfaceRaised
                        Text {
                            id: dayText
                            anchors.centerIn: parent
                            text: Qt.formatDate(new Date(msg.modelData.timestamp * 1000), "d MMMM yyyy")
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.captionSize
                            color: Theme.textSecondary
                        }
                    }

                    Rectangle {
                        id: bubble
                        y: msg.newDay ? 34 : 0
                        x: msg.mine ? parent.width - width - 10 : 10
                        width: Math.min(msg.maxWidth, msg.naturalWidth + 24)
                        height: content.height + footer.height + 14
                        radius: 16
                        color: msg.mine ? app.bubbleMine : Theme.surface
                        Column {
                            id: content
                            x: 12
                            y: 7
                            width: bubble.width - 24
                            spacing: 4
                            Text {
                                visible: msg.showSender
                                width: parent.width
                                elide: Text.ElideRight
                                text: msg.senderText
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.captionSize
                                font.weight: Font.DemiBold
                                color: app.green
                            }
                            // The message it answers.
                            Rectangle {
                                visible: !!msg.modelData.quote
                                width: parent.width
                                height: visible ? quoteText.implicitHeight + 12 : 0
                                radius: 8
                                color: Theme.surfaceRaised
                                Rectangle { width: 4; height: parent.height; radius: 2; color: app.green }
                                Text {
                                    id: quoteText
                                    x: 12
                                    y: 6
                                    width: parent.width - 18
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                    wrapMode: Text.Wrap
                                    text: msg.modelData.quote ? ((msg.modelData.quote.senderName === "me" ? qsTr("You") : msg.modelData.quote.senderName || "")
                                                                  + "\n" + (msg.modelData.quote.body || app.typeLabel(msg.modelData.quote.type))).trim() : ""
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.captionSize
                                    color: Theme.textSecondary
                                }
                            }
                            // Photo, sticker
                            Image {
                                visible: msg.picture
                                width: visible ? parent.width : 0
                                height: visible ? (status === Image.Ready ? width * implicitHeight / Math.max(1, implicitWidth) : 180) : 0
                                source: visible ? app.mediaUrl(msg.modelData) : ""
                                asynchronous: true
                                fillMode: Image.PreserveAspectFit
                                sourceSize.width: 520
                                Spinner { anchors.centerIn: parent; visible: parent.status === Image.Loading }
                                MouseArea { anchors.fill: parent; onClicked: viewer.show(msg.modelData) }
                            }
                            // Video, voice, audio, document
                            Row {
                                visible: msg.mediaRow
                                width: parent.width
                                spacing: 10
                                IconButton {
                                    id: play
                                    size: 40
                                    iconName: msg.modelData.type === "document" ? "file"
                                            : player.playing === msg.modelData.id ? "pause" : "play"
                                    color: app.green
                                    iconColor: Theme.accentText
                                    onClicked: msg.modelData.type === "document" ? page.messageMenu(msg.modelData)
                                             : msg.modelData.type === "video" ? viewer.show(msg.modelData)
                                             : player.toggle(msg.modelData)
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - play.width - 10
                                    elide: Text.ElideMiddle
                                    text: msg.mediaLabel
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.bodySize
                                    color: Theme.text
                                }
                            }
                            Text {
                                visible: msg.bodyText !== ""
                                width: parent.width
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                                text: msg.bodyText
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.bodySize
                                font.italic: msg.modelData.type === "deleted"
                                color: Theme.text
                            }
                        }
                        Text {
                            id: footer
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 5
                            text: msg.modelData.ack < 0 ? qsTr("Not sent")
                                : Qt.formatTime(new Date(msg.modelData.timestamp * 1000), "HH:mm") + (msg.mine ? "  " + app.ticks(msg.modelData.ack) : "")
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.footnoteSize
                            color: msg.modelData.ack < 0 ? Theme.danger : msg.mine && msg.modelData.ack >= 3 ? Theme.accent : Theme.textTertiary
                        }
                        MouseArea {
                            anchors.fill: parent
                            z: -1
                            onPressAndHold: page.messageMenu(msg.modelData)
                        }
                    }
                    Rectangle {
                        visible: !!msg.modelData.reaction
                        anchors.top: bubble.bottom
                        anchors.topMargin: -6
                        x: msg.mine ? bubble.x + bubble.width - width - 12 : bubble.x + 12
                        width: reactionText.implicitWidth + 12
                        height: 24
                        radius: 12
                        color: Theme.surfaceRaised
                        border.color: Theme.background
                        border.width: 2
                        Text { id: reactionText; anchors.centerIn: parent; text: msg.modelData.reaction || ""; font.pixelSize: Theme.captionSize }
                    }
                }
            }

            // Header: the chat, its number or its group
            Rectangle {
                width: parent.width
                height: Theme.statusBarHeight + 64
                color: Theme.background
                IconButton {
                    x: 10
                    y: Theme.statusBarHeight + 10
                    size: 40
                    iconName: "chevron-left"
                    onClicked: page.stack.pop()
                }
                Avatar {
                    x: 58
                    y: Theme.statusBarHeight + 9
                    size: 44
                    chatId: page.chat ? page.chat.id : ""
                    name: app.nameOf(page.live)
                }
                Column {
                    x: 114
                    width: parent.width - 126
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: Theme.statusBarHeight / 2
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: app.nameOf(page.live)
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.headlineSize
                        font.weight: Font.DemiBold
                        color: Theme.text
                    }
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: page.channel ? qsTr("Channel")
                            : page.group ? qsTr("Group · tap for info")
                            : (page.live.name && page.live.phone ? page.live.phone : qsTr("WhatsApp"))
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.captionSize
                        color: Theme.textSecondary
                    }
                }
                MouseArea {
                    x: 58
                    width: parent.width - 58
                    height: parent.height
                    enabled: page.group
                    onClicked: page.stack.open(groupPage, { chat: page.live })
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
            }

            Text {
                visible: page.sendError !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: replyBar.visible ? replyBar.top : composer.top
                anchors.bottomMargin: 8
                width: parent.width - 32
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: page.sendError
                font.family: Theme.fontFamily
                font.pixelSize: Theme.captionSize
                color: Theme.textSecondary
            }

            // Answering a message
            Rectangle {
                id: replyBar
                visible: page.replyTo !== null
                anchors.bottom: composer.top
                anchors.bottomMargin: 6
                x: 12
                width: parent.width - 24
                height: 52
                radius: 12
                color: Theme.surface
                Rectangle { width: 4; height: parent.height; radius: 2; color: app.green }
                Text {
                    x: 14
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 64
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.Wrap
                    text: page.replyTo ? (page.replyTo.body || app.typeLabel(page.replyTo.type)) : ""
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.captionSize
                    color: Theme.textSecondary
                }
                IconButton {
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    size: 32
                    iconName: "close"
                    onClicked: page.replyTo = null
                }
            }

            // Composer (not in channels: they are read only)
            Row {
                id: composer
                visible: !page.channel
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 28
                x: 10
                spacing: 8
                height: 48
                IconButton {
                    size: 48
                    iconName: "paperclip"
                    onClicked: Permissions.request("astra.permission.MEDIA", function(granted) {
                        if (granted)
                            attach.load()
                    })
                }
                TextField {
                    id: input
                    width: page.width - 20 - 48 * 2 - 16
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

            // Photos and videos to send
            Sheet {
                id: attach
                title: qsTr("Send a Photo or Video")
                property var items: []
                function load() {
                    Application.mediaAsync(["*.jpg", "*.jpeg", "*.png", "*.webp", "*.mp4", "*.mov", "*.3gp"], function(list) {
                        attach.items = list.slice(0, 120)
                    })
                    open()
                }
                Flickable {
                    width: parent.width
                    height: Math.min(contentHeight, 460)
                    contentHeight: grid.height
                    clip: true
                    Grid {
                        id: grid
                        columns: 3
                        spacing: 4
                        width: parent.width
                        Repeater {
                            model: attach.items
                            delegate: Image {
                                required property var modelData
                                width: (grid.width - 8) / 3
                                height: width
                                source: modelData.video ? "" : modelData.url
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                sourceSize.width: 240
                                clip: true
                                Rectangle {
                                    anchors.fill: parent
                                    visible: modelData.video
                                    color: Theme.surfaceRaised
                                    Icon { anchors.centerIn: parent; name: "video"; size: 28; color: Theme.textSecondary }
                                }
                                MouseArea { anchors.fill: parent; onClicked: page.sendFile(modelData.path) }
                            }
                        }
                    }
                }
                EmptyState {
                    visible: attach.items.length === 0
                    iconName: "image"
                    title: qsTr("No photos")
                    message: ""
                }
            }

            // Voice messages and audio
            MediaPlayer {
                id: player
                property string playing: ""
                audioOutput: AudioOutput {}
                function toggle(m) {
                    if (playing === m.id && playbackState === MediaPlayer.PlayingState) {
                        pause()
                        return
                    }
                    if (playing !== m.id) {
                        stop()
                        source = app.mediaUrl(m)
                        playing = m.id
                    }
                    play()
                }
                onPlaybackStateChanged: if (playbackState === MediaPlayer.StoppedState) playing = ""
            }
        }
    }

    // ---- a group: its description and members ------------------------------------------------
    Component {
        id: groupPage
        Page {
            id: gpage
            property var chat
            property var info: null
            property string message: ""
            title: info ? info.name : app.nameOf(chat)
            Component.onCompleted: app.api("GET", "group?chatId=" + encodeURIComponent(chat.id), null, (c, body, err) => {
                gpage.info = body
                gpage.message = err || ""
            })
            Spinner { visible: !gpage.info && !gpage.message; anchors.horizontalCenter: parent.horizontalCenter }
            Text {
                visible: gpage.message !== ""
                width: parent.width
                wrapMode: Text.Wrap
                text: gpage.message
                font.family: Theme.fontFamily
                font.pixelSize: Theme.bodySize
                color: Theme.textSecondary
            }
            Item {
                width: parent.width
                height: 120
                Avatar { anchors.centerIn: parent; size: 100; chatId: gpage.chat.id; name: gpage.title }
            }
            Text {
                visible: !!(gpage.info && gpage.info.topic)
                width: parent.width
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                text: gpage.info ? gpage.info.topic : ""
                font.family: Theme.fontFamily
                font.pixelSize: Theme.bodySize
                color: Theme.textSecondary
            }
            ListGroup {
                visible: !!gpage.info
                title: gpage.info ? qsTr("%n member(s)", "", gpage.info.members.length) : ""
                Repeater {
                    model: gpage.info ? gpage.info.members : []
                    delegate: ListItem {
                        required property var modelData
                        required property int index
                        text: modelData.me ? qsTr("You") : (modelData.name || modelData.phone || qsTr("Someone"))
                        subtitle: modelData.me ? "" : (modelData.name ? modelData.phone : "")
                        value: modelData.admin ? qsTr("Admin") : ""
                        separator: index < gpage.info.members.length - 1
                        onClicked: if (!modelData.me && modelData.phone) {
                            app.api("POST", "newChat", { phone: modelData.phone }, (c, body, err) => {
                                if (!err)
                                    stack.open(conversationPage, { chat: body })
                            })
                        }
                    }
                }
            }
            ListGroup {
                visible: !!gpage.info
                ListItem {
                    text: qsTr("Leave Group")
                    destructive: true
                    separator: false
                    onClicked: Dialogs.show({ title: qsTr("Leave %1?").arg(gpage.title),
                                              buttons: [{ id: "cancel", label: qsTr("Cancel") },
                                                        { id: "leave", label: qsTr("Leave"), style: "destructive" }] },
                                            function(answer) {
                        if (answer === "leave")
                            app.api("POST", "leaveGroup", { chatId: gpage.chat.id }, (c, body, err) => {
                                if (err)
                                    gpage.message = err
                                else
                                    stack.pop(null)
                            })
                    })
                }
            }
        }
    }

    // ---- a new chat: a contact, a number, or a new group ---------------------------------------
    Sheet {
        id: newChat
        title: groupMode ? qsTr("New Group") : qsTr("New Chat")
        property bool groupMode: false
        property var picked: []
        property string error: ""
        function start(group) {
            groupMode = group
            picked = []
            error = ""
            find.text = ""
            open()
        }
        readonly property string digits: find.text.replace(/[^0-9]/g, "")
        readonly property var matches: app.contacts.filter(c => !find.text.trim()
            || c.name.toLowerCase().includes(find.text.trim().toLowerCase()) || c.phone.includes(newChat.digits || "§")).slice(0, 80)
        function openChat(chat) {
            newChat.close()
            stack.open(conversationPage, { chat: chat })
        }
        Column {
            width: parent.width
            spacing: 12
            TextField {
                id: groupName
                visible: newChat.groupMode
                width: parent.width
                placeholder: qsTr("Group name")
            }
            TextField {
                id: find
                width: parent.width
                placeholder: newChat.groupMode ? qsTr("Add people") : qsTr("Name or number with country code")
            }
            Text {
                visible: newChat.error !== ""
                width: parent.width
                wrapMode: Text.Wrap
                text: newChat.error
                font.family: Theme.fontFamily
                font.pixelSize: Theme.captionSize
                color: Theme.danger
            }
            Button {
                visible: newChat.groupMode
                width: parent.width
                enabled: groupName.text.trim() !== "" && newChat.picked.length > 0
                text: qsTr("Create Group (%1)").arg(newChat.picked.length)
                onClicked: app.api("POST", "createGroup", { name: groupName.text, participants: newChat.picked }, (c, body, err) => {
                    newChat.error = err
                    if (!err)
                        newChat.openChat(body)
                })
            }
            Flickable {
                width: parent.width
                height: Math.min(contentHeight, 420)
                contentHeight: people.height
                clip: true
                Column {
                    id: people
                    width: parent.width
                    ListItem {
                        visible: !newChat.groupMode && !find.text.trim()
                        width: parent.width
                        iconName: "person-add"
                        text: qsTr("New Group")
                        chevron: true
                        onClicked: newChat.groupMode = true
                    }
                    ListItem {
                        visible: !newChat.groupMode && newChat.digits.length >= 6
                        width: parent.width
                        iconName: "message"
                        text: qsTr("Chat with +%1").arg(newChat.digits)
                        onClicked: app.api("POST", "newChat", { phone: newChat.digits }, (c, body, err) => {
                            newChat.error = err
                            if (!err)
                                newChat.openChat(body)
                        })
                    }
                    Repeater {
                        model: newChat.matches
                        delegate: ListItem {
                            required property var modelData
                            width: people.width
                            text: modelData.name
                            subtitle: modelData.phone
                            selected: newChat.groupMode && newChat.picked.indexOf(modelData.id) >= 0
                            onClicked: {
                                if (newChat.groupMode) {
                                    const i = newChat.picked.indexOf(modelData.id)
                                    newChat.picked = i >= 0 ? newChat.picked.filter(p => p !== modelData.id) : newChat.picked.concat([modelData.id])
                                } else {
                                    newChat.openChat({ id: modelData.id, name: modelData.name, phone: modelData.phone })
                                }
                            }
                        }
                    }
                    EmptyState {
                        visible: newChat.matches.length === 0 && newChat.digits.length < 6
                        iconName: "person"
                        title: qsTr("No contacts")
                        message: qsTr("Your contacts come from your main phone's address book: they arrive a few minutes after linking.")
                    }
                }
            }
        }
    }

    // ---- photos and videos full screen -------------------------------------------------------
    Rectangle {
        id: viewer
        property var item: null
        function show(m) { item = m }
        anchors.fill: parent
        visible: item !== null
        color: Theme.scrim
        z: 10
        Rectangle { anchors.fill: parent; color: Theme.background; opacity: 0.9 }
        Image {
            anchors.fill: parent
            visible: viewer.item && viewer.item.type !== "video"
            source: visible ? app.mediaUrl(viewer.item) : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
        }
        VideoOutput {
            id: video
            anchors.fill: parent
            visible: viewer.item && viewer.item.type === "video"
        }
        MediaPlayer {
            id: videoPlayer
            videoOutput: video
            audioOutput: AudioOutput {}
            source: viewer.item && viewer.item.type === "video" ? app.mediaUrl(viewer.item) : ""
            onSourceChanged: if (source != "") play()
        }
        MouseArea {
            anchors.fill: parent
            onClicked: {
                videoPlayer.stop()
                viewer.item = null
            }
        }
        Text {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 40
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: viewer.item ? viewer.item.body || "" : ""
            font.family: Theme.fontFamily
            font.pixelSize: Theme.bodySize
            color: Theme.text
        }
    }

    // ---- status updates, one after the other ------------------------------------------------
    Rectangle {
        id: storyViewer
        property int person: -1
        property int item: 0
        readonly property var current: person >= 0 && person < app.statuses.length ? app.statuses[person] : null
        readonly property var story: current ? current.items[item] : null
        function show(index) {
            person = index
            item = 0
            timer.restart()
        }
        function close() {
            storyPlayer.stop()
            person = -1
        }
        function next() {
            if (!current)
                return
            if (item + 1 < current.items.length) {
                item++
            } else if (person + 1 < app.statuses.length) {
                person++
                item = 0
            } else {
                close()
                return
            }
            timer.restart()
        }
        function previous() {
            if (item > 0)
                item--
            else if (person > 0) {
                person--
                item = 0
            }
            timer.restart()
        }
        anchors.fill: parent
        visible: current !== null
        color: story && !story.hasMedia ? app.green : Theme.background
        z: 11
        Timer {
            id: timer
            interval: storyViewer.story && storyViewer.story.type === "video" ? Math.max(5, storyViewer.story.seconds || 15) * 1000 : 5000
            running: storyViewer.visible
            onTriggered: storyViewer.next()
        }
        Image {
            anchors.fill: parent
            visible: !!(storyViewer.story && storyViewer.story.hasMedia && storyViewer.story.type !== "video")
            source: visible ? app.mediaUrl(storyViewer.story) : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
        }
        VideoOutput { id: storyVideo; anchors.fill: parent; visible: !!(storyViewer.story && storyViewer.story.type === "video") }
        MediaPlayer {
            id: storyPlayer
            videoOutput: storyVideo
            audioOutput: AudioOutput {}
            source: storyViewer.story && storyViewer.story.type === "video" ? app.mediaUrl(storyViewer.story) : ""
            onSourceChanged: if (source != "") play()
        }
        Text {
            anchors.centerIn: parent
            width: parent.width - 60
            visible: !!(storyViewer.story && storyViewer.story.body)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: storyViewer.story ? storyViewer.story.body : ""
            font.family: Theme.fontFamily
            font.pixelSize: storyViewer.story && storyViewer.story.hasMedia ? Theme.bodySize : Theme.titleSize
            font.weight: Font.DemiBold
            color: storyViewer.story && !storyViewer.story.hasMedia ? Theme.accentText : Theme.text
        }
        // Progress, who and when
        Row {
            x: 10
            y: Theme.statusBarHeight + 6
            width: parent.width - 20
            spacing: 4
            Repeater {
                model: storyViewer.current ? storyViewer.current.items.length : 0
                delegate: Rectangle {
                    required property int index
                    width: (parent.width - 4 * ((storyViewer.current ? storyViewer.current.items.length : 1) - 1)) / Math.max(1, storyViewer.current ? storyViewer.current.items.length : 1)
                    height: 3
                    radius: 1.5
                    color: index <= storyViewer.item ? Theme.text : Theme.separator
                }
            }
        }
        Row {
            x: 14
            y: Theme.statusBarHeight + 20
            spacing: 10
            Avatar {
                size: 38
                chatId: storyViewer.current ? storyViewer.current.id : ""
                name: storyViewer.current ? storyViewer.current.name : ""
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    text: storyViewer.current ? (storyViewer.current.name || storyViewer.current.phone) : ""
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.bodySize
                    font.weight: Font.DemiBold
                    color: Theme.text
                }
                Text {
                    text: storyViewer.story ? app.when(storyViewer.story.timestamp) : ""
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.captionSize
                    color: Theme.textSecondary
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            anchors.topMargin: Theme.statusBarHeight + 70
            onClicked: (m) => m.x < width / 3 ? storyViewer.previous() : storyViewer.next()
            onPressAndHold: timer.stop()
            onReleased: if (!timer.running && storyViewer.visible) timer.start()
        }
        IconButton {
            anchors.right: parent.right
            anchors.rightMargin: 12
            y: Theme.statusBarHeight + 20
            size: 38
            iconName: "close"
            onClicked: storyViewer.close()
        }
    }

    // ---- settings -----------------------------------------------------------------------------
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
                                              message: qsTr("Your chats are removed from this phone. You can link it again by scanning a new code."),
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
                text: qsTr("WhatsAstra speaks WhatsApp's protocol on this phone, as a linked device of your main phone: messages are end to end encrypted to this phone and pass through no other server. WhatsApp does not support other apps officially: a linked account can be restricted by WhatsApp. WhatsAstra is not made by or affiliated with WhatsApp or Meta.")
                font.family: Theme.fontFamily
                font.pixelSize: Theme.captionSize
                color: Theme.textTertiary
            }
        }
    }
}

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
    readonly property color textMine: Theme.text

    property string base: ""            // http://127.0.0.1:<port>
    property string token: ""
    property string status: "loading"   // loading starting qr_ready authenticating ready offline noservice
    property string error: ""
    property string qr: ""
    property string myName: ""
    property string myPhone: ""
    property var chats: []
    property int seq: 0
    property string openChat: ""
    property var openPage: null
    property bool showArchived: false

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
    function avatarUrl(chatId) { return app.base ? app.base + "/avatar?chatId=" + encodeURIComponent(chatId) + "&token=" + app.token : "" }

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
            if (app.status === "ready")
                app.refreshChats()
        })
    }
    function refreshChats() {
        api("GET", "chats", null, (code, body, err) => { if (!err) app.chats = body || [] })
    }
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
        const chat = Qt.application.state === Qt.ApplicationActive && app.openPage ? app.openChat : ""
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
    function nameOf(chat) {
        return chat && chat.name ? chat.name : "+" + String(chat ? chat.id : "").split("@")[0]
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

    // ---- linked: chats, conversations, settings ----------------------------------------
    PageStack {
        id: stack
        anchors.fill: parent
        visible: app.status === "ready" || (depth > 1 && app.status === "authenticating")
        Component.onCompleted: open(chatsPage)
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
                        color: "white"
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

    // ---- chats ----------------------------------------------------------------------------
    Component {
        id: chatsPage
        Page {
            id: chatsList
            title: app.showArchived ? qsTr("Archived") : qsTr("Chats")
            actions: Row {
                spacing: 8
                IconButton { iconName: "edit"; onClicked: newChat.open() }
                IconButton { iconName: "settings"; onClicked: stack.open(settingsPage) }
            }

            readonly property string query: search.text.trim().toLowerCase()
            readonly property var visibleChats: app.chats.filter(c =>
                (chatsList.query ? String(app.nameOf(c)).toLowerCase().includes(chatsList.query) : c.archived === app.showArchived))
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
                            chat: row.modelData
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
                                font.pixelSize: Theme.captionSize + 1
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
                                        color: "white"
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
    }

    // A chat's photo, or its initials.
    component Avatar: Rectangle {
        property var chat
        property real size: 52
        width: size
        height: size
        radius: size / 2
        color: Theme.surfaceRaised
        clip: true
        Text {
            anchors.centerIn: parent
            visible: photo.status !== Image.Ready
            text: parent.chat && parent.chat.isGroup ? "👥" : app.initials(app.nameOf(parent.chat))
            font.family: Theme.fontFamily
            font.pixelSize: parent.size * 0.36
            font.weight: Font.DemiBold
            color: Theme.textSecondary
        }
        Image {
            id: photo
            anchors.fill: parent
            source: parent.chat ? app.avatarUrl(parent.chat.id) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 128
            visible: status === Image.Ready
        }
    }

    // ---- a conversation ---------------------------------------------------------------------
    Component {
        id: conversationPage
        Item {
            id: page
            property var stack
            property var chat
            property var messages: []
            property var replyTo: null
            property string sendError: ""
            property bool older: true

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
                app.api("GET", "messages?chatId=" + encodeURIComponent(chat.id) + "&limit=60", null, (code, body, err) => {
                    if (err)
                        return
                    page.messages = body || []
                    page.older = page.messages.length >= 60
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
                const buttons = [{ id: "reply", label: qsTr("Reply") }]
                if (m.body)
                    buttons.push({ id: "copy", label: qsTr("Copy") })
                if (m.hasMedia)
                    buttons.push({ id: "save", label: qsTr("Save to Files") })
                for (const e of ["👍", "❤️", "😂", "😮", "😢", "🙏"])
                    buttons.push({ id: "react:" + e, label: e })
                if (m.fromMe && m.type !== "deleted" && Date.now() / 1000 - m.timestamp < 2 * 86400)
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
                anchors.topMargin: Theme.statusBarHeight + 60
                anchors.bottomMargin: composer.height + 36 + (replyBar.visible ? replyBar.height : 0)
                spacing: 3
                clip: true
                model: page.messages
                onAtYBeginningChanged: if (atYBeginning && contentHeight > height) page.loadOlder()
                delegate: Item {
                    id: msg
                    required property var modelData
                    required property int index
                    readonly property bool mine: modelData.fromMe === true
                    readonly property bool group: page.chat && String(page.chat.id).endsWith("@g.us")
                    readonly property bool newDay: index === 0 || new Date(page.messages[index - 1].timestamp * 1000).toDateString()
                                                                   !== new Date(modelData.timestamp * 1000).toDateString()
                    readonly property real maxWidth: list.width * 0.8
                    width: list.width
                    height: (newDay ? 34 : 0) + bubble.height + (modelData.reaction ? 16 : 4)

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
                        width: Math.min(msg.maxWidth, Math.max(content.implicitWidth, footer.implicitWidth + 8) + 20)
                        height: content.implicitHeight + footer.implicitHeight + 14
                        radius: 14
                        color: msg.mine ? app.bubbleMine : Theme.surface
                        Column {
                            id: content
                            x: 10
                            y: 6
                            width: bubble.width - 20
                            spacing: 4
                            Text {
                                visible: msg.group && !msg.mine && msg.modelData.senderName !== undefined
                                text: msg.modelData.senderName || ("+" + String(msg.modelData.sender || "").split("@")[0])
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
                                visible: msg.modelData.hasMedia && (msg.modelData.type === "image" || msg.modelData.type === "sticker")
                                width: visible ? Math.min(content.width, 260) : 0
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
                                visible: msg.modelData.hasMedia && ["video", "voice", "audio", "document"].indexOf(msg.modelData.type) >= 0
                                spacing: 10
                                IconButton {
                                    size: 40
                                    iconName: msg.modelData.type === "document" ? "file"
                                            : player.playing === msg.modelData.id ? "pause" : "play"
                                    color: app.green
                                    iconColor: "white"
                                    onClicked: msg.modelData.type === "document" ? page.messageMenu(msg.modelData)
                                             : msg.modelData.type === "video" ? viewer.show(msg.modelData)
                                             : player.toggle(msg.modelData)
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, content.width - 50)
                                    elide: Text.ElideMiddle
                                    text: msg.modelData.type === "document" ? (msg.modelData.fileName || qsTr("Document"))
                                        : app.typeLabel(msg.modelData.type) + (msg.modelData.seconds ? " · " + app.duration(msg.modelData.seconds) : "")
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.bodySize
                                    color: msg.mine ? app.textMine : Theme.text
                                }
                            }
                            Text {
                                visible: text !== ""
                                width: Math.min(implicitWidth, content.width)
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                                text: msg.modelData.type === "deleted" ? "🚫 " + app.typeLabel("deleted")
                                    : msg.modelData.body || (!msg.modelData.hasMedia ? app.typeLabel(msg.modelData.type) : "")
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.bodySize
                                font.italic: msg.modelData.type === "deleted"
                                color: msg.mine ? app.textMine : Theme.text
                            }
                        }
                        Text {
                            id: footer
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 4
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
                        Text { id: reactionText; anchors.centerIn: parent; text: msg.modelData.reaction || ""; font.pixelSize: 13 }
                    }
                }
            }

            // Header
            Rectangle {
                width: parent.width
                height: Theme.statusBarHeight + 60
                color: Theme.background
                IconButton {
                    x: 10
                    y: Theme.statusBarHeight + 8
                    size: 40
                    iconName: "chevron-left"
                    onClicked: page.stack.pop()
                }
                Avatar {
                    x: 58
                    y: Theme.statusBarHeight + 8
                    size: 42
                    chat: page.chat
                }
                Column {
                    x: 112
                    width: parent.width - 124
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: Theme.statusBarHeight / 2
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: page.chat ? (app.chats.find(c => c.id === page.chat.id) || page.chat).name || app.nameOf(page.chat) : ""
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.headlineSize
                        font.weight: Font.DemiBold
                        color: Theme.text
                    }
                    Text {
                        text: page.chat && String(page.chat.id).endsWith("@g.us") ? qsTr("Group") : "+" + String(page.chat ? page.chat.id : "").split("@")[0]
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

            // Composer
            Row {
                id: composer
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
                    iconColor: input.text.trim() ? "white" : Theme.textSecondary
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

            // Photos and videos full screen
            Rectangle {
                id: viewer
                property var item: null
                function show(m) { item = m }
                anchors.fill: parent
                visible: item !== null
                color: "black"
                z: 10
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
                    color: "white"
                }
            }
        }
    }

    // Starting a chat with a phone number (from Chats).
    Sheet {
        id: newChat
        title: qsTr("New Chat")
        property string error: ""
        Column {
            width: parent.width
            spacing: 14
            TextField {
                id: phone
                width: parent.width
                placeholder: qsTr("Phone number with country code")
                inputMethodHints: Qt.ImhDialableCharactersOnly
                onAccepted: start.clicked()
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
                id: start
                width: parent.width
                text: qsTr("Start Chat")
                enabled: phone.text.trim().length >= 6
                onClicked: app.api("POST", "newChat", { phone: phone.text }, (code, body, err) => {
                    newChat.error = err
                    if (err)
                        return
                    newChat.close()
                    phone.text = ""
                    stack.open(conversationPage, { chat: body })
                })
            }
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

import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.boyoyooo.whatsmarchy"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // --- mirrored host state --------------------------------------------------
  readonly property bool   everLoaded:  hostWidget ? hostWidget.everLoaded === true : false
  readonly property bool   fetching:    hostWidget ? hostWidget.fetching === true : false
  readonly property string errorText:   hostWidget ? hostWidget.errorText : ""
  readonly property string mode:        hostWidget ? hostWidget.mode : "all"
  readonly property bool   paused:      hostWidget ? hostWidget.paused === true : false
  readonly property bool   syncRunning: hostWidget ? hostWidget.syncRunning === true : false
  readonly property int    totalNew:    hostWidget ? hostWidget.totalNew : 0
  readonly property bool   truncated:   hostWidget ? hostWidget.truncated === true : false
  readonly property var    chats:       hostWidget ? hostWidget.chats : []
  readonly property string widgetLabel: hostWidget ? hostWidget.widgetLabel : ""
  readonly property string ctlScript:   hostWidget ? hostWidget.ctlScript : ""
  readonly property color  accentColor: hostWidget ? hostWidget.accentColor : "#25d366"
  readonly property color  alertColor:  hostWidget ? hostWidget.alertColor : "#e5534b"

  readonly property string iconDm:       "\u{F0361}"
  readonly property string iconGroup:    "\u{F0B79}"
  readonly property string iconPlay:     "\u{F040A}"
  readonly property string iconImage:    "\u{F02E9}"
  readonly property string iconDoc:      "\u{F0219}"
  readonly property string iconMic:      "\u{F036C}"
  readonly property string iconSend:     "\u{F048A}"
  readonly property string iconOpen:     "\u{F03CC}"
  readonly property string iconSettings: "\u{F0493}"
  readonly property string iconMarkRead: "\u{F012C}"
  readonly property string iconRefresh:  "\u{F0450}"

  // --- panel-local UI state -------------------------------------------------
  property string expandedJid: ""
  property bool   settingsOpen: false
  property string actionError: ""
  // Keyed by "<jid>|<msgId>" so an id colliding across chats can't cross wires.
  property var    mediaPaths: ({})
  property var    transcripts: ({})
  property string busyKey: ""
  property var    allowList: []
  property bool   whisperAvailable: false
  property string whisperDetail: ""
  property bool   confirmInstallOpen: false

  function msgKey(jid, id) { return String(jid) + "|" + String(id) }

  // A local path becomes a file: URL. Percent-encoding matters: a store path
  // with a space, '#' or '?' would otherwise be truncated or misread as a
  // fragment/query and silently load the wrong file (or nothing).
  function fileUrl(path) {
    return "file://" + encodeURI(String(path)).replace(/#/g, "%23").replace(/\?/g, "%3F")
  }

  // Mutating a `property var` object in place does not fire its change signal,
  // so every update goes through a fresh copy. Bindings that read these maps
  // would otherwise keep showing the pre-update value.
  function withEntry(obj, key, value) {
    var next = ({})
    for (var k in obj) next[k] = obj[k]
    next[key] = value
    return next
  }

  function open()  { root.controller.show() }
  function close() { root.controller.hide() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  onOpenedChanged: {
    if (root.opened) {
      root.actionError = ""
      configProc.reload()
      whisperProc.probe()
    } else {
      root.expandedJid = ""
      root.settingsOpen = false
      root.confirmInstallOpen = false
    }
  }

  // Keeps "2 min ago" honest while the panel sits open between polls.
  property int nowTick: 0
  Timer { interval: 20000; running: root.opened; repeat: true; onTriggered: root.nowTick++ }

  function agoText(epoch) {
    root.nowTick // dependency: re-evaluate on each tick
    if (!epoch) return ""
    var secs = Math.max(0, Math.round(Date.now() / 1000) - epoch)
    if (secs < 60)    return "now"
    if (secs < 3600)  return Math.round(secs / 60) + "m"
    if (secs < 86400) return Math.round(secs / 3600) + "h"
    return Math.round(secs / 86400) + "d"
  }

  function mediaGlyph(m) {
    if (!m) return ""
    if (m.isVoice) return root.iconMic
    switch (String(m.mediaType)) {
      case "image": case "sticker": return root.iconImage
      case "video": case "gif":     return root.iconPlay
      case "audio":                 return root.iconMic
      default:                      return root.iconDoc
    }
  }

  function mediaLabel(m) {
    if (!m) return ""
    if (m.isVoice) return "Voice message"
    switch (String(m.mediaType)) {
      case "image":    return "Photo"
      case "sticker":  return "Sticker"
      case "video":    return "Video"
      case "gif":      return "GIF"
      case "audio":    return "Audio"
      case "document": return m.filename ? String(m.filename) : "Document"
      case "location": return "Location"
      default:         return "Attachment"
    }
  }

  // --- action plumbing ------------------------------------------------------
  // Every mutating call goes through wa-ctl.sh, which validates its own
  // arguments; the panel never builds a wacli command line itself.
  function runAction(args, onDone) {
    if (actionProc.running) {
      // One action at a time. Silently swallowing the click would look like the
      // button is broken, which is worse than saying why nothing happened.
      root.actionError = "Still working on the previous action…"
      return
    }
    root.actionError = ""
    actionProc.pending = onDone || null
    actionProc.command = [root.ctlScript].concat(args)
    actionProc.running = true
  }

  Process {
    id: actionProc
    running: false
    property var pending: null
    stdout: StdioCollector {
      onStreamFinished: {
        var cb = actionProc.pending
        actionProc.pending = null
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "action failed")
          root.busyKey = ""
          return
        }
        if (cb) cb(payload)
      }
    }
  }

  Process {
    id: configProc
    running: false
    function reload() { if (!configProc.running) configProc.running = true }
    command: [root.ctlScript, "config-get"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var p = JSON.parse(this.text)
          if (p && p.ok === true && Array.isArray(p.allow)) root.allowList = p.allow
        } catch (e) { /* leave the previous list rather than blanking it */ }
      }
    }
  }

  Process {
    id: whisperProc
    running: false
    function probe() { if (!whisperProc.running) whisperProc.running = true }
    command: [root.ctlScript, "whisper-status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var p = JSON.parse(this.text)
          root.whisperAvailable = !!(p && p.ok === true && p.available === true)
          root.whisperDetail = String((p && (p.detail || p.tool)) || "")
        } catch (e) {
          root.whisperAvailable = false
          root.whisperDetail = ""
        }
      }
    }
  }

  // Emitted after a reply lands, so the delegate that owns the (repeater-
  // scoped) input can clear itself. The Process below lives at panel scope and
  // cannot reach any individual delegate's TextField by id.
  signal replySent(string jid)

  // Sends the reply body over stdin, never as an argument: the text is the
  // user's private message and has no business in /proc/<pid>/cmdline.
  Process {
    id: sendProc
    running: false
    stdinEnabled: false
    property string body: ""
    property string jid: ""
    onStarted: {
      write(sendProc.body)
      sendProc.body = ""
      // Closing stdin is what lets wa-ctl.sh's `cat` return; without it the
      // send would hang until the process was killed.
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        root.busyKey = ""
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "send failed")
          return
        }
        root.actionError = ""
        root.replySent(sendProc.jid)
      }
    }
  }

  Process {
    id: allowProc
    running: false
    stdinEnabled: false
    property string body: "[]"
    onStarted: {
      write(allowProc.body)
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true)
          root.actionError = String((payload && payload.error) || "could not save the allow list")
        if (root.hostWidget) root.hostWidget.refresh()
      }
    }
  }

  function saveAllow(values) {
    if (allowProc.running) return
    var arr = []
    for (var i = 0; i < values.length; i++) arr.push(String(values[i]))
    root.allowList = arr
    allowProc.body = JSON.stringify(arr)
    allowProc.command = [root.ctlScript, "set-allow"]
    allowProc.stdinEnabled = true
    allowProc.running = true
  }

  function setMode(newMode) {
    runAction(["set-mode", newMode], function () {
      if (root.hostWidget) root.hostWidget.refresh()
    })
  }

  function markSeen(jid, ts) {
    runAction(["mark-seen", String(jid), String(Math.round(ts))], function () {
      if (root.hostWidget) root.hostWidget.refresh()
    })
  }

  function markAllSeen() {
    runAction(["mark-all-seen", String(Math.round(Date.now() / 1000))], function () {
      root.expandedJid = ""
      if (root.hostWidget) root.hostWidget.refresh()
    })
  }

  function openWebApp() { runAction(["webapp"], null) }

  function sendReply(jid, text) {
    if (sendProc.running) return
    var body = String(text || "").trim()
    if (body === "") return
    root.busyKey = "send"
    sendProc.jid = String(jid)
    sendProc.body = body
    sendProc.command = [root.ctlScript, "send", String(jid)]
    sendProc.stdinEnabled = true
    sendProc.running = true
  }

  function playVoice(jid, id) {
    root.busyKey = root.msgKey(jid, id)
    runAction(["play", String(jid), String(id)], function () { root.busyKey = "" })
  }

  function openAttachment(jid, id) {
    root.busyKey = root.msgKey(jid, id)
    runAction(["open", String(jid), String(id)], function () { root.busyKey = "" })
  }

  function transcribe(jid, id) {
    var key = root.msgKey(jid, id)
    root.busyKey = key
    runAction(["transcribe", String(jid), String(id)], function (payload) {
      root.transcripts = root.withEntry(root.transcripts, key, String(payload.text || ""))
      root.busyKey = ""
    })
  }

  // --- thumbnail queue ------------------------------------------------------
  // One resolver at a time: a chat with a dozen photos should not fan out into
  // a dozen concurrent wacli downloads the moment its row is expanded.
  property var thumbQueue: []

  function queueThumb(jid, id) {
    var key = root.msgKey(jid, id)
    if (root.mediaPaths[key] !== undefined) return
    for (var i = 0; i < root.thumbQueue.length; i++)
      if (root.thumbQueue[i].key === key) return
    var q = root.thumbQueue.slice()
    q.push({ key: key, jid: String(jid), id: String(id) })
    root.thumbQueue = q
    pumpThumbs()
  }

  function pumpThumbs() {
    if (thumbProc.running) return
    if (root.thumbQueue.length === 0) return
    var q = root.thumbQueue.slice()
    var job = q.shift()
    root.thumbQueue = q
    thumbProc.key = job.key
    thumbProc.command = [root.ctlScript, "media", job.jid, job.id]
    thumbProc.running = true
  }

  Process {
    id: thumbProc
    running: false
    property string key: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        // "" records a definitive failure so the queue does not retry this
        // attachment on every repaint.
        root.mediaPaths = root.withEntry(root.mediaPaths, thumbProc.key,
          (payload && payload.ok === true) ? String(payload.path) : "")
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.pumpThumbs)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.confirmInstallOpen) { root.confirmInstallOpen = false; return }
        root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // --- header ---------------------------------------------------------
        Item {
          width: parent.width
          height: Math.max(titleCol.implicitHeight, headerActions.implicitHeight)

          Column {
            id: titleCol
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - headerActions.implicitWidth - Style.space(8)
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: root.widgetLabel !== "" ? root.widgetLabel : "WhatsApp"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              text: {
                if (!root.everLoaded) return "loading…"
                if (root.errorText !== "") return "unavailable"
                if (root.paused) return "notifications paused"
                if (root.totalNew === 0) return "nothing new"
                return root.totalNew + (root.truncated ? "+" : "")
                  + (root.totalNew === 1 && !root.truncated ? " new message" : " new messages")
              }
              color: root.totalNew > 0 && root.errorText === "" && !root.paused
                ? root.accentColor
                : Util.alpha(root.barForeground, 0.6)
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              iconText: root.iconMarkRead
              tooltipText: "Mark everything as read"
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              visible: root.totalNew > 0
              onClicked: root.markAllSeen()
            }
            PanelActionButton {
              id: refreshBtn
              iconText: root.iconRefresh
              tooltipText: "Refresh"
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              onClicked: if (root.hostWidget) root.hostWidget.refresh()

              RotationAnimator {
                target: refreshBtn
                from: 0; to: 360
                duration: 700
                loops: Animation.Infinite
                running: root.fetching
              }
            }
            PanelActionButton {
              iconText: root.iconSettings
              tooltipText: "Who may notify me"
              foreground: root.settingsOpen ? root.accentColor : root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              onClicked: root.settingsOpen = !root.settingsOpen
            }
          }
        }

        // --- faults ----------------------------------------------------------
        Text {
          width: parent.width
          visible: root.errorText !== ""
          text: root.errorText
          textFormat: Text.PlainText
          color: root.alertColor
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: root.actionError !== ""
          text: root.actionError
          textFormat: Text.PlainText
          color: root.alertColor
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.bodySmall
        }

        // A stopped sync is the difference between "no new messages" and "no
        // news reaching this machine". Saying so beats a silently frozen count.
        Text {
          width: parent.width
          visible: root.everLoaded && root.errorText === "" && !root.syncRunning
          text: "wacli sync is not running — this list is frozen. Start it with:  systemctl --user start whatsmarchy-sync"
          textFormat: Text.PlainText
          color: "#e0a458"
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.caption
        }

        // --- settings: who may notify me -------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.settingsOpen

          PanelSeparator { width: parent.width; foreground: root.barForeground; strength: 0.08 }
          PanelSectionHeader { text: "WHO MAY NOTIFY ME"; foreground: root.barForeground }

          Row {
            spacing: Style.space(6)
            Repeater {
              model: [
                { value: "paused", label: "Paused" },
                { value: "all",    label: "Everyone" },
                { value: "custom", label: "Chosen chats" }
              ]
              delegate: Button {
                required property var modelData
                text: modelData.label
                bordered: true
                selected: root.mode === modelData.value
                foreground: root.barForeground
                accent: root.accentColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.setMode(modelData.value)
              }
            }
          }

          MultiSelect {
            id: allowSelect
            width: parent.width
            visible: root.mode === "custom"
            label: ""
            showLabel: false
            // Seeded, not bound: MultiSelect assigns to its own `values` when
            // a row is toggled, which would break a declarative binding on the
            // first click and then silently ignore later reloads.
            Component.onCompleted: allowSelect.values = root.allowList
            Connections {
              target: root
              function onAllowListChanged() {
                if (!allowProc.running) allowSelect.values = root.allowList
              }
            }
            // Populated live from wacli's synced chats, so the picker always
            // reflects the real address book rather than a hard-coded list.
            // Held empty until the host widget has been injected: MultiSelect
            // refreshes on Component.onCompleted, which runs before the Loader
            // that owns this panel hands it a hostWidget. With an empty
            // ctlScript that spawns `["", "recipients"]` and leaves the picker
            // stuck showing an options-command error. Assigning the real
            // command later re-fires onOptionsCommandChanged, so the list still
            // loads on its own.
            optionsCommand: root.ctlScript !== "" ? [root.ctlScript, "recipients"] : []
            placeholderText: "Search contacts and groups…"
            emptyText: "No synced chats yet — let wacli sync run first"
            noSelectionText: "No chats selected — nothing will notify you"
            foreground: root.barForeground
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function (values) { root.saveAllow(values) }
          }

          PanelSectionHeader { text: "VOICE NOTES"; foreground: root.barForeground }

          Text {
            width: parent.width
            text: root.whisperAvailable
              ? "Playback and local transcription are both available."
              : "Playback works. Transcription needs a local speech engine (" + root.whisperDetail + ")."
            color: Util.alpha(root.barForeground, 0.7)
            wrapMode: Text.WordWrap
            font.pixelSize: Style.font.caption
          }

          Button {
            visible: !root.whisperAvailable
            text: "Set up local transcription…"
            bordered: true
            foreground: root.barForeground
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.bodySmall
            // Opens a confirmation, which opens a terminal, which asks again
            // before touching a single package. Nothing installs silently.
            onClicked: root.confirmInstallOpen = true
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground; strength: 0.08 }
        }

        // --- chat list --------------------------------------------------------
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          visible: root.everLoaded && root.errorText === "" && root.chats.length === 0
          text: root.paused ? "Notifications are paused." : "You're all caught up."
          color: Util.alpha(root.barForeground, 0.5)
          font.pixelSize: Style.font.bodySmall
          topPadding: Style.space(10)
          bottomPadding: Style.space(10)
        }

        Flickable {
          id: chatScroll
          width: parent.width
          visible: root.chats.length > 0
          // Bounded so a busy morning cannot grow the panel past the screen;
          // beyond that the list scrolls instead.
          height: Math.min(chatColumn.implicitHeight, Style.space(430))
          contentWidth: width
          contentHeight: chatColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

          Column {
            id: chatColumn
            // Explicit width so every delegate below can safely bind
            // `width: parent.width` without making this Column's own width
            // depend on its children's width.
            width: chatScroll.width
            spacing: Style.space(4)

            Repeater {
              model: root.chats

              delegate: Column {
                id: chatItem
                required property var modelData
                readonly property bool expanded: root.expandedJid === modelData.jid
                width: chatColumn.width
                spacing: Style.space(4)

                Rectangle {
                  width: parent.width
                  height: chatRow.implicitHeight + Style.space(14)
                  radius: Style.space(6)
                  color: chatItem.expanded
                    ? Util.alpha(root.barForeground, 0.08)
                    : (chatHover.hovered ? Util.alpha(root.barForeground, 0.05) : "transparent")

                  HoverHandler { id: chatHover }
                  MouseArea {
                    anchors.fill: parent
                    onClicked: {
                      if (chatItem.expanded) {
                        // Second click on an already-open chat hands off to the
                        // official app. WhatsApp Web has no stable deep link to
                        // a specific conversation (wa.me only starts a *new*
                        // chat, and does nothing at all for groups), so this
                        // lands on the inbox — a documented limitation, not a
                        // bug to work around.
                        root.openWebApp()
                      } else {
                        root.expandedJid = chatItem.modelData.jid
                        root.markSeen(chatItem.modelData.jid, chatItem.modelData.lastTs)
                        var msgs = chatItem.modelData.messages || []
                        for (var i = 0; i < msgs.length; i++) {
                          var m = msgs[i]
                          if (String(m.mediaType) === "image" || String(m.mediaType) === "sticker")
                            root.queueThumb(chatItem.modelData.jid, m.id)
                        }
                      }
                    }
                  }

                  Row {
                    id: chatRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(chatItem.modelData.kind) === "group" ? root.iconGroup : root.iconDm
                      color: Util.alpha(root.barForeground, 0.65)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.icon
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      // Explicit width taken from the row's own geometry, not
                      // from sibling `width` values, so nothing here can form a
                      // width cycle with the enclosing Row.
                      width: chatRow.width - Style.space(8) * 3 - Style.font.icon
                             - countBadge.implicitWidth - timeText.implicitWidth
                      text: String(chatItem.modelData.name)
                      // Contact and group names are chosen by whoever is
                      // messaging you. Text defaults to AutoText, which would
                      // render "<b>Bank</b>" as bold and let an <img> tag pull
                      // in a local file. Every attacker-controlled string in
                      // this panel is pinned to PlainText.
                      textFormat: Text.PlainText
                      color: root.barForeground
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Rectangle {
                      id: countBadge
                      anchors.verticalCenter: parent.verticalCenter
                      implicitWidth: Math.max(badgeText.implicitWidth + Style.space(10), Style.space(20))
                      implicitHeight: badgeText.implicitHeight + Style.space(4)
                      radius: height / 2
                      color: root.accentColor
                      Text {
                        id: badgeText
                        anchors.centerIn: parent
                        text: chatItem.modelData.count > 99 ? "99+" : String(chatItem.modelData.count)
                        color: "#0b1f14"
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                    Text {
                      id: timeText
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.agoText(chatItem.modelData.lastTs)
                      color: Util.alpha(root.barForeground, 0.45)
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                // --- expanded preview ---------------------------------------
                Column {
                  width: parent.width
                  visible: chatItem.expanded
                  spacing: Style.space(8)
                  leftPadding: Style.space(8)
                  rightPadding: Style.space(8)
                  bottomPadding: Style.space(8)

                  Repeater {
                    model: chatItem.expanded ? (chatItem.modelData.messages || []) : []

                    delegate: Column {
                      id: msgItem
                      required property var modelData
                      readonly property string key: root.msgKey(chatItem.modelData.jid, modelData.id)
                      readonly property bool busy: root.busyKey === key
                      readonly property string thumb: {
                        var p = root.mediaPaths[key]
                        return (p !== undefined && p !== "") ? p : ""
                      }
                      readonly property string transcript: {
                        var t = root.transcripts[key]
                        return t === undefined ? "" : t
                      }
                      // Explicit: the enclosing Column has a real width, and
                      // the Texts below bind to *this* width.
                      width: chatColumn.width - Style.space(16)
                      spacing: Style.space(3)

                      Text {
                        width: parent.width
                        visible: String(chatItem.modelData.kind) === "group" && String(msgItem.modelData.sender) !== ""
                        text: String(msgItem.modelData.sender)
                        textFormat: Text.PlainText
                        color: Util.alpha(root.accentColor, 0.9)
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        visible: String(msgItem.modelData.text) !== ""
                        text: String(msgItem.modelData.text)
                        textFormat: Text.PlainText
                        color: root.barForeground
                        wrapMode: Text.WordWrap
                        maximumLineCount: 6
                        elide: Text.ElideRight
                        font.pixelSize: Style.font.bodySmall
                      }

                      // Image / sticker: real thumbnail once the file is local.
                      Image {
                        width: Math.min(implicitWidth, parent.width)
                        visible: msgItem.thumb !== ""
                          && (String(msgItem.modelData.mediaType) === "image"
                              || String(msgItem.modelData.mediaType) === "sticker")
                        source: msgItem.thumb !== "" ? root.fileUrl(msgItem.thumb) : ""
                        fillMode: Image.PreserveAspectFit
                        // Both axes are capped. With only a height cap, Qt
                        // scales the other axis proportionally, so a 200000x20
                        // image still decodes to ~1.5 megapixels wide — a
                        // decompression bomb from anyone who can send a photo.
                        // wa-ctl.sh separately refuses to hand over a file over
                        // its byte ceiling, so the decoder never sees one.
                        sourceSize.width: Style.space(340)
                        sourceSize.height: Style.space(150)
                        asynchronous: true
                        cache: false
                      }

                      // Everything else: a glyph, a label, and the actions that
                      // actually apply to that kind of attachment.
                      Row {
                        width: parent.width
                        spacing: Style.space(6)
                        visible: msgItem.modelData.hasMedia === true

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.mediaGlyph(msgItem.modelData)
                          color: Util.alpha(root.barForeground, 0.7)
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.icon
                        }
                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          // mediaLabel can be a WhatsApp-supplied filename.
                          text: root.mediaLabel(msgItem.modelData)
                          textFormat: Text.PlainText
                          color: Util.alpha(root.barForeground, 0.7)
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                        Button {
                          anchors.verticalCenter: parent.verticalCenter
                          visible: String(msgItem.modelData.mediaType) === "audio"
                                   || String(msgItem.modelData.mediaType) === "video"
                                   || String(msgItem.modelData.mediaType) === "gif"
                          text: msgItem.busy ? "…" : "Play"
                          iconText: root.iconPlay
                          bordered: true
                          foreground: root.barForeground
                          accent: root.accentColor
                          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                          fontSize: Style.font.caption
                          onClicked: root.playVoice(chatItem.modelData.jid, msgItem.modelData.id)
                        }
                        Button {
                          anchors.verticalCenter: parent.verticalCenter
                          // Only offered for voice notes, and only when a local
                          // engine actually exists — an always-visible button
                          // that errors on click is worse than no button.
                          visible: msgItem.modelData.isVoice === true && root.whisperAvailable
                          text: msgItem.busy ? "…" : "Transcribe"
                          bordered: true
                          foreground: root.barForeground
                          accent: root.accentColor
                          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                          fontSize: Style.font.caption
                          onClicked: root.transcribe(chatItem.modelData.jid, msgItem.modelData.id)
                        }
                        Button {
                          anchors.verticalCenter: parent.verticalCenter
                          visible: String(msgItem.modelData.mediaType) === "document"
                                   || String(msgItem.modelData.mediaType) === "image"
                          text: "Open"
                          bordered: true
                          foreground: root.barForeground
                          accent: root.accentColor
                          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                          fontSize: Style.font.caption
                          onClicked: root.openAttachment(chatItem.modelData.jid, msgItem.modelData.id)
                        }
                      }

                      Text {
                        width: parent.width
                        visible: msgItem.transcript !== ""
                        text: "“" + msgItem.transcript + "”"
                        textFormat: Text.PlainText
                        color: Util.alpha(root.barForeground, 0.8)
                        wrapMode: Text.WordWrap
                        font.pixelSize: Style.font.caption
                        font.italic: true
                      }
                    }
                  }

                  // --- quick reply (text only in this version) ---------------
                  Row {
                    id: replyRow
                    width: chatColumn.width - Style.space(16)
                    spacing: Style.space(6)

                    TextField {
                      id: replyText
                      anchors.verticalCenter: parent.verticalCenter
                      width: replyRow.width - sendBtn.implicitWidth - webBtn.implicitWidth
                             - Style.space(6) * 2
                      placeholderText: "Reply…"
                      foreground: root.barForeground
                      accent: root.accentColor
                      enabled: !sendProc.running
                      onAccepted: root.sendReply(chatItem.modelData.jid, replyText.text)

                      Connections {
                        target: root
                        function onReplySent(jid) {
                          if (jid === String(chatItem.modelData.jid)) replyText.text = ""
                        }
                      }
                    }
                    Button {
                      id: sendBtn
                      anchors.verticalCenter: parent.verticalCenter
                      iconText: root.iconSend
                      tooltipText: "Send"
                      bordered: true
                      enabled: !sendProc.running
                      foreground: root.barForeground
                      accent: root.accentColor
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      fontSize: Style.font.icon
                      onClicked: root.sendReply(chatItem.modelData.jid, replyText.text)
                    }
                    Button {
                      id: webBtn
                      anchors.verticalCenter: parent.verticalCenter
                      iconText: root.iconOpen
                      tooltipText: "Open WhatsApp Web (opens the inbox — WhatsApp has no per-chat link)"
                      bordered: true
                      foreground: root.barForeground
                      accent: root.accentColor
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      fontSize: Style.font.icon
                      onClicked: root.openWebApp()
                    }
                  }
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.confirmInstallOpen
        message: "Open a terminal to set up local voice-note transcription?\n\nIt will show exactly which packages and downloads are involved and ask you to confirm again before changing anything. Nothing is installed by this button."
        confirmText: "Open terminal"
        cancelText: "Cancel"
        foreground: root.barForeground
        onCanceled: root.confirmInstallOpen = false
        onConfirmed: {
          root.confirmInstallOpen = false
          root.runAction(["install-whisper"], null)
        }
      }
    }
  }
}

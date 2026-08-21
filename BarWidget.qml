import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.boyoyooo.whatsmarchy"

  // --- settings, read from this widget's shell.json entry -------------------
  readonly property int    interval:      Math.max(5, setting("interval", 20))
  readonly property string widgetLabel:   setting("label", "")
  readonly property string barDetail:     setting("barDetail", "Sender and count")
  readonly property int    previewLimit:  Math.max(1, Math.min(20, setting("previewLimit", 4)))
  readonly property bool   includeChannels: setting("includeChannels", false)
  readonly property string notifyMode:    setting("desktopNotifications", "Sender only")
  readonly property bool   hideWhenEmpty: setting("hideWhenEmpty", false)

  // --- state, consumed by Panel.qml ----------------------------------------
  property bool   everLoaded: false
  property bool   fetching: false
  property string errorText: ""
  property string mode: "all"
  property bool   paused: false
  property bool   syncRunning: false
  property int    totalNew: 0
  property int    chatCount: 0
  property string topSender: ""
  property bool   truncated: false
  property var    chats: []

  readonly property bool healthy: errorText === ""

  readonly property string scriptDir:
    Qt.resolvedUrl("bin/").toString().replace(/^file:\/\//, "")
  readonly property string statusScript: scriptDir + "wa-status.sh"
  readonly property string ctlScript:    scriptDir + "wa-ctl.sh"

  // Nerd Font (Material Design) glyphs. Verified present in the fonts Omarchy
  // ships; a missing one would render as a tofu box rather than fail loudly.
  readonly property string iconWhatsApp: "\u{F05A3}"
  readonly property string iconMuted:    "\u{F009B}"

  readonly property color accentColor: "#25d366"   // WhatsApp green
  readonly property color alertColor:  "#e5534b"
  readonly property color idleColor: root.bar ? root.bar.barForeground : "#cccccc"

  readonly property color stateColor: {
    if (!healthy)         return alertColor
    if (paused)           return Qt.rgba(idleColor.r, idleColor.g, idleColor.b, 0.55)
    if (totalNew > 0)     return accentColor
    return idleColor
  }

  // Bar text never includes message content — only who is waiting and how
  // many. That is the whole point of the "how much is shown" spectrum: the
  // always-visible surface leaks nothing a passer-by could read.
  // topSender is a contact or group name — chosen by whoever is messaging you.
  // It reaches a Text and a tooltip, both of which default to auto-detecting
  // rich text, so markup characters and line breaks are stripped at the source
  // rather than at each of the several places the name is rendered.
  function plain(s) {
    return String(s).replace(/[<>&]/g, " ").replace(/[\r\n\t]+/g, " ")
  }
  readonly property string safeSender: root.plain(root.topSender)

  // A capped scan yields a floor, so the count is always shown with a "+"
  // rather than as an exact figure it cannot stand behind.
  readonly property string countText:
    (totalNew > 99 || root.truncated) ? (totalNew > 99 ? "99+" : String(totalNew) + "+")
                                      : String(totalNew)
  readonly property string barText: {
    if (!everLoaded) return ""
    if (!healthy)    return "!"
    if (paused)      return ""
    if (totalNew === 0) return ""
    if (barDetail === "Icon only")  return ""
    if (barDetail === "Count only") return countText
    // "Sender and count": one chat names it, several just say how many.
    if (chatCount === 1) return root.safeSender + " " + countText
    return chatCount + " chats · " + countText
  }

  // "Hide when empty" is expressed by handing WidgetButton an empty `text`
  // rather than by overriding this widget's own `visible`: the base component
  // already derives hasVisualContent (and its visibility) from `text`, and the
  // bar's layout is built around that, not around a widget disappearing from
  // under it.
  readonly property bool shouldHide:
    root.hideWhenEmpty && root.everLoaded && root.healthy && !root.paused && root.totalNew === 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.settings = root.settings
  }

  // --- panel plumbing (same contract as the built-in clock) -----------------
  readonly property bool opened:
    panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing:
    panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open()   { if (panelLoader.item) panelLoader.item.open() }
  function close()  { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // --- polling --------------------------------------------------------------
  function applyPayload(text) {
    root.everLoaded = true
    var payload
    try {
      payload = JSON.parse(text)
    } catch (e) {
      root.errorText = "invalid response from the wacli poller"
      return
    }
    if (!payload || payload.ok !== true) {
      // A failed poll must never be rendered as "nothing new". The counts are
      // deliberately left untouched and the bar switches to its fault marker,
      // so a broken store can't look like a quiet inbox.
      root.errorText = String((payload && payload.error) || "poller failed")
      return
    }
    root.errorText = ""
    root.mode        = String(payload.mode || "all")
    root.paused      = payload.paused === true
    root.syncRunning = payload.syncRunning === true
    root.truncated   = payload.truncated === true
    root.chatCount   = typeof payload.chatCount === "number" ? payload.chatCount : 0
    root.topSender   = String(payload.topSender || "")
    root.chats       = Array.isArray(payload.chats) ? payload.chats : []

    var incoming = typeof payload.totalNew === "number" ? payload.totalNew : 0
    var previous = root.totalNew
    root.totalNew = incoming
    if (root.everNotified && incoming > previous && !root.paused) notifier.announce()
    root.everNotified = true
  }

  property bool everNotified: false

  function refresh() {
    if (fetcher.running) return
    fetcher.running = true
  }

  onOpenedChanged: if (root.opened) root.refresh()

  Process {
    id: fetcher
    running: false
    command: [root.statusScript, String(root.previewLimit), root.includeChannels ? "1" : "0"]
    onRunningChanged: root.fetching = fetcher.running
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(this.text)
    }
  }

  Timer {
    // Floored at 5s so a hand-edited shell.json can't spin the poller. This
    // only reads a local SQLite file, so a short interval is cheap — but not
    // free, and there is no reason to beat on it.
    interval: Math.max(5, root.interval) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // --- desktop notification --------------------------------------------------
  // Opt-in, and content-free unless the user explicitly chose otherwise. The
  // body is passed after `--` so a message starting with "-" is data, not a
  // notify-send flag.
  Process {
    id: notifier
    running: false
    // Contact names and message bodies are attacker-controlled text. Most
    // notification daemons render Pango markup in the summary and body, so
    // angle brackets and ampersands are neutralised before they get there — a
    // contact named "<b>Bank</b>" must not be able to style its own popup.
    function sanitize(s) {
      return String(s).replace(/[<>&]/g, " ").replace(/[\r\n\t]+/g, " ")
    }

    function announce() {
      if (root.notifyMode === "Off") return
      if (!root.chats || root.chats.length === 0) return
      var chat = root.chats[0]
      var title = notifier.sanitize(chat.name || "WhatsApp")
      var body = chat.count + (chat.count === 1 ? " new message" : " new messages")
      if (root.notifyMode === "Sender and preview") {
        var msgs = chat.messages || []
        var last = msgs.length > 0 ? msgs[msgs.length - 1] : null
        if (last) {
          var preview = String(last.text || "")
          if (!preview && last.hasMedia) preview = "[" + String(last.mediaType) + "]"
          if (preview) {
            preview = notifier.sanitize(preview)
            body = preview.length > 120 ? preview.slice(0, 117) + "…" : preview
          }
        }
      }
      notifier.command = ["notify-send", "-a", "Whatsmarchy", "-u", "normal", "--", title, body]
      notifier.running = true
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    // WidgetButton derives hasVisualContent (and therefore its own visibility)
    // from `text`, independently of labelVisible. A custom-rendered widget
    // that leaves `text` empty silently never appears in the bar, so this is
    // set even though the Row below is what actually gets drawn.
    text: root.shouldHide ? "" : (root.barText !== "" ? root.barText : root.iconWhatsApp)
    // Omarchy's PanelToolTip sets no textFormat, so its Text defaults to
    // AutoText. errorText carries wacli / sqlite3 output verbatim, which can
    // include a WhatsApp-supplied filename, so the whole string is put through
    // the same markup strip the bar label uses.
    tooltipText: {
      if (!root.everLoaded) return "WhatsApp: loading…"
      if (!root.healthy)    return "WhatsApp: " + root.plain(root.errorText)
      var lbl = root.widgetLabel ? root.plain(root.widgetLabel) + " — " : ""
      if (root.paused)   return lbl + "WhatsApp notifications paused"
      if (!root.syncRunning) return lbl + "wacli sync is not running — counts are stale"
      if (root.totalNew === 0) return lbl + "No new WhatsApp messages"
      return lbl + root.totalNew + (root.truncated ? "+" : "") + " new in " + root.chatCount
        + (root.chatCount === 1 ? " chat" : " chats")
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton)        root.toggle()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
    }

    implicitWidth: fixedWidth > 0 ? fixedWidth
      : (vertical ? barSize : Math.max(12, content.implicitWidth + scaledHorizontalMargin * 2))
    implicitHeight: fixedHeight > 0 ? fixedHeight
      : (vertical ? Math.max(12, content.implicitHeight + scaledVerticalPadding * 2) : barSize)

    Row {
      id: content
      anchors.centerIn: parent
      spacing: 4
      visible: !root.shouldHide

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.paused ? root.iconMuted : root.iconWhatsApp
        textFormat: Text.PlainText
        color: root.stateColor
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.barText !== ""
        text: root.barText
        textFormat: Text.PlainText
        color: root.stateColor
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        font.bold: root.totalNew > 0
        renderType: Text.NativeRendering
      }

      // A short pulse when the count goes up, so a new message registers
      // peripherally without a popup stealing focus.
      SequentialAnimation {
        id: pulse
        loops: 2
        NumberAnimation { target: content; property: "opacity"; to: 0.25; duration: 160; easing.type: Easing.InOutQuad }
        NumberAnimation { target: content; property: "opacity"; to: 1.0;  duration: 160; easing.type: Easing.InOutQuad }
      }
      Connections {
        target: root
        function onTotalNewChanged() {
          if (root.everNotified && root.totalNew > 0) pulse.restart()
        }
      }
    }
  }
}

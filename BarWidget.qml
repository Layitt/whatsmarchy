import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "layitt.whatsmarchy"

  // --- settings, read from this widget's shell.json entry -------------------
  readonly property int    interval:      Math.max(5, setting("interval", 20))
  readonly property string widgetLabel:   setting("label", "")
  readonly property string barDetail:     setting("barDetail", "Sender and count")
  readonly property int    previewLimit:  Math.max(1, Math.min(20, setting("previewLimit", 4)))
  readonly property bool   includeChannels: setting("includeChannels", false)
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

  readonly property color accentColor: Color.accent
  readonly property color alertColor:  Color.urgent
  readonly property color idleColor:   Color.foreground

  readonly property color stateColor: {
    if (!healthy)         return alertColor
    if (paused)           return Util.alpha(idleColor, 0.45)
    if (totalNew > 0)     return accentColor
    return idleColor
  }

  // Bar text includes message content only under the opt-in "Message preview"
  // barDetail setting; every other setting shows just who is waiting and how
  // many, so the always-visible surface leaks nothing by default.
  // topSender is a contact or group name — chosen by whoever is messaging you.
  // It reaches a Text and a tooltip, both of which default to auto-detecting
  // rich text, so markup characters and line breaks are stripped at the source
  // rather than at each of the several places the name is rendered.
  function plain(s) {
    return String(s).replace(/[<>&]/g, " ").replace(/[\r\n\t]+/g, " ")
  }
  readonly property string safeSender: root.plain(root.topSender)

  // Only reached when the user explicitly opts into "Message preview" —
  // every other barDetail setting never calls this. Same truncation/plain()
  // treatment as the sender name: attacker-controlled text, markup stripped.
  readonly property string topPreview: {
    if (root.chats.length === 0) return ""
    var msgs = root.chats[0].messages || []
    var last = msgs.length > 0 ? msgs[msgs.length - 1] : null
    if (!last) return ""
    var text = String(last.text || "")
    if (!text && last.hasMedia) text = "[" + String(last.mediaType) + "]"
    text = root.plain(text)
    return text.length > 40 ? text.slice(0, 37) + "…" : text
  }

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
    if (barDetail === "Message preview (nothing to hide)") {
      if (chatCount === 1 && root.topPreview !== "") return root.safeSender + ": " + root.topPreview
      if (chatCount === 1) return root.safeSender + " " + countText
      return chatCount + " chats · " + countText
    }
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

    root.totalNew = typeof payload.totalNew === "number" ? payload.totalNew : 0
    root.everNotified = true
  }

  property bool everNotified: false

  function refresh() {
    if (fetcher.running) fetcher.running = false
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

  // refresh() no-ops while fetcher.running is true — one poll at a time. A
  // poll that never comes back (wa-status.sh itself is timeout-guarded, but
  // this covers anything else that could wedge the process) would otherwise
  // silently and permanently disable every future refresh, including a
  // manual click on the refresh button, until the shell was reloaded.
  Timer {
    running: fetcher.running
    interval: 12000
    onTriggered: {
      if (fetcher.running) {
        fetcher.running = false
        root.errorText = "poller did not respond in time — try refresh again"
      }
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
  // Removed: notify-send popups were firing twice for a single message with
  // no code-level cause found (ruled out: duplicate widget instance,
  // duplicate shell process, a dedup guard keyed on jid+count). Rather than
  // keep chasing what looks like a system/notification-daemon issue outside
  // this plugin, new messages are signalled by the bar flash below only —
  // it never leaves this widget's own rendering, so it can't double-fire the
  // same way.

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

    DropArea {
      id: barDropArea
      anchors.fill: parent
      onEntered: function (drag) {
        drag.acceptProposedAction()
        root.open()
      }
      onDropped: function (drop) {
        var filePath = Model.getFilePathFromDrop(drop)
        if (filePath && panelLoader.item) {
          root.open()
          panelLoader.item.attachDroppedFile(filePath)
        }
        drop.acceptProposedAction()
      }
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: 4
      visible: !root.shouldHide
      scale: barDropArea.containsDrag ? 1.15 : 1.0
      Behavior on scale { NumberAnimation { duration: 150 } }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.paused ? root.iconMuted : root.iconWhatsApp
        textFormat: Text.PlainText
        color: root.stateColor
        font.family: button.fontFamily
        // Matches the size omARR uses for its Sonarr/Radarr logos
        // (Style.space(16)), rather than inheriting the bar's body text size.
        font.pixelSize: Style.space(16)
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
        loops: 4
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

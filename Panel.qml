import QtQuick
import QtQuick.Effects
import QtQuick.Controls as QQC
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "layitt.whatsmarchy"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  AudioOutput { id: voiceAudioOut }
  MediaPlayer {
    id: voicePlayer
    audioOutput: voiceAudioOut
    property string activeKey: ""
  }

  // --- navigation & conversation state --------------------------------------
  property string view: "chats" // "chats" | "chat"
  property string activeJid: ""
  property var    activeChat: null
  property var    messages: []
  property int    cursorIndex: 0
  property bool   pinToLatest: true

  // --- in-chat search & reply state -----------------------------------------
  property bool   chatSearchOpen: false
  property string chatSearchQuery: ""
  property var    replyingTo: null

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
  readonly property color  accentColor: hostWidget ? hostWidget.accentColor : Color.accent
  readonly property color  alertColor:  hostWidget ? hostWidget.alertColor : Color.urgent
  readonly property color  contentForeground: Color.popups.text

  readonly property string iconBack:     "\u{F004D}"
  readonly property string iconDm:       "\u{F0361}"
  readonly property string iconGroup:    "\u{F0B79}"
  readonly property string iconPlay:     "\u{F040A}"
  readonly property string iconPause:    "\u{F03E4}"
  readonly property string iconImage:    "\u{F02E9}"
  readonly property string iconDoc:      "\u{F0219}"
  readonly property string iconMic:      "\u{F036C}"
  readonly property string iconSend:     "\u{F048A}"
  readonly property string iconOpen:     "\u{F03CC}"
  readonly property string iconSettings: "\u{F0493}"
  readonly property string iconMarkRead: "\u{F012C}"
  readonly property string iconRefresh:  "\u{F0450}"
  readonly property string iconWhatsApp: "\u{F05A3}"
  readonly property string iconSearch:   "\u{F0349}"
  readonly property string iconAttach:   "\u{F018F}"
  readonly property string iconReply:    "\u{F045A}"

  // --- panel-local UI state -------------------------------------------------
  property bool   settingsOpen: false
  property string actionError: ""

  // --- all chats & search state ---------------------------------------------
  property string currentTab: "unread" // "unread" | "all"
  property string searchQuery: ""
  property var    allChatsList: []
  property bool   fetchingAllChats: false
  property var    chatHistoryMap: ({})
  property string loadingHistoryJid: ""

  // --- file attachment state ------------------------------------------------
  property var    selectedFile: null
  property string fileCaption: ""

  readonly property var activeModel: {
    if (root.currentTab === "unread") return root.chats
    return root.allChatsList
  }

  function fetchAllChats() {
    if (allChatsProc.running) return
    allChatsProc.command = [root.ctlScript, "all-chats", "60", root.searchQuery]
    allChatsProc.running = true
  }

  function loadChatMessages(jid, query) {
    if (!jid) return
    root.loadingHistoryJid = jid
    messagesProc.jid = jid
    messagesProc.command = [root.ctlScript, "chat-messages", jid, "50", query || ""]
    if (!messagesProc.running) messagesProc.running = true
  }

  function selectChat(chat) {
    if (!chat) return
    var jid = String(chat.jid || "")
    if (!jid) return
    root.activeJid = jid
    root.activeChat = chat
    root.view = "chat"
    root.pinToLatest = true
    root.chatSearchOpen = false
    root.chatSearchQuery = ""
    root.replyingTo = null
    root.queueAvatar(jid)
    var cached = root.chatHistoryMap[jid]
    if (cached && cached.length > 0) {
      root.messages = cached
    } else if (chat.messages && chat.messages.length > 0) {
      root.messages = chat.messages
    } else {
      root.messages = []
    }
    root.loadChatMessages(jid)
    Qt.callLater(function () {
      if (root.selectedFile !== null && typeof captionInput !== "undefined" && captionInput) {
        captionInput.forceActiveFocus()
      } else if (typeof composer !== "undefined" && composer) {
        composer.forceActiveFocus()
      }
    })
  }

  function back() {
    root.cancelVoice()
    root.view = "chats"
    root.activeJid = ""
    root.activeChat = null
    root.messages = []
    root.chatSearchOpen = false
    root.chatSearchQuery = ""
    root.replyingTo = null
    if (root.currentTab === "all") root.fetchAllChats()
    else if (root.hostWidget) root.hostWidget.refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function attachDroppedFile(filePath) {
    if (!filePath) return
    root.open()
    pickFileProc.command = [root.ctlScript, "pick-file", filePath]
    pickFileProc.running = true
  }

  // Keyed by "<jid>|<msgId>"
  property var    mediaPaths: ({})
  property string busyKey: ""
  property int    markReadPending: 0
  readonly property bool markReadBusy: root.markReadPending > 0

  onMarkReadPendingChanged: {
    if (root.markReadPending > 0) markReadSafetyTimer.restart()
    else markReadSafetyTimer.stop()
  }

  Timer {
    id: markReadSafetyTimer
    interval: 2000
    repeat: false
    onTriggered: { root.markReadPending = 0 }
  }

  // --- voice reply state ----------------------------------------------------
  property bool   voiceAvailable: false
  property string voiceDetail: ""
  property int    voiceMaxSeconds: 120
  property string voiceState: "idle" // idle -> recording -> preview -> sending
  property string voiceJid: ""
  property string voiceName: ""
  property string voiceToken: ""
  property int    voiceSeconds: 0
  property string voiceLevel: "ok"
  property bool   voiceDiscardOnStop: false
  property bool   voiceAbandonOnSend: false

  function msgKey(jid, id) { return String(jid) + "|" + String(id) }

  function fileUrl(path) {
    return "file://" + encodeURI(String(path)).replace(/#/g, "%23").replace(/\?/g, "%3F")
  }

  function withEntry(obj, key, value) {
    var next = ({})
    for (var k in obj) next[k] = obj[k]
    next[key] = value
    return next
  }

  function formatBytes(bytes) {
    if (!bytes || bytes <= 0) return "0 B"
    var k = 1024
    var sizes = ["B", "KB", "MB", "GB"]
    var i = Math.floor(Math.log(bytes) / Math.log(k))
    return (bytes / Math.pow(k, i)).toFixed(1) + " " + sizes[i]
  }

  function fileGlyph(mime) {
    var m = String(mime || "").toLowerCase()
    if (m.indexOf("image") >= 0) return root.iconImage
    if (m.indexOf("video") >= 0) return root.iconPlay
    if (m.indexOf("audio") >= 0) return root.iconMic
    return root.iconDoc
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
      voiceStatusProc.probe()
      if (root.view === "chat" && root.activeJid) {
        root.loadChatMessages(root.activeJid, root.chatSearchQuery)
      } else if (root.currentTab === "all") {
        root.fetchAllChats()
      }
    } else {
      root.cancelVoice()
      root.settingsOpen = false
    }
  }

  onActiveJidChanged: {
    if (root.voiceState !== "idle" && root.voiceJid !== root.activeJid) root.cancelVoice()
  }

  property int nowTick: 0
  Timer { interval: 20000; running: root.opened; repeat: true; onTriggered: root.nowTick++ }

  function mmss(secs) {
    var s = Math.max(0, Math.round(secs))
    var r = s % 60
    return Math.floor(s / 60) + ":" + (r < 10 ? "0" : "") + r
  }

  function mediaGlyph(m) {
    if (!m) return ""
    if (m.isVoice || String(m.mediaType) === "audio") return root.iconMic
    switch (String(m.mediaType)) {
      case "image": case "sticker": return root.iconImage
      case "video": case "gif":     return root.iconPlay
      case "document":              return root.iconDoc
      default:                      return root.iconDoc
    }
  }

  function mediaLabel(m) {
    if (!m) return ""
    if (m.filename && String(m.filename) !== "" && !m.isVoice) return String(m.filename)
    if (m.isVoice || String(m.mediaType) === "audio") return "Nota de voz"
    switch (String(m.mediaType)) {
      case "image":    return "Foto"
      case "sticker":  return "Sticker"
      case "video":    return "Video"
      case "gif":      return "GIF"
      case "document": return "Documento"
      default:         return "Archivo adjunto"
    }
  }

  // --- action runner --------------------------------------------------------
  property var actionQueue: []

  function runAction(args, onDone) {
    var q = root.actionQueue.slice()
    q.push({ args: args, onDone: onDone || null })
    root.actionQueue = q
    pumpAction()
  }

  function pumpAction() {
    if (actionProc.running) return
    if (root.actionQueue.length === 0) return
    var q = root.actionQueue.slice()
    var job = q.shift()
    root.actionQueue = q
    actionProc.job = job
    actionProc.command = [root.ctlScript].concat(job.args)
    actionProc.running = true
  }

  Process {
    id: actionProc
    property var job: null
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true)
          root.actionError = String((payload && payload.error) || "action failed")
        if (actionProc.job && typeof actionProc.job.onDone === "function") {
          try { actionProc.job.onDone(payload) } catch (e) {}
        }
        actionProc.job = null
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.pumpAction)
  }

  Process {
    id: configProc
    running: false
    function reload() {
      if (!configProc.running && root.ctlScript !== "") {
        configProc.command = [root.ctlScript, "config-get"]
        configProc.running = true
      }
    }
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var p = JSON.parse(this.text)
          if (p && p.ok === true && Array.isArray(p.allow)) root.allowList = p.allow
        } catch (e) {}
      }
    }
  }

  signal replySent(string jid)

  property var sendQueue: []

  function pumpSend() {
    if (sendProc.running) return
    if (root.sendQueue.length === 0) return
    var q = root.sendQueue.slice()
    var job = q.shift()
    root.sendQueue = q
    root.busyKey = "send"
    sendProc.currentJob = job
    var cmd = [root.ctlScript, "send", job.jid]
    if (job.replyId) {
      cmd.push(job.replyId)
      if (job.replySender) cmd.push(job.replySender)
    }
    sendProc.command = cmd
    sendProc.stdinEnabled = true
    sendProc.running = true
  }

  Process {
    id: sendProc
    running: false
    stdinEnabled: false
    property var currentJob: null
    onStarted: {
      if (sendProc.currentJob && sendProc.currentJob.body) {
        write(sendProc.currentJob.body + "\n")
      }
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        root.busyKey = ""
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        var jobJid = sendProc.currentJob ? sendProc.currentJob.jid : root.activeJid
        var tempId = sendProc.currentJob ? sendProc.currentJob.tempId : ""
        sendProc.currentJob = null
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "send failed")
          if (tempId) {
            var markFailed = function(list) {
              var res = []
              for (var i = 0; i < (list || []).length; i++) {
                var m = list[i]
                if (m && m.id === tempId) res.push(Object.assign({}, m, { isFailed: true }))
                else res.push(m)
              }
              return res
            }
            if (root.activeJid === jobJid) root.messages = markFailed(root.messages)
            if (root.chatHistoryMap[jobJid]) {
              root.chatHistoryMap = root.withEntry(root.chatHistoryMap, jobJid, markFailed(root.chatHistoryMap[jobJid]))
            }
          }
        } else {
          root.actionError = ""
          if (tempId && payload.id) {
            var realId = String(payload.id)
            var updateMsgId = function(list) {
              var res = []
              for (var i = 0; i < (list || []).length; i++) {
                var m = list[i]
                if (m && m.id === tempId) res.push(Object.assign({}, m, { id: realId }))
                else res.push(m)
              }
              return res
            }
            if (root.activeJid === jobJid) root.messages = updateMsgId(root.messages)
            if (root.chatHistoryMap[jobJid]) {
              root.chatHistoryMap = root.withEntry(root.chatHistoryMap, jobJid, updateMsgId(root.chatHistoryMap[jobJid]))
            }
          }
          root.replySent(jobJid)
          root.autoMarkSeenAfterSend(jobJid)
          root.loadChatMessages(jobJid, root.chatSearchQuery)
          root.scheduleChatReload(jobJid)
        }
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.pumpSend)
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
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "could not update allowed senders")
          configProc.reload()
          return
        }
        root.actionError = ""
        if (root.hostWidget) root.hostWidget.refresh()
      }
    }
  }

  // --- file picker & sending processes --------------------------------------
  Process {
    id: pickFileProc
    running: false
    command: [root.ctlScript, "pick-file"]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (payload && payload.ok === true && payload.path && String(payload.path).trim() !== "") {
          root.selectedFile = {
            path: String(payload.path),
            name: String(payload.name || payload.path.split("/").pop()),
            size: Number(payload.size || 0),
            mime: String(payload.mime || "")
          }
          root.fileCaption = ""
          Qt.callLater(function () {
            if (typeof captionInput !== "undefined" && captionInput) captionInput.forceActiveFocus()
          })
        }
      }
    }
  }

  function pickFile() {
    if (pickFileProc.running) return
    pickFileProc.command = [root.ctlScript, "pick-file"]
    pickFileProc.running = true
  }

  Process {
    id: fileSendProc
    property string targetJid: ""
    property string tempId: ""
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        var targetJid = fileSendProc.targetJid || root.activeJid
        var tempId = fileSendProc.tempId
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "error al enviar archivo")
          if (tempId) {
            var markFailed = function(list) {
              var res = []
              for (var i = 0; i < (list || []).length; i++) {
                var m = list[i]
                if (m && m.id === tempId) res.push(Object.assign({}, m, { isFailed: true }))
                else res.push(m)
              }
              return res
            }
            if (root.activeJid === targetJid) root.messages = markFailed(root.messages)
            if (root.chatHistoryMap[targetJid]) {
              root.chatHistoryMap = root.withEntry(root.chatHistoryMap, targetJid, markFailed(root.chatHistoryMap[targetJid]))
            }
          }
          return
        }
        root.actionError = ""
        if (tempId && payload.id) {
          var realId = String(payload.id)
          var updateMsgId = function(list) {
            var res = []
            for (var i = 0; i < (list || []).length; i++) {
              var m = list[i]
              if (m && m.id === tempId) res.push(Object.assign({}, m, { id: realId }))
              else res.push(m)
            }
            return res
          }
          if (root.activeJid === targetJid) root.messages = updateMsgId(root.messages)
          if (root.chatHistoryMap[targetJid]) {
            root.chatHistoryMap = root.withEntry(root.chatHistoryMap, targetJid, updateMsgId(root.chatHistoryMap[targetJid]))
          }
        }
        root.selectedFile = null
        root.fileCaption = ""
        if (targetJid) {
          root.autoMarkSeenAfterSend(targetJid)
          root.loadChatMessages(targetJid, root.chatSearchQuery)
          root.scheduleChatReload(targetJid)
        }
      }
    }
  }

  property int reloadChatRetries: 0
  property string reloadChatJid: ""

  function scheduleChatReload(jid) {
    var target = String(jid || root.activeJid || "")
    if (!target) return
    root.reloadChatJid = target
    root.reloadChatRetries = 4
    reloadChatTimer.interval = 1000
    reloadChatTimer.restart()
  }

  Timer {
    id: reloadChatTimer
    interval: 1000
    repeat: false
    onTriggered: {
      var target = root.reloadChatJid || root.activeJid
      if (target) {
        root.loadChatMessages(target, root.chatSearchQuery)
        if (root.reloadChatRetries > 0) {
          root.reloadChatRetries--
          reloadChatTimer.interval = 1800
          reloadChatTimer.restart()
        }
      }
    }
  }

  function updateChatListSnippet(jid, snippetText, senderName, timestamp) {
    if (!jid) return
    var ts = timestamp || Math.floor(Date.now() / 1000)
    var snd = senderName || "me"
    var snip = snippetText || ""

    var updateList = function(list) {
      if (!Array.isArray(list)) return []
      var updated = []
      var found = null
      for (var i = 0; i < list.length; i++) {
        var item = list[i]
        if (item && item.jid === jid) {
          found = Object.assign({}, item, {
            snippet: snip,
            lastSender: snd,
            lastTs: ts,
            unread: 0,
            count: 0
          })
        } else {
          updated.push(item)
        }
      }
      if (found) updated.unshift(found)
      return updated
    }

    root.allChatsList = updateList(root.allChatsList)
    if (root.hostWidget && Array.isArray(root.hostWidget.chats)) {
      root.hostWidget.chats = updateList(root.hostWidget.chats)
    }
  }

  function sendFile() {
    if (!root.selectedFile || !root.selectedFile.path || fileSendProc.running) return
    if (!root.activeJid) return
    root.actionError = ""

    var tempFileMsg = {
      id: "temp_file_" + Date.now(),
      chatJid: root.activeJid,
      ts: Math.round(Date.now() / 1000),
      fromMe: true,
      sender: "Tú",
      senderJid: "",
      text: root.fileCaption || "",
      mediaType: "document",
      mime: root.selectedFile.mime || "application/octet-stream",
      filename: root.selectedFile.name || "Archivo",
      localPath: root.selectedFile.path,
      hasMedia: true,
      isVoice: false,
      quotedId: "",
      quotedSender: "",
      quotedText: "",
      quotedMediaType: "",
      reactions: []
    }
    var updated = root.messages.concat([tempFileMsg])
    root.messages = updated
    root.chatHistoryMap = root.withEntry(root.chatHistoryMap, root.activeJid, updated)
    var fileLabel = root.fileCaption ? root.fileCaption : (root.selectedFile.name || "[Documento]")
    root.updateChatListSnippet(root.activeJid, fileLabel, "me", tempFileMsg.ts)
    Qt.callLater(function () { if (messageList) messageList.positionViewAtEnd() })

    fileSendProc.targetJid = root.activeJid
    fileSendProc.tempId = tempFileMsg.id
    fileSendProc.command = [root.ctlScript, "send-file", root.activeJid, root.selectedFile.path, root.fileCaption]
    fileSendProc.running = true
  }

  // --- presence & reaction helpers ------------------------------------------
  Process {
    id: presenceProc
    running: false
  }

  function sendPresence(jid, state, media) {
    if (!jid) return
    presenceProc.command = [root.ctlScript, "presence", String(jid), String(state || "typing"), String(media || "")]
    if (!presenceProc.running) presenceProc.running = true
  }

  Timer {
    id: typingTimer
    interval: 3500
    repeat: false
    onTriggered: {
      if (root.activeJid) root.sendPresence(root.activeJid, "paused")
    }
  }

  function sendReaction(jid, msgId, emoji, senderJid) {
    if (!jid || !msgId) return
    runAction(["react", String(jid), String(msgId), String(emoji), String(senderJid || "")], function () {
      if (root.activeJid) root.loadChatMessages(root.activeJid, root.chatSearchQuery)
    })
  }

  function setMode(newMode) {
    if (newMode !== "paused" && newMode !== "all" && newMode !== "custom") return
    runAction(["set-mode", newMode], function (p) {
      if (p && p.ok === true && root.hostWidget) root.hostWidget.refresh()
    })
  }

  function saveAllow(jids) {
    if (allowProc.running) return
    var list = []
    for (var i = 0; i < (jids || []).length; i++) {
      var j = String(jids[i]).trim()
      if (j !== "") list.push(j)
    }
    root.allowList = list
    allowProc.body = JSON.stringify(list)
    allowProc.command = [root.ctlScript, "set-allow"]
    allowProc.stdinEnabled = true
    allowProc.running = true
  }

  function setBarDetail(newDetail) {
    if (!root.hostWidget) return
    root.hostWidget.setSetting("barDetail", newDetail)
  }

  function markSeen(jid, ts, onDone) {
    if (!jid) {
      if (typeof onDone === "function") onDone()
      return
    }
    root.markReadPending++
    var done = function () {
      root.markReadPending = Math.max(0, root.markReadPending - 1)
      if (typeof onDone === "function") onDone()
    }

    // 1. Optimistic UI: Update hostWidget.chats and totalNew immediately
    if (root.hostWidget) {
      var nextChats = []
      var clearedCount = 0
      for (var i = 0; i < (root.hostWidget.chats || []).length; i++) {
        var c = root.hostWidget.chats[i]
        if (c && c.jid === jid) {
          clearedCount = Number(c.count || c.unread || 0)
        } else if (c) {
          nextChats.push(c)
        }
      }
      root.hostWidget.chats = nextChats
      root.hostWidget.totalNew = Math.max(0, (root.hostWidget.totalNew || 0) - clearedCount)
      root.hostWidget.chatCount = nextChats.length
      if (nextChats.length === 0) root.hostWidget.topSender = ""
    }

    // 2. Optimistic UI: Update allChatsList immediately
    var nextAll = []
    for (var a = 0; a < (root.allChatsList || []).length; a++) {
      var item = root.allChatsList[a]
      if (item && item.jid === jid) {
        nextAll.push(Object.assign({}, item, { unread: 0, count: 0 }))
      } else if (item) {
        nextAll.push(item)
      }
    }
    root.allChatsList = nextAll

    var effectiveTs = ts
    if (!effectiveTs && root.activeChat && root.activeChat.jid === jid) {
      effectiveTs = root.activeChat.lastTs
    }
    if (!effectiveTs && root.messages && root.messages.length > 0) {
      effectiveTs = root.messages[root.messages.length - 1].ts
    }
    if (!effectiveTs) {
      for (var k = 0; k < root.chats.length; k++) {
        if (root.chats[k].jid === jid) { effectiveTs = root.chats[k].lastTs; break }
      }
    }
    if (!effectiveTs) effectiveTs = Math.round(Date.now() / 1000)

    runAction(["mark-seen", String(jid), String(effectiveTs), "0"], function (p) {
      if (p && p.ok === true && root.hostWidget) root.hostWidget.refresh()
      done()
    })
  }

  function autoMarkSeenAfterSend(jid) {
    if (!jid) return
    if (root.hostWidget) {
      var nextChats = []
      var clearedCount = 0
      for (var i = 0; i < (root.hostWidget.chats || []).length; i++) {
        var c = root.hostWidget.chats[i]
        if (c && c.jid === jid) {
          clearedCount = Number(c.count || c.unread || 0)
        } else if (c) {
          nextChats.push(c)
        }
      }
      root.hostWidget.chats = nextChats
      root.hostWidget.totalNew = Math.max(0, (root.hostWidget.totalNew || 0) - clearedCount)
      root.hostWidget.chatCount = nextChats.length
    }
    var nextAll = []
    for (var a = 0; a < (root.allChatsList || []).length; a++) {
      var item = root.allChatsList[a]
      if (item && item.jid === jid) {
        nextAll.push(Object.assign({}, item, { unread: 0, count: 0 }))
      } else if (item) {
        nextAll.push(item)
      }
    }
    root.allChatsList = nextAll

    var ts = Math.round(Date.now() / 1000)
    runAction(["mark-seen", String(jid), String(ts), "0"], function (p) {
      if (p && p.ok === true && root.hostWidget) root.hostWidget.refresh()
    })
  }

  function markAllSeen() {
    root.markReadPending++
    // 1. Optimistic UI: Clear hostWidget immediately
    if (root.hostWidget) {
      root.hostWidget.chats = []
      root.hostWidget.totalNew = 0
      root.hostWidget.chatCount = 0
      root.hostWidget.topSender = ""
    }
    // 2. Optimistic UI: Clear allChatsList badges
    var nextAll = []
    for (var a = 0; a < (root.allChatsList || []).length; a++) {
      var item = root.allChatsList[a]
      if (item) nextAll.push(Object.assign({}, item, { unread: 0, count: 0 }))
    }
    root.allChatsList = nextAll

    runAction(["mark-all-seen"], function (p) {
      root.markReadPending = Math.max(0, root.markReadPending - 1)
      if (p && p.ok === true && root.hostWidget) root.hostWidget.refresh()
    })
  }

  function openWebApp() { runAction(["webapp"], null) }

  function sendReply(jid, text, replyId, replySender, tempId) {
    var body = String(text || "").trim()
    if (body === "" || !jid) return
    var q = root.sendQueue.slice()
    q.push({
      jid: String(jid),
      body: body,
      replyId: replyId ? String(replyId) : "",
      replySender: replySender ? String(replySender) : "",
      tempId: String(tempId || "")
    })
    root.sendQueue = q
    pumpSend()
  }

  function sendReplyText() {
    if (!composer) return
    var text = String(composer.text || "").trim()
    if (!text || !root.activeJid) return
    if (typingTimer.running) typingTimer.stop()
    root.sendPresence(root.activeJid, "paused")
    var rId = root.replyingTo ? root.replyingTo.id : ""
    var rSender = root.replyingTo ? root.replyingTo.senderJid : ""
    var rQuoted = root.replyingTo

    var tempId = "temp_" + Date.now()
    var tempMsg = {
      id: tempId,
      chatJid: root.activeJid,
      ts: Math.round(Date.now() / 1000),
      fromMe: true,
      sender: "Tú",
      senderJid: "",
      text: text,
      mediaType: "",
      mime: "",
      filename: "",
      localPath: "",
      hasMedia: false,
      isVoice: false,
      quotedId: rId || "",
      quotedSender: rQuoted ? rQuoted.sender : "",
      quotedText: rQuoted ? rQuoted.text : "",
      quotedMediaType: "",
      reactions: []
    }
    var updated = root.messages.concat([tempMsg])
    root.messages = updated
    root.chatHistoryMap = root.withEntry(root.chatHistoryMap, root.activeJid, updated)
    root.updateChatListSnippet(root.activeJid, text, "me", tempMsg.ts)
    Qt.callLater(function () { if (messageList) messageList.positionViewAtEnd() })

    root.sendReply(root.activeJid, text, rId, rSender, tempId)
    root.replyingTo = null
    composer.text = ""
  }

  function togglePlayVoice(jid, id, localPath) {
    var key = root.msgKey(jid, id)
    if (voicePlayer.activeKey === key) {
      if (voicePlayer.playbackState === MediaPlayer.PlayingState) {
        voicePlayer.pause()
      } else {
        voicePlayer.play()
      }
      return
    }

    voicePlayer.stop()
    voicePlayer.activeKey = key

    var path = localPath || root.mediaPaths[key] || ""
    if (path !== "") {
      voicePlayer.source = root.fileUrl(path)
      voicePlayer.play()
    } else {
      root.busyKey = key
      runAction(["media", String(jid), String(id)], function (p) {
        root.busyKey = ""
        if (p && p.ok === true && p.path) {
          root.mediaPaths = root.withEntry(root.mediaPaths, key, String(p.path))
          if (voicePlayer.activeKey === key) {
            voicePlayer.source = root.fileUrl(p.path)
            voicePlayer.play()
          }
        }
      })
    }
  }

  function playVoice(jid, id) {
    root.togglePlayVoice(jid, id, "")
  }

  function openAttachment(jid, id) {
    root.busyKey = root.msgKey(jid, id)
    runAction(["open", String(jid), String(id)], function () { root.busyKey = "" })
  }

  // --- voice reply implementation -------------------------------------------
  Process {
    id: voiceStatusProc
    running: false
    function probe() { if (!voiceStatusProc.running) voiceStatusProc.running = true }
    command: [root.ctlScript, "voice-status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var p = JSON.parse(this.text)
          root.voiceAvailable = !!(p && p.ok === true && p.available === true)
          root.voiceDetail = String((p && (p.detail || p.recorder)) || "")
          if (p && typeof p.maxSeconds === "number" && p.maxSeconds > 0)
            root.voiceMaxSeconds = p.maxSeconds
        } catch (e) {
          root.voiceAvailable = false
          root.voiceDetail = ""
        }
      }
    }
  }

  Process {
    id: recordProc
    running: false
    stdinEnabled: false
    stdout: StdioCollector {
      onStreamFinished: {
        var discard = root.voiceDiscardOnStop
        root.voiceDiscardOnStop = false
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "recording failed")
          root.resetVoice()
          return
        }
        if (discard) {
          root.discardRecording(String(payload.token))
          root.resetVoice()
          return
        }
        root.voiceToken = String(payload.token || "")
        if (typeof payload.seconds === "number") root.voiceSeconds = payload.seconds
        root.voiceLevel = payload.silent === true ? "silent"
                        : (payload.silent === false ? "ok" : "unknown")
        root.voiceState = root.voiceToken !== "" ? "preview" : "idle"
      }
    }
  }

  Process {
    id: voiceSendProc
    property string targetJid: ""
    property string tempId: ""
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        var abandoned = root.voiceAbandonOnSend
        var targetJid = voiceSendProc.targetJid || root.voiceJid
        var tempId = voiceSendProc.tempId
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "voice note send failed")
          if (tempId) {
            var markFailed = function(list) {
              var res = []
              for (var i = 0; i < (list || []).length; i++) {
                var m = list[i]
                if (m && m.id === tempId) res.push(Object.assign({}, m, { isFailed: true }))
                else res.push(m)
              }
              return res
            }
            if (root.activeJid === targetJid) root.messages = markFailed(root.messages)
            if (root.chatHistoryMap[targetJid]) {
              root.chatHistoryMap = root.withEntry(root.chatHistoryMap, targetJid, markFailed(root.chatHistoryMap[targetJid]))
            }
          }
          if (abandoned) {
            if (root.voiceToken !== "") root.discardRecording(root.voiceToken)
            root.resetVoice()
          } else {
            root.voiceState = "preview"
            root.voiceAbandonOnSend = false
          }
          return
        }
        root.actionError = ""
        var sentVoiceJid = targetJid || root.voiceJid
        root.resetVoice()
        if (tempId && payload.id) {
          var realId = String(payload.id)
          var updateMsgId = function(list) {
            var res = []
            for (var i = 0; i < (list || []).length; i++) {
              var m = list[i]
              if (m && m.id === tempId) res.push(Object.assign({}, m, { id: realId }))
              else res.push(m)
            }
            return res
          }
          if (root.activeJid === sentVoiceJid) root.messages = updateMsgId(root.messages)
          if (root.chatHistoryMap[sentVoiceJid]) {
            root.chatHistoryMap = root.withEntry(root.chatHistoryMap, sentVoiceJid, updateMsgId(root.chatHistoryMap[sentVoiceJid]))
          }
        }
        if (sentVoiceJid !== "") {
          root.autoMarkSeenAfterSend(sentVoiceJid)
          root.loadChatMessages(sentVoiceJid, root.chatSearchQuery)
          root.scheduleChatReload(sentVoiceJid)
        }
      }
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.voiceState === "recording"
    onTriggered: {
      root.voiceSeconds++
      if (root.voiceSeconds >= root.voiceMaxSeconds) root.stopVoice()
    }
  }

  property var voiceDiscardQueue: []

  function discardRecording(token) {
    if (!token) return
    var q = root.voiceDiscardQueue.slice()
    q.push(String(token))
    root.voiceDiscardQueue = q
    pumpDiscards()
  }

  function pumpDiscards() {
    if (discardProc.running) return
    if (root.voiceDiscardQueue.length === 0) return
    var q = root.voiceDiscardQueue.slice()
    var token = q.shift()
    root.voiceDiscardQueue = q
    discardProc.command = [root.ctlScript, "voice-discard", token]
    discardProc.running = true
  }

  Process {
    id: discardProc
    running: false
    stdout: StdioCollector { onStreamFinished: { } }
    onRunningChanged: if (!running) Qt.callLater(root.pumpDiscards)
  }

  function resetVoice() {
    root.voiceState = "idle"
    root.voiceJid = ""
    root.voiceName = ""
    root.voiceToken = ""
    root.voiceSeconds = 0
    root.voiceLevel = "ok"
    root.voiceDiscardOnStop = false
    root.voiceAbandonOnSend = false
  }

  function startVoice(jid, name) {
    if (root.voiceState !== "idle" || recordProc.running || sendProc.running) return
    root.actionError = ""
    root.voiceJid = String(jid)
    root.voiceName = String(name || jid).replace(/[<>&]/g, " ").replace(/[\r\n\t]+/g, " ")
    root.voiceToken = ""
    root.voiceSeconds = 0
    root.voiceLevel = "ok"
    root.voiceDiscardOnStop = false
    root.voiceAbandonOnSend = false
    root.voiceState = "recording"
    root.sendPresence(jid, "typing", "audio")
    recordProc.command = [root.ctlScript, "voice-record", String(root.voiceMaxSeconds)]
    recordProc.stdinEnabled = true
    recordProc.running = true
  }

  function stopVoice() {
    if (root.voiceState !== "recording") return
    recordProc.stdinEnabled = false
    if (root.voiceJid) root.sendPresence(root.voiceJid, "paused")
  }

  function cancelVoice() {
    if (root.voiceJid) root.sendPresence(root.voiceJid, "paused")
    if (root.voiceState === "sending") {
      root.voiceAbandonOnSend = true
      return
    }
    if (root.voiceState === "recording") {
      root.voiceDiscardOnStop = true
      recordProc.stdinEnabled = false
      return
    }
    if (root.voiceState === "preview" && root.voiceToken !== "")
      root.discardRecording(root.voiceToken)
    root.resetVoice()
  }

  function playVoiceDraft() {
    if (root.voiceState !== "preview" || root.voiceToken === "") return
    root.runAction(["voice-play", root.voiceToken], null)
  }

  function sendVoice() {
    if (root.voiceState !== "preview" || root.voiceToken === "") return
    if (voiceSendProc.running) return

    var tempVoiceMsg = {
      id: "temp_voice_" + Date.now(),
      chatJid: root.voiceJid,
      ts: Math.round(Date.now() / 1000),
      fromMe: true,
      sender: "Tú",
      senderJid: "",
      text: "",
      mediaType: "audio",
      mime: "audio/ogg; codecs=opus",
      filename: "",
      localPath: "",
      hasMedia: true,
      isVoice: true,
      quotedId: "",
      quotedSender: "",
      quotedText: "",
      quotedMediaType: "",
      reactions: []
    }
    if (root.activeJid === root.voiceJid) {
      var updated = root.messages.concat([tempVoiceMsg])
      root.messages = updated
      root.chatHistoryMap = root.withEntry(root.chatHistoryMap, root.voiceJid, updated)
      Qt.callLater(function () { if (messageList) messageList.positionViewAtEnd() })
    }
    root.updateChatListSnippet(root.voiceJid, "🎤 Nota de voz", "me", tempVoiceMsg.ts)

    root.voiceState = "sending"
    voiceSendProc.targetJid = root.voiceJid
    voiceSendProc.tempId = tempVoiceMsg.id
    voiceSendProc.command = [root.ctlScript, "voice-send", root.voiceJid, root.voiceToken]
    voiceSendProc.running = true
  }

  // --- thumbnail queue ------------------------------------------------------
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
        root.mediaPaths = root.withEntry(root.mediaPaths, thumbProc.key,
          (payload && payload.ok === true) ? String(payload.path) : "")
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.pumpThumbs)
  }

  // --- avatar queue ---------------------------------------------------------
  property var avatarPaths: ({})
  property var avatarQueue: []

  function queueAvatar(jid) {
    if (!jid) return
    if (root.avatarPaths[jid] !== undefined) return
    for (var i = 0; i < root.avatarQueue.length; i++)
      if (root.avatarQueue[i] === jid) return
    var q = root.avatarQueue.slice()
    q.push(String(jid))
    root.avatarQueue = q
    pumpAvatars()
  }

  function pumpAvatars() {
    if (avatarProc.running) return
    if (root.avatarQueue.length === 0) return
    var q = root.avatarQueue.slice()
    var jid = q.shift()
    root.avatarQueue = q
    avatarProc.jid = jid
    avatarProc.command = [root.ctlScript, "avatar", jid]
    avatarProc.running = true
  }

  Process {
    id: avatarProc
    running: false
    property string jid: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        var p = (payload && payload.ok === true && payload.path) ? String(payload.path) : ""
        root.avatarPaths = root.withEntry(root.avatarPaths, avatarProc.jid, p)
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.pumpAvatars)
  }

  property bool syncingAvatars: false

  Process {
    id: syncAvatarsProc
    running: false
    command: [root.ctlScript, "sync-avatars", "force"]
    onRunningChanged: root.syncingAvatars = running
    stdout: StdioCollector {
      onStreamFinished: {
        root.avatarPaths = ({})
        root.avatarQueue = []
        for (var i = 0; i < root.chats.length; i++) {
          if (root.chats[i] && root.chats[i].jid) root.queueAvatar(root.chats[i].jid)
        }
        for (var j = 0; j < root.allChatsList.length; j++) {
          if (root.allChatsList[j] && root.allChatsList[j].jid) root.queueAvatar(root.allChatsList[j].jid)
        }
        if (root.activeJid) root.queueAvatar(root.activeJid)
      }
    }
  }

  function reloadAvatars() {
    if (syncAvatarsProc.running) return
    syncAvatarsProc.command = [root.ctlScript, "sync-avatars", "force"]
    syncAvatarsProc.running = true
  }

  Process {
    id: allChatsProc
    running: false
    onRunningChanged: root.fetchingAllChats = running
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (payload && payload.ok === true && Array.isArray(payload.chats)) {
          var incomingChats = payload.chats.slice()
          for (var c = 0; c < incomingChats.length; c++) {
            var chatItem = incomingChats[c]
            if (!chatItem || !chatItem.jid) continue
            var hist = root.chatHistoryMap[chatItem.jid]
            if (hist && hist.length > 0) {
              var lastHist = hist[hist.length - 1]
              if (lastHist && (lastHist.ts || 0) > (chatItem.lastTs || 0)) {
                chatItem.lastTs = lastHist.ts
                chatItem.snippet = lastHist.text || (lastHist.mediaType ? "[" + lastHist.mediaType + "]" : (lastHist.filename || ""))
                chatItem.lastSender = lastHist.fromMe ? "me" : (lastHist.sender || "")
              }
            }
          }
          incomingChats.sort(function(a, b) { return (b.lastTs || 0) - (a.lastTs || 0) })
          root.allChatsList = incomingChats
        }
      }
    }
  }

  Timer {
    id: searchDebounceTimer
    interval: 200
    repeat: false
    onTriggered: root.fetchAllChats()
  }

  Timer {
    id: chatSearchDebounceTimer
    interval: 250
    repeat: false
    onTriggered: {
      if (root.activeJid) root.loadChatMessages(root.activeJid, root.chatSearchQuery)
    }
  }

  Process {
    id: messagesProc
    property string jid: ""
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (payload && payload.ok === true && Array.isArray(payload.messages)) {
          var targetJid = String(payload.jid || messagesProc.jid)
          var incoming = payload.messages
          var current = (root.activeJid === targetJid && root.messages && root.messages.length > 0)
            ? root.messages
            : (root.chatHistoryMap[targetJid] || [])

          // Preserve any in-flight temporary/optimistic messages not yet synced to SQLite
          var pending = []
          var nowSec = Math.floor(Date.now() / 1000)
          for (var c = 0; c < current.length; c++) {
            var curMsg = current[c]
            if (!curMsg) continue
            var isTemp = String(curMsg.id || "").indexOf("temp_") === 0

            // Check if this message is already present in incoming
            var matched = false
            for (var k = 0; k < incoming.length; k++) {
              var incMsg = incoming[k]
              if (!incMsg) continue
              // Exact ID match (covers synced messages with real WhatsApp ID)
              if (curMsg.id && incMsg.id && curMsg.id === incMsg.id) {
                matched = true
                break
              }
              // For temp optimistic messages, match only forward in time (-5s to +35s slack)
              if (isTemp && incMsg.fromMe) {
                var tsDiff = (incMsg.ts || 0) - (curMsg.ts || 0)
                if (tsDiff >= -5 && tsDiff <= 35) {
                  var curText = String(curMsg.text || "").trim()
                  var incText = String(incMsg.text || "").trim()
                  if (curText !== "" && incText === curText) {
                    matched = true
                    break
                  }
                  if (curMsg.hasMedia && incMsg.hasMedia) {
                    if ((curMsg.filename && incMsg.filename === curMsg.filename) || (curMsg.mediaType && incMsg.mediaType === curMsg.mediaType)) {
                      matched = true
                      break
                    }
                  }
                }
              }
            }

            if (!matched) {
              // Retain in-flight / recent sent messages if created within the last 3 minutes
              if (curMsg.fromMe && (nowSec - (curMsg.ts || 0) < 180)) {
                pending.push(curMsg)
              }
            }
          }

          var merged = incoming.concat(pending)
          merged.sort(function(a, b) { return (a.ts || 0) - (b.ts || 0) })
          root.chatHistoryMap = root.withEntry(root.chatHistoryMap, targetJid, merged)
          if (root.activeJid === targetJid) {
            root.messages = merged
            Qt.callLater(function() {
              if (messageList) messageList.positionViewAtEnd()
            })
          }
          for (var i = 0; i < incoming.length; i++) {
            var msg = incoming[i]
            if (String(msg.mediaType) === "image" || String(msg.mediaType) === "sticker")
              root.queueThumb(targetJid, msg.id)
          }
        }
        root.loadingHistoryJid = ""
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.view === "chat") {
          if (root.chatSearchOpen) { root.chatSearchOpen = false; root.chatSearchQuery = ""; root.loadChatMessages(root.activeJid); }
          else root.back()
        } else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }

      DropArea {
        anchors.fill: parent
        onEntered: function (drag) { drag.acceptProposedAction() }
        onDropped: function (drop) {
          var filePath = Model.getFilePathFromDrop(drop)
          if (filePath) root.attachDroppedFile(filePath)
          drop.acceptProposedAction()
        }
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(8)

        // ── Header ────────────────────────────────────────────────────────
        Item {
          width: parent.width
          implicitHeight: Math.max(headerTitleCol.implicitHeight, backBtn.height, headerActions.implicitHeight)

          Button {
            id: backBtn
            visible: root.view === "chat"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.iconBack
            tooltipText: "Volver a la lista de chats"
            bordered: true
            foreground: root.contentForeground
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.body
            onClicked: root.back()
          }

          Rectangle {
            id: headerAvatar
            visible: root.view === "chat"
            width: Style.space(28)
            height: Style.space(28)
            radius: width / 2
            anchors.left: backBtn.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            color: Model.avatarColor(root.activeJid || (root.activeChat ? root.activeChat.name : ""))
            clip: true

            readonly property string headAvPath: root.avatarPaths[root.activeJid] || ""

            Text {
              visible: !headAvatarEffect.visible
              anchors.centerIn: parent
              text: Model.avatarInitials(root.activeChat ? root.activeChat.name : root.activeJid, root.activeChat ? root.activeChat.kind : "dm")
              color: Color.background
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Item {
              id: headMask
              anchors.fill: parent
              visible: false
              layer.enabled: true
              layer.smooth: true
              Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: "white"
              }
            }

            Image {
              id: headAvatarImg
              anchors.fill: parent
              visible: false
              source: headerAvatar.headAvPath !== "" ? root.fileUrl(headerAvatar.headAvPath) : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: false
            }

            MultiEffect {
              id: headAvatarEffect
              anchors.fill: parent
              source: headAvatarImg
              visible: headerAvatar.headAvPath !== "" && headAvatarImg.status === Image.Ready
              maskEnabled: true
              maskSource: headMask
              maskThresholdMin: 0.5
              maskSpreadAtMin: 0.02
            }

            Rectangle {
              id: headOnlineDot
              width: Style.space(8)
              height: Style.space(8)
              radius: width / 2
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              color: "#25d366"
              border.color: Color.background
              border.width: 1.5
              visible: Model.isContactOnline(root.activeChat, root.messages)
            }
          }

          Column {
            id: headerTitleCol
            anchors.left: headerAvatar.visible ? headerAvatar.right : (backBtn.visible ? backBtn.right : parent.left)
            anchors.leftMargin: (headerAvatar.visible || backBtn.visible) ? Style.space(8) : 0
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              width: parent.width
              text: {
                if (root.view === "chat") {
                  return root.activeChat ? (root.activeChat.name || root.activeJid) : (root.activeJid || "Chat")
                }
                return root.widgetLabel !== "" ? root.widgetLabel : "WhatsApp"
              }
              color: root.contentForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: {
                if (root.view === "chat") {
                  if (root.loadingHistoryJid === root.activeJid) return "cargando mensajes…"
                  return Model.contactStatusText(root.activeChat, root.messages)
                }
                if (!root.everLoaded) return "cargando…"
                if (root.errorText !== "") return "no disponible"
                if (root.paused) return "notificaciones pausadas"
                if (root.currentTab === "unread") {
                  return root.totalNew > 0
                    ? (root.totalNew + (root.truncated ? "+" : "") + " no leídos")
                    : "al día"
                }
                return "todos los chats"
              }
              color: {
                if (root.view === "chat") {
                  return Model.isContactOnline(root.activeChat, root.messages)
                    ? "#25d366"
                    : Util.alpha(root.contentForeground, 0.6)
                }
                return (root.totalNew > 0 && root.view === "chats" && root.currentTab === "unread")
                  ? root.accentColor
                  : Util.alpha(root.contentForeground, 0.6)
              }
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            // In-chat search toggle button
            PanelActionButton {
              visible: root.view === "chat"
              iconText: root.iconSearch
              tooltipText: root.chatSearchOpen ? "Cerrar búsqueda" : "Buscar en esta conversación"
              foreground: root.chatSearchOpen ? root.accentColor : root.contentForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              onClicked: {
                root.chatSearchOpen = !root.chatSearchOpen
                if (!root.chatSearchOpen) {
                  root.chatSearchQuery = ""
                  root.loadChatMessages(root.activeJid)
                } else {
                  Qt.callLater(function () { if (chatSearchTextInput) chatSearchTextInput.forceActiveFocus() })
                }
              }
            }

            PanelActionButton {
              iconText: root.iconMarkRead
              tooltipText: root.view === "chat" ? "Marcar chat como leído" : "Marcar todo como leído"
              foreground: root.contentForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              visible: root.view === "chat" || root.totalNew > 0 || (root.chats && root.chats.length > 0)
              enabled: !root.markReadBusy
              onClicked: {
                if (root.view === "chat" && root.activeJid) {
                  var lastTs = (root.activeChat && root.activeChat.lastTs)
                    ? root.activeChat.lastTs
                    : (root.messages && root.messages.length > 0 ? root.messages[root.messages.length - 1].ts : 0)
                  root.markSeen(root.activeJid, lastTs)
                } else {
                  root.markAllSeen()
                }
              }
            }

            PanelActionButton {
              id: refreshBtn
              iconText: root.iconRefresh
              tooltipText: root.view === "chat" ? "Actualizar conversación y foto" : "Actualizar chats y fotos"
              foreground: root.contentForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              onClicked: {
                root.reloadAvatars()
                if (root.view === "chat" && root.activeJid) {
                  root.loadChatMessages(root.activeJid, root.chatSearchQuery)
                } else if (root.currentTab === "all") {
                  root.fetchAllChats()
                } else if (root.hostWidget) {
                  root.hostWidget.refresh()
                }
              }

              RotationAnimator {
                target: refreshBtn
                from: 0; to: 360
                duration: 700
                loops: Animation.Infinite
                running: root.fetching || root.fetchingAllChats || root.syncingAvatars || (root.loadingHistoryJid !== "")
              }
            }

            PanelActionButton {
              visible: root.view === "chats"
              iconText: root.iconSettings
              tooltipText: "Configurar notificaciones"
              foreground: root.settingsOpen ? root.accentColor : root.contentForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              onClicked: root.settingsOpen = !root.settingsOpen
            }

            PanelActionButton {
              iconText: root.iconWhatsApp
              tooltipText: "Abrir WhatsApp Web"
              foreground: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              onClicked: root.openWebApp()
            }
          }
        }

        // ── In-Chat Search Bar ────────────────────────────────────────────
        Rectangle {
          id: chatSearchBar
          width: parent.width
          height: Style.space(30)
          radius: Style.cornerRadius
          visible: root.view === "chat" && root.chatSearchOpen
          color: Style.controlFill(chatSearchTextInput.activeFocus, chatSearchHover.hovered, root.contentForeground, root.accentColor)
          border.color: chatSearchTextInput.activeFocus ? root.accentColor : Util.alpha(root.contentForeground, 0.2)
          border.width: 1

          HoverHandler { id: chatSearchHover }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.iconSearch
              color: Util.alpha(root.contentForeground, 0.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.icon
            }

            TextInput {
              id: chatSearchTextInput
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(48)
              text: root.chatSearchQuery
              color: root.contentForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              clip: true
              selectByMouse: true
              onTextChanged: {
                root.chatSearchQuery = text
                chatSearchDebounceTimer.restart()
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Buscar mensajes en este chat…"
                color: Util.alpha(root.contentForeground, 0.4)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                visible: chatSearchTextInput.text === "" && !chatSearchTextInput.activeFocus
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: chatSearchTextInput.text !== ""
              text: "✕"
              color: Util.alpha(root.contentForeground, 0.6)
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  chatSearchTextInput.text = ""
                  root.chatSearchQuery = ""
                  root.loadChatMessages(root.activeJid)
                }
              }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.contentForeground; strength: 0.1 }

        // ── Faults & Alerts / Onboarding Guide ─────────────────────────────
        Rectangle {
          width: parent.width
          visible: root.errorText !== ""
          radius: Style.radius.panel
          color: Util.alpha(root.alertColor, 0.12)
          border.color: Util.alpha(root.alertColor, 0.3)
          border.width: 1
          implicitHeight: errCol.implicitHeight + Style.space(16)

          Column {
            id: errCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            spacing: Style.space(6)

            Row {
              spacing: Style.space(6)
              Text {
                text: "⚠️"
                font.pixelSize: Style.font.body
              }
              Text {
                text: "WhatsApp no vinculado o wacli ausente"
                color: root.alertColor
                font.bold: true
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              width: parent.width
              text: root.errorText
              color: root.contentForeground
              wrapMode: Text.WordWrap
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              text: "Para conectar tu cuenta de WhatsApp:\n1. Ejecuta en tu terminal: wacli auth\n2. Escanea el código QR desde tu teléfono (WhatsApp > Dispositivos vinculados).\n3. Inicia la sincronización: systemctl --user enable --now whatsmarchy-sync"
              color: Util.alpha(root.contentForeground, 0.85)
              wrapMode: Text.WordWrap
              font.pixelSize: Math.max(9, Style.font.caption - 1)
            }
          }
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

        Rectangle {
          width: parent.width
          visible: root.everLoaded && root.errorText === "" && !root.syncRunning
          radius: Style.radius.panel
          color: Util.alpha(Color.urgent, 0.1)
          border.color: Util.alpha(Color.urgent, 0.25)
          border.width: 1
          implicitHeight: syncCol.implicitHeight + Style.space(14)

          Column {
            id: syncCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(8)
            spacing: Style.space(4)

            Text {
              text: "⚠️ Sincronización en segundo plano pausada"
              color: Color.urgent
              font.bold: true
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              text: "Para recibir mensajes en tiempo real, ejecuta en terminal:\nsystemctl --user enable --now whatsmarchy-sync"
              color: Util.alpha(root.contentForeground, 0.85)
              wrapMode: Text.WordWrap
              font.pixelSize: Math.max(9, Style.font.caption - 1)
            }
          }
        }

        // ── Settings View ────────────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.settingsOpen && root.view === "chats"

          PanelSectionHeader {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "QUIÉN PUEDE NOTIFICARME"
            foreground: root.contentForeground
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)
            Repeater {
              model: [
                { value: "paused", label: "Pausado" },
                { value: "all",    label: "Todos" },
                { value: "custom", label: "Chats elegidos" }
              ]
              delegate: Button {
                required property var modelData
                text: modelData.label
                bordered: true
                selected: root.mode === modelData.value
                foreground: root.contentForeground
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
            Component.onCompleted: allowSelect.values = root.allowList
            Connections {
              target: root
              function onAllowListChanged() {
                if (!allowProc.running) allowSelect.values = root.allowList
              }
            }
            optionsCommand: root.ctlScript !== "" ? [root.ctlScript, "recipients"] : []
            placeholderText: "Buscar contactos y grupos…"
            emptyText: "No hay chats sincronizados aún"
            noSelectionText: "Sin chats seleccionados"
            foreground: root.contentForeground
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function (values) { root.saveAllow(values) }
          }

          PanelSeparator { width: parent.width; foreground: root.contentForeground; strength: 0.08 }
          PanelSectionHeader {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "DETALLE EN LA BARRA"
            foreground: root.contentForeground
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: [
                { value: "Icon only",                          label: "Solo icono" },
                { value: "Count only",                         label: "Solo conteo" },
                { value: "Sender and count",                   label: "Remitente y conteo" },
                { value: "Message preview (nothing to hide)",  label: "Vista previa del mensaje" }
              ]
              delegate: Button {
                required property var modelData
                width: parent.width
                text: modelData.label
                bordered: true
                selected: root.hostWidget && root.hostWidget.barDetail === modelData.value
                foreground: root.contentForeground
                accent: root.accentColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.setBarDetail(modelData.value)
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.contentForeground; strength: 0.08 }
          PanelSectionHeader {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "FOTOS DE PERFIL"
            foreground: root.contentForeground
          }

          Button {
            width: parent.width
            text: root.syncingAvatars ? "Sincronizando fotos…" : "Recargar fotos de perfil"
            icon: root.iconRefresh
            bordered: true
            enabled: !root.syncingAvatars
            foreground: root.contentForeground
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.bodySmall
            onClicked: root.reloadAvatars()
          }

          PanelSeparator { width: parent.width; foreground: root.contentForeground; strength: 0.08 }
        }

        // ═══════════════════════════════════════════════════════════════════
        // ── CHATS LIST VIEW ───────────────────────────────────────────────
        // ═══════════════════════════════════════════════════════════════════
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.settingsOpen && root.view === "chats"

          // --- Attached File Banner in Chats List ---
          Rectangle {
            width: parent.width
            implicitHeight: fileBannerRow.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            visible: root.selectedFile !== null
            color: Util.alpha(root.accentColor, 0.15)
            border.color: root.accentColor
            border.width: 1

            Row {
              id: fileBannerRow
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.fileGlyph(root.selectedFile ? root.selectedFile.mime : "")
                color: root.accentColor
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.icon
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.font.icon - discardBannerBtn.implicitWidth - Style.space(24)
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: root.selectedFile ? root.selectedFile.name : ""
                  textFormat: Text.PlainText
                  color: root.contentForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideMiddle
                }

                Text {
                  width: parent.width
                  text: "Selecciona un chat para enviarlo"
                  color: root.accentColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Math.max(9, Style.font.caption - 2)
                }
              }

              Button {
                id: discardBannerBtn
                anchors.verticalCenter: parent.verticalCenter
                text: "✕"
                tooltipText: "Descartar archivo"
                bordered: true
                foreground: root.contentForeground
                accent: root.alertColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                onClicked: { root.selectedFile = null; root.fileCaption = "" }
              }
            }
          }

          // --- Tabs: No leídos / Todos los chats ---
          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (parent.width - Style.space(6)) / 2
              text: "No leídos" + (root.totalNew > 0 ? " (" + root.totalNew + ")" : "")
              bordered: true
              selected: root.currentTab === "unread"
              foreground: root.contentForeground
              accent: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.bodySmall
              onClicked: {
                root.currentTab = "unread"
                if (root.hostWidget) root.hostWidget.refresh()
              }
            }

            Button {
              width: (parent.width - Style.space(6)) / 2
              text: "Todos los chats"
              bordered: true
              selected: root.currentTab === "all"
              foreground: root.contentForeground
              accent: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.bodySmall
              onClicked: {
                root.currentTab = "all"
                root.fetchAllChats()
              }
            }
          }

          // --- Search Bar ---
          Rectangle {
            id: searchBox
            width: parent.width
            height: Style.space(32)
            radius: Style.cornerRadius
            visible: root.currentTab === "all"
            color: Style.controlFill(searchInput.activeFocus, searchHover.hovered, root.contentForeground, root.accentColor)
            border.color: searchInput.activeFocus ? root.accentColor : Util.alpha(root.contentForeground, 0.2)
            border.width: 1

            HoverHandler { id: searchHover }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.iconSearch
                color: Util.alpha(root.contentForeground, 0.6)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.icon
              }

              TextInput {
                id: searchInput
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(48)
                text: root.searchQuery
                color: root.contentForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                clip: true
                selectByMouse: true
                onTextChanged: {
                  root.searchQuery = text
                  searchDebounceTimer.restart()
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Buscar chat o contacto…"
                  color: Util.alpha(root.contentForeground, 0.4)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  visible: searchInput.text === "" && !searchInput.activeFocus
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: searchInput.text !== ""
                text: "✕"
                color: Util.alpha(root.contentForeground, 0.6)
                font.pixelSize: Style.font.caption
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    searchInput.text = ""
                    root.searchQuery = ""
                    root.fetchAllChats()
                  }
                }
              }
            }
          }

          // --- Empty State ---
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: root.everLoaded && root.errorText === "" && root.activeModel.length === 0
            text: root.currentTab === "all"
              ? (root.fetchingAllChats ? "Cargando chats…" : (root.searchQuery !== "" ? "No se encontraron chats." : "No hay chats disponibles."))
              : (root.paused ? "Notificaciones pausadas." : "Estás al día.")
            color: Util.alpha(root.contentForeground, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            topPadding: Style.space(12)
            bottomPadding: Style.space(12)
          }

          // --- Chat List View ---
          ListView {
            id: chatListView
            width: parent.width
            visible: root.activeModel.length > 0
            height: Math.min(contentHeight, Style.space(340))
            model: root.activeModel
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            delegate: CursorSurface {
              id: chatRowItem
              required property var modelData
              required property int index

              width: chatListView.width
              implicitHeight: Math.max(rowCol.implicitHeight + Style.space(12), Style.space(48))
              height: implicitHeight
              foreground: root.contentForeground
              accent: root.accentColor
              hasCursor: chatMouse.containsMouse || chatRowDrop.containsDrag

              Rectangle {
                anchors.fill: parent
                visible: chatRowDrop.containsDrag
                color: Util.alpha(root.accentColor, 0.2)
                border.color: root.accentColor
                border.width: 1
                radius: Style.cornerRadius
              }

              DropArea {
                id: chatRowDrop
                anchors.fill: parent
                onEntered: function (drag) { drag.acceptProposedAction() }
                onDropped: function (drop) {
                  var filePath = Model.getFilePathFromDrop(drop)
                  if (filePath) {
                    root.selectChat(chatRowItem.modelData)
                    root.attachDroppedFile(filePath)
                  }
                  drop.acceptProposedAction()
                }
              }

              Item {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)

                Rectangle {
                  id: avatarRect
                  width: Style.space(34)
                  height: Style.space(34)
                  radius: width / 2
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  color: Model.avatarColor(chatRowItem.modelData.jid || chatRowItem.modelData.name)
                  clip: true

                  Component.onCompleted: root.queueAvatar(chatRowItem.modelData.jid)

                  readonly property string avPath: root.avatarPaths[chatRowItem.modelData.jid] || ""

                  Text {
                    visible: !avatarEffect.visible
                    anchors.centerIn: parent
                    text: Model.avatarInitials(chatRowItem.modelData.name || chatRowItem.modelData.jid, chatRowItem.modelData.kind)
                    color: Color.background
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Item {
                    id: rowMask
                    anchors.fill: parent
                    visible: false
                    layer.enabled: true
                    layer.smooth: true
                    Rectangle {
                      anchors.fill: parent
                      radius: width / 2
                      color: "white"
                    }
                  }

                  Image {
                    id: avatarImg
                    anchors.fill: parent
                    visible: false
                    source: avatarRect.avPath !== "" ? root.fileUrl(avatarRect.avPath) : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: false
                  }

                  MultiEffect {
                    id: avatarEffect
                    anchors.fill: parent
                    source: avatarImg
                    visible: avatarRect.avPath !== "" && avatarImg.status === Image.Ready
                    maskEnabled: true
                    maskSource: rowMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 0.02
                  }

                  Rectangle {
                    width: Style.space(9)
                    height: Style.space(9)
                    radius: width / 2
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    color: "#25d366"
                    border.color: Color.background
                    border.width: 1.5
                    visible: Model.isContactOnline(chatRowItem.modelData)
                  }
                }

                Column {
                  id: rowCol
                  anchors.left: avatarRect.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: rowMeta.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  clip: true

                  Text {
                    width: parent.width
                    text: String(chatRowItem.modelData.name || chatRowItem.modelData.jid)
                    textFormat: Text.PlainText
                    color: root.contentForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: (chatRowItem.modelData.unread > 0 || (chatRowItem.modelData.count && chatRowItem.modelData.count > 0))
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: {
                      var snip = chatRowItem.modelData.snippet || ""
                      if (!snip && chatRowItem.modelData.messages && chatRowItem.modelData.messages.length > 0) {
                        var lastM = chatRowItem.modelData.messages[chatRowItem.modelData.messages.length - 1]
                        snip = lastM.text || (lastM.mediaType ? "[" + lastM.mediaType + "]" : "")
                      }
                      if (snip.toLowerCase() === "[audio]" || snip.toLowerCase() === "audio") {
                        snip = "🎤 Nota de voz"
                      }
                      var snd = chatRowItem.modelData.lastSender || ""
                      if (snd && snip) return snd + ": " + Model.oneLine(snip)
                      return Model.oneLine(snip) || "Sin mensajes recientes"
                    }
                    textFormat: Text.PlainText
                    color: Util.alpha(root.contentForeground, 0.55)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Row {
                  id: rowMeta
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)
                  z: 2

                  Column {
                    spacing: Style.space(2)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: stampText
                      anchors.right: parent.right
                      text: Model.chatTimestamp(chatRowItem.modelData.lastTs)
                      color: Util.alpha(root.contentForeground, 0.5)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    Rectangle {
                      id: badgeRect
                      anchors.right: parent.right
                      readonly property int uCount: Number(chatRowItem.modelData.count !== undefined ? chatRowItem.modelData.count : (chatRowItem.modelData.unread || 0))
                      visible: badgeRect.uCount > 0
                      implicitWidth: badgeLabel.implicitWidth + Style.space(8)
                      implicitHeight: badgeLabel.implicitHeight + Style.space(2)
                      radius: height / 2
                      color: root.accentColor

                      Text {
                        id: badgeLabel
                        anchors.centerIn: parent
                        text: Model.badgeText(badgeRect.uCount)
                        color: Color.background
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }

                  Rectangle {
                    id: rowMarkReadBtn
                    readonly property int uCount: Number(chatRowItem.modelData.count !== undefined ? chatRowItem.modelData.count : (chatRowItem.modelData.unread || 0))
                    visible: rowMarkReadBtn.uCount > 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(24)
                    height: Style.space(24)
                    radius: Style.space(12)
                    color: rowMarkMouse.containsMouse ? Util.alpha(root.contentForeground, 0.12) : "transparent"

                    Text {
                      anchors.centerIn: parent
                      text: root.iconMarkRead
                      color: rowMarkMouse.containsMouse ? root.accentColor : Util.alpha(root.contentForeground, 0.6)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.small
                    }

                    MouseArea {
                      id: rowMarkMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: function (mouse) {
                        mouse.accepted = true
                        root.markSeen(chatRowItem.modelData.jid, chatRowItem.modelData.lastTs)
                      }
                    }
                  }
                }
              }

              MouseArea {
                id: chatMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectChat(chatRowItem.modelData)
              }
            }
          }
        }

        // ═══════════════════════════════════════════════════════════════════
        // ── DEDICATED CHAT CONVERSATION VIEW ──────────────────────────────
        // ═══════════════════════════════════════════════════════════════════
        Column {
          id: conversationCol
          width: parent.width
          spacing: Style.space(6)
          visible: !root.settingsOpen && root.view === "chat"

          ListView {
            id: messageList
            width: parent.width
            height: Style.space(330)
            model: root.messages
            clip: true
            spacing: Style.space(6)
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
            onMovementEnded: root.pinToLatest = atYEnd
            onContentHeightChanged: if (root.pinToLatest) Qt.callLater(function () { messageList.positionViewAtEnd() })

            delegate: Column {
              id: messageRow
              required property var modelData
              required property int index

              width: messageList.width
              spacing: Style.space(4)

              readonly property var previous: messageRow.index > 0 ? root.messages[messageRow.index - 1] : null
              readonly property bool showDay: !messageRow.previous
                || !Model.sameDay(messageRow.previous.ts, messageRow.modelData.ts)

              Text {
                width: parent.width
                visible: messageRow.showDay
                horizontalAlignment: Text.AlignHCenter
                text: Model.dayLabel(messageRow.modelData.ts)
                color: Util.alpha(root.contentForeground, 0.5)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                topPadding: Style.space(4)
                bottomPadding: Style.space(2)
              }

              Item {
                id: bubbleRow
                width: parent.width
                implicitHeight: bubbleRect.height + (reactionsBadge.visible ? Style.space(10) : 0)
                height: implicitHeight

                readonly property real pad: Style.space(8)
                readonly property real maxInner: Math.max(Style.space(60), bubbleRow.width * 0.78 - bubbleRow.pad * 2)
                readonly property string key: root.msgKey(messageRow.modelData.chatJid || root.activeJid, messageRow.modelData.id)
                readonly property string thumb: {
                  var p = root.mediaPaths[key]
                  return (p !== undefined && p !== "") ? p : (messageRow.modelData.localPath || "")
                }
                readonly property bool hasThumb: thumb !== ""
                readonly property bool isGroupChat: root.activeChat ? root.activeChat.kind === "group" : false
                readonly property bool showSender: !messageRow.modelData.fromMe && bubbleRow.isGroupChat && String(messageRow.modelData.sender || "") !== ""

                // Hover area for message actions (quote & react)
                HoverHandler { id: bubbleHover }

                // Quick Action Bar on Hover (Quote & React)
                Row {
                  id: bubbleActionBar
                  visible: bubbleHover.hovered || actionPop.visible
                  anchors.right: messageRow.modelData.fromMe ? bubbleRect.left : undefined
                  anchors.left: messageRow.modelData.fromMe ? undefined : bubbleRect.right
                  anchors.rightMargin: Style.space(4)
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: bubbleRect.verticalCenter
                  spacing: Style.space(2)
                  z: 5

                  // Reply / Quote Button
                  Button {
                    text: "↩"
                    tooltipText: "Responder / Citar"
                    bordered: true
                    foreground: root.contentForeground
                    accent: root.accentColor
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onClicked: {
                      root.replyingTo = {
                        id: messageRow.modelData.id,
                        sender: messageRow.modelData.sender || (messageRow.modelData.fromMe ? "Tú" : "Contacto"),
                        text: messageRow.modelData.text || messageRow.modelData.mediaType || "Mensaje",
                        senderJid: messageRow.modelData.senderJid || ""
                      }
                      if (composer) composer.forceActiveFocus()
                    }
                  }

                  // Reaction Trigger Button
                  Button {
                    id: reactBtn
                    text: "😀"
                    tooltipText: "Reaccionar"
                    bordered: true
                    foreground: root.contentForeground
                    accent: root.accentColor
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onClicked: actionPop.visible = !actionPop.visible
                  }
                }

                // Quick Reactions Popover
                Rectangle {
                  id: actionPop
                  visible: false
                  anchors.bottom: bubbleRect.top
                  anchors.bottomMargin: Style.space(4)
                  anchors.right: messageRow.modelData.fromMe ? bubbleRect.right : undefined
                  anchors.left: messageRow.modelData.fromMe ? undefined : bubbleRect.left
                  implicitWidth: reactListRow.implicitWidth + Style.space(8)
                  implicitHeight: reactListRow.implicitHeight + Style.space(6)
                  radius: Style.cornerRadius
                  color: Color.popups.background
                  border.color: Util.alpha(root.accentColor, 0.5)
                  border.width: 1
                  z: 10

                  Row {
                    id: reactListRow
                    anchors.centerIn: parent
                    spacing: Style.space(4)
                    Repeater {
                      model: ["❤️", "👍", "😂", "😮", "😢", "🙏"]
                      delegate: Text {
                        required property string modelData
                        text: modelData
                        font.pixelSize: Style.font.body
                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.sendReaction(messageRow.modelData.chatJid || root.activeJid, messageRow.modelData.id, modelData, messageRow.modelData.senderJid)
                            actionPop.visible = false
                          }
                        }
                      }
                    }
                  }
                }

                // Main Bubble Rectangle
                Rectangle {
                  id: bubbleRect
                  width: bubbleContent.width + bubbleRow.pad * 2
                  height: bubbleContent.implicitHeight + bubbleRow.pad
                  anchors.right: messageRow.modelData.fromMe ? parent.right : undefined
                  anchors.left: messageRow.modelData.fromMe ? undefined : parent.left
                  radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
                  color: messageRow.modelData.fromMe
                    ? Util.alpha(root.accentColor, 0.28)
                    : Util.alpha(root.contentForeground, 0.12)
                  border.color: messageRow.modelData.fromMe
                    ? Util.alpha(root.accentColor, 0.45)
                    : Util.alpha(root.contentForeground, 0.15)
                  border.width: 1

                  Column {
                    id: bubbleContent
                    x: bubbleRow.pad
                    y: bubbleRow.pad / 2
                    spacing: Style.space(4)
                    width: Math.min(bubbleRow.maxInner, Math.max(
                      bubbleRow.showSender ? senderText.implicitWidth : 0,
                      quoteBox.visible ? quoteBox.width : 0,
                      photoImg.visible ? photoImg.width : 0,
                      voicePlayerRow.visible ? voicePlayerRow.width : 0,
                      docCard.visible ? docCard.width : 0,
                      bodyText.visible ? Math.min(bodyText.implicitWidth, bubbleRow.maxInner) : 0,
                      placeholderText.visible ? placeholderText.implicitWidth : 0,
                      metaRow.implicitWidth + Style.space(10)
                    ))

                    // ── Sender Name (in groups) ────────────────────────────
                    Text {
                      id: senderText
                      visible: bubbleRow.showSender
                      width: Math.min(implicitWidth, bubbleRow.maxInner)
                      text: String(messageRow.modelData.sender || "")
                      textFormat: Text.PlainText
                      color: root.accentColor
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    // ── Quoted Message Card (Reply) ────────────────────────
                    Rectangle {
                      id: quoteBox
                      visible: messageRow.modelData.quotedId !== ""
                      width: Math.min(bubbleRow.maxInner, Style.space(240))
                      implicitHeight: quoteBoxCol.implicitHeight + Style.space(8)
                      radius: Style.cornerRadius > 0 ? Math.max(2, Style.cornerRadius - 2) : Style.space(4)
                      color: Util.alpha(Color.background, 0.35)
                      border.color: messageRow.modelData.fromMe ? Util.alpha(root.accentColor, 0.35) : Util.alpha(root.contentForeground, 0.2)
                      border.width: 1

                      Rectangle {
                        id: quoteAccentBar
                        width: 3
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        radius: 1
                        color: root.accentColor
                      }

                      Column {
                        id: quoteBoxCol
                        anchors.left: quoteAccentBar.right
                        anchors.leftMargin: Style.space(6)
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(1)

                        Text {
                          width: parent.width
                          text: messageRow.modelData.quotedSender || "Mensaje"
                          textFormat: Text.PlainText
                          color: root.accentColor
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          elide: Text.ElideRight
                        }

                        Text {
                          width: parent.width
                          text: messageRow.modelData.quotedText || (messageRow.modelData.quotedMediaType ? "[" + messageRow.modelData.quotedMediaType + "]" : "...")
                          textFormat: Text.PlainText
                          color: Util.alpha(root.contentForeground, 0.75)
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Math.max(9, Style.font.caption - 1)
                          elide: Text.ElideRight
                          maximumLineCount: 2
                        }
                      }
                    }

                    // ── Photo / Sticker ────────────────────────────────────
                    Image {
                      id: photoImg
                      visible: bubbleRow.hasThumb && (String(messageRow.modelData.mediaType) === "image" || String(messageRow.modelData.mediaType) === "sticker")
                      width: Math.min(bubbleRow.maxInner, Style.space(200))
                      height: photoImg.sourceSize.height > 0
                        ? Math.min(Style.space(160), photoImg.sourceSize.height * (width / Math.max(1, photoImg.sourceSize.width)))
                        : Style.space(120)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      cache: false
                      source: bubbleRow.hasThumb ? root.fileUrl(bubbleRow.thumb) : ""

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openAttachment(messageRow.modelData.chatJid || root.activeJid, messageRow.modelData.id)
                      }
                    }

                    // ── WhatsApp Voice Note Player with Play/Pause & Progress Line ──
                    Row {
                      id: voicePlayerRow
                      visible: messageRow.modelData.isVoice === true || String(messageRow.modelData.mediaType) === "audio"
                      spacing: Style.space(10)
                      anchors.verticalCenter: undefined
                      width: Math.min(bubbleRow.maxInner, Style.space(220))

                      readonly property bool isThisPlaying: voicePlayer.activeKey === bubbleRow.key && voicePlayer.playbackState === MediaPlayer.PlayingState
                      readonly property bool isThisActive: voicePlayer.activeKey === bubbleRow.key

                      // Circular Play / Pause Button
                      Rectangle {
                        id: voicePlayCircle
                        width: Style.space(34)
                        height: Style.space(34)
                        radius: width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: messageRow.modelData.fromMe ? root.accentColor : Color.accent
                        opacity: voicePlayHover.hovered ? 0.85 : 1.0

                        HoverHandler { id: voicePlayHover }

                        Text {
                          anchors.centerIn: parent
                          text: voicePlayerRow.isThisPlaying ? root.iconPause : root.iconPlay
                          color: Color.background
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.icon
                        }

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.togglePlayVoice(messageRow.modelData.chatJid || root.activeJid, messageRow.modelData.id, messageRow.modelData.localPath)
                        }
                      }

                      // Waveform & Progress Line & Subtitle
                      Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)
                        width: voicePlayerRow.width - voicePlayCircle.width - Style.space(10)

                        // Stylized Waveform Bars with Reactive Progress & Scrubbing
                        Item {
                          id: waveformContainer
                          width: parent.width
                          height: Style.space(22)

                          Row {
                            anchors.fill: parent
                            spacing: Style.space(2)

                            Repeater {
                              model: [6, 12, 18, 10, 16, 20, 12, 18, 8, 14, 20, 12, 16, 10, 6]
                              delegate: Rectangle {
                                required property int modelData
                                required property int index
                                width: Style.space(3)
                                height: Style.space(modelData)
                                radius: width / 2
                                anchors.verticalCenter: parent.verticalCenter
                                color: {
                                  var barFraction = (index + 1) / 15.0
                                  var currentFraction = (voicePlayerRow.isThisActive && voicePlayer.duration > 0)
                                    ? (voicePlayer.position / voicePlayer.duration)
                                    : 0
                                  if (currentFraction >= barFraction) {
                                    return root.accentColor
                                  }
                                  return messageRow.modelData.fromMe
                                    ? Util.alpha(root.contentForeground, 0.45)
                                    : Util.alpha(root.contentForeground, 0.35)
                                }
                              }
                            }
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: function (mouse) {
                              if (voicePlayerRow.isThisActive && voicePlayer.duration > 0) {
                                var targetPos = Math.round((mouse.x / width) * voicePlayer.duration)
                                voicePlayer.position = targetPos
                              } else {
                                root.togglePlayVoice(messageRow.modelData.chatJid || root.activeJid, messageRow.modelData.id, messageRow.modelData.localPath)
                              }
                            }
                          }
                        }

                        // Time position & info row
                        Row {
                          width: parent.width
                          spacing: Style.space(4)

                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.iconMic
                            color: messageRow.modelData.fromMe ? root.accentColor : Util.alpha(root.contentForeground, 0.6)
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Math.max(9, Style.font.caption - 2)
                          }

                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: {
                              if (voicePlayerRow.isThisActive && voicePlayer.duration > 0) {
                                return root.mmss(voicePlayer.position / 1000) + " / " + root.mmss(voicePlayer.duration / 1000)
                              }
                              return "Nota de voz"
                            }
                            color: Util.alpha(root.contentForeground, 0.7)
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Math.max(9, Style.font.caption - 2)
                          }
                        }
                      }
                    }

                    // ── Document & Media Card ──────────────────────────────
                    Rectangle {
                      id: docCard
                      visible: (messageRow.modelData.hasMedia === true || String(messageRow.modelData.mediaType) === "document") && !photoImg.visible && !voicePlayerRow.visible
                      width: Math.min(bubbleRow.maxInner, Style.space(230))
                      implicitHeight: docCardRow.implicitHeight + Style.space(12)
                      radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
                      color: messageRow.modelData.fromMe
                        ? Util.alpha(Color.background, 0.28)
                        : Util.alpha(root.contentForeground, 0.08)
                      border.color: messageRow.modelData.fromMe
                        ? Util.alpha(root.accentColor, 0.35)
                        : Util.alpha(root.contentForeground, 0.15)
                      border.width: 1

                      Row {
                        id: docCardRow
                        anchors.fill: parent
                        anchors.margins: Style.space(6)
                        spacing: Style.space(8)

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.mediaGlyph(messageRow.modelData)
                          color: root.accentColor
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.icon
                        }

                        Column {
                          anchors.verticalCenter: parent.verticalCenter
                          width: parent.width - Style.font.icon - openDocBtn.implicitWidth - Style.space(20)
                          spacing: Style.space(1)

                          Text {
                            width: parent.width
                            text: root.mediaLabel(messageRow.modelData)
                            textFormat: Text.PlainText
                            color: root.contentForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            elide: Text.ElideMiddle
                          }

                          Text {
                            width: parent.width
                            text: String(messageRow.modelData.mime || messageRow.modelData.mediaType || "Archivo")
                            textFormat: Text.PlainText
                            color: Util.alpha(root.contentForeground, 0.55)
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Math.max(9, Style.font.caption - 2)
                            elide: Text.ElideRight
                          }
                        }

                        Button {
                          id: openDocBtn
                          anchors.verticalCenter: parent.verticalCenter
                          readonly property bool isBusy: root.busyKey === root.msgKey(messageRow.modelData.chatJid || root.activeJid, messageRow.modelData.id)
                          text: isBusy ? "…" : "Abrir"
                          bordered: true
                          enabled: !isBusy
                          foreground: root.contentForeground
                          accent: root.accentColor
                          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                          fontSize: Style.font.caption
                          onClicked: root.openAttachment(messageRow.modelData.chatJid || root.activeJid, messageRow.modelData.id)
                        }
                      }
                    }

                    // ── Text Content ───────────────────────────────────────
                    Text {
                      id: bodyText
                      visible: {
                        var t = String(messageRow.modelData.text || "").trim()
                        if (t === "") return false
                        if (voicePlayerRow.visible) {
                          if (t.toLowerCase() === "[audio]" || t.toLowerCase() === "audio") return false
                        }
                        return true
                      }
                      width: bubbleContent.width
                      text: String(messageRow.modelData.text || "")
                      textFormat: Text.PlainText
                      color: root.contentForeground
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                      wrapMode: Text.WrapAnywhere
                    }

                    // ── Placeholder for empty message ──────────────────────
                    Text {
                      id: placeholderText
                      visible: !photoImg.visible && !voicePlayerRow.visible && !docCard.visible && !bodyText.visible
                      width: Math.min(implicitWidth, bubbleRow.maxInner)
                      text: "(Mensaje)"
                      font.italic: true
                      color: Util.alpha(root.contentForeground, 0.45)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    // ── Timestamp & Status Ticks ───────────────────────────
                    Row {
                      id: metaRow
                      anchors.right: parent.right
                      spacing: Style.space(4)

                      Text {
                        id: metaText
                        text: Model.messageTimestamp(messageRow.modelData.ts)
                        color: Util.alpha(root.contentForeground, 0.5)
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                      }

                      // Checkmarks (palomitas) for sent messages
                      Text {
                        id: checkmarksText
                        visible: !!messageRow.modelData.fromMe
                        anchors.verticalCenter: metaText.verticalCenter
                        text: (messageRow.modelData.isFailed === true)
                          ? "❌"
                          : ((String(messageRow.modelData.id).indexOf("temp_") === 0 || messageRow.modelData.isPending === true)
                            ? "🕒"
                            : "✓✓")
                        color: (text === "❌")
                          ? root.alertColor
                          : ((text === "🕒")
                            ? Util.alpha(root.contentForeground, 0.45)
                            : root.accentColor)
                        font.pixelSize: (text === "🕒" || text === "❌") ? Math.max(8, Style.font.caption - 3) : Style.font.caption
                        font.bold: true
                      }
                    }
                  }
                }

                // ── Reactions Badge at Corner ──────────────────────────────
                Rectangle {
                  id: reactionsBadge
                  visible: messageRow.modelData.reactions && messageRow.modelData.reactions.length > 0
                  anchors.top: bubbleRect.bottom
                  anchors.topMargin: -Style.space(6)
                  anchors.right: messageRow.modelData.fromMe ? bubbleRect.right : undefined
                  anchors.left: messageRow.modelData.fromMe ? undefined : bubbleRect.left
                  anchors.rightMargin: Style.space(4)
                  anchors.leftMargin: Style.space(4)
                  implicitWidth: reactionLabel.implicitWidth + Style.space(8)
                  implicitHeight: reactionLabel.implicitHeight + Style.space(2)
                  radius: height / 2
                  color: Color.popups.background
                  border.color: Util.alpha(root.accentColor, 0.4)
                  border.width: 1
                  z: 3

                  Text {
                    id: reactionLabel
                    anchors.centerIn: parent
                    text: {
                      var list = messageRow.modelData.reactions || []
                      var seen = ({})
                      var ems = ""
                      var count = 0
                      for (var i = 0; i < list.length; i++) {
                        var e = list[i].emoji
                        if (!seen[e]) { seen[e] = true; ems += e; count++; }
                        if (count >= 3) break
                      }
                      if (list.length > 1) ems += " " + list.length
                      return ems
                    }
                    color: root.contentForeground
                    font.pixelSize: Math.max(10, Style.font.caption - 1)
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.messages.length === 0
            horizontalAlignment: Text.AlignHCenter
            text: root.chatSearchQuery !== ""
              ? "No se encontraron mensajes con \"" + root.chatSearchQuery + "\""
              : "No hay mensajes en esta conversación."
            color: Util.alpha(root.contentForeground, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
          }

          // ── Quoted Reply Preview Bar ──────────────────────────────────────
          Rectangle {
            id: replyPreviewBox
            width: parent.width
            implicitHeight: replyPreviewRow.implicitHeight + Style.space(6)
            radius: Style.cornerRadius
            visible: root.replyingTo !== null
            color: Util.alpha(root.accentColor, 0.15)
            border.color: root.accentColor
            border.width: 1

            Row {
              id: replyPreviewRow
              anchors.fill: parent
              anchors.margins: Style.space(4)
              spacing: Style.space(6)

              Rectangle {
                width: 3
                height: parent.height
                radius: 1
                color: root.accentColor
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(32)
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: "Respondiendo a " + (root.replyingTo ? root.replyingTo.sender : "")
                  textFormat: Text.PlainText
                  color: root.accentColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: root.replyingTo ? root.replyingTo.text : ""
                  textFormat: Text.PlainText
                  color: root.contentForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Math.max(9, Style.font.caption - 1)
                  elide: Text.ElideRight
                }
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                text: "✕"
                bordered: true
                foreground: root.contentForeground
                accent: root.alertColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                onClicked: root.replyingTo = null
              }
            }
          }

          // ── Bottom Composer Area ──────────────────────────────────────────
          Item {
            width: parent.width
            implicitHeight: {
              if (root.selectedFile !== null) return fileUploadCard.implicitHeight
              if (root.voiceState === "recording") return recordingBar.implicitHeight
              if (root.voiceState === "preview" || root.voiceState === "sending") return previewBar.implicitHeight
              return composerRow.implicitHeight
            }

            // Mode 1: Normal text composer
            Row {
              id: composerRow
              width: parent.width
              spacing: Style.space(6)
              visible: root.voiceState === "idle" && root.selectedFile === null

              Button {
                id: attachBtn
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.iconAttach
                tooltipText: "Adjuntar archivo (documento, imagen, etc.)"
                bordered: true
                enabled: !sendProc.running && !fileSendProc.running
                foreground: root.contentForeground
                accent: root.accentColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.body
                onClicked: root.pickFile()
              }

              TextField {
                id: composer
                width: parent.width - attachBtn.implicitWidth - sendBtn.implicitWidth - (micBtn.visible ? micBtn.implicitWidth + Style.space(6) : 0) - Style.space(6) * 3
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.contentForeground
                accent: root.accentColor
                placeholderText: root.replyingTo ? "Escribe una respuesta…" : "Escribe un mensaje…"
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                onTextChanged: {
                  if (composer.text.trim().length > 0 && root.activeJid) {
                    root.sendPresence(root.activeJid, "typing")
                    typingTimer.restart()
                  }
                }
                onAccepted: root.sendReplyText()
                Keys.onEscapePressed: function (event) {
                  if (root.replyingTo !== null) { root.replyingTo = null; event.accepted = true; return; }
                  if (composer.text.length > 0) composer.text = ""
                  else root.back()
                  event.accepted = true
                }
              }

              Button {
                id: micBtn
                anchors.verticalCenter: parent.verticalCenter
                visible: root.voiceAvailable
                iconText: root.iconMic
                tooltipText: "Grabar nota de voz"
                bordered: true
                enabled: !sendProc.running
                foreground: root.contentForeground
                accent: root.accentColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.body
                onClicked: root.startVoice(root.activeJid, root.activeChat ? root.activeChat.name : root.activeJid)
              }

              Button {
                id: sendBtn
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.iconSend
                tooltipText: "Enviar mensaje"
                bordered: true
                enabled: !sendProc.running && composer.text.trim().length > 0
                foreground: composer.text.trim().length > 0 ? root.accentColor : root.contentForeground
                accent: root.accentColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.body
                onClicked: root.sendReplyText()
              }
            }

            // Mode 2: File Upload Card (when a file is chosen)
            Rectangle {
              id: fileUploadCard
              width: parent.width
              implicitHeight: fileUploadCol.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              visible: root.selectedFile !== null
              color: Util.alpha(root.contentForeground, 0.08)
              border.color: Util.alpha(root.accentColor, 0.45)
              border.width: 1

              Column {
                id: fileUploadCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(6)
                spacing: Style.space(6)

                // Header row: Icon + Filename + Size + Discard Button
                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.fileGlyph(root.selectedFile ? root.selectedFile.mime : "")
                    color: root.accentColor
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.icon
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.font.icon - discardFileBtn.implicitWidth - Style.space(24)
                    spacing: Style.space(1)

                    Text {
                      width: parent.width
                      text: root.selectedFile ? root.selectedFile.name : ""
                      textFormat: Text.PlainText
                      color: root.contentForeground
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideMiddle
                    }

                    Text {
                      width: parent.width
                      text: root.selectedFile ? root.formatBytes(root.selectedFile.size) : ""
                      textFormat: Text.PlainText
                      color: Util.alpha(root.contentForeground, 0.6)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Button {
                    id: discardFileBtn
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✕"
                    tooltipText: "Descartar archivo"
                    bordered: true
                    foreground: root.contentForeground
                    accent: root.alertColor
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onClicked: { root.selectedFile = null; root.fileCaption = "" }
                  }
                }

                // Caption input + Send button row
                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  TextField {
                    id: captionInput
                    width: parent.width - sendFileBtn.implicitWidth - Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    foreground: root.contentForeground
                    accent: root.accentColor
                    placeholderText: "Comentario o pie de foto (opcional)…"
                    text: root.fileCaption
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    onTextChanged: root.fileCaption = text
                    onAccepted: root.sendFile()
                  }

                  Button {
                    id: sendFileBtn
                    anchors.verticalCenter: parent.verticalCenter
                    text: fileSendProc.running ? "…" : "Enviar"
                    iconText: root.iconSend
                    bordered: true
                    enabled: !fileSendProc.running
                    foreground: root.accentColor
                    accent: root.accentColor
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.bodySmall
                    onClicked: root.sendFile()
                  }
                }
              }
            }

            // Mode 3: Audio Recording in progress
            Rectangle {
              id: recordingBar
              width: parent.width
              height: Style.space(34)
              implicitHeight: height
              radius: Style.cornerRadius
              visible: root.voiceState === "recording"
              color: Util.alpha(root.alertColor, 0.15)
              border.color: Util.alpha(root.alertColor, 0.4)
              border.width: 1

              Item {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)

                Row {
                  anchors.left: parent.left
                  anchors.right: recButtons.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(10)
                    height: Style.space(10)
                    radius: width / 2
                    color: root.alertColor
                    SequentialAnimation on opacity {
                      running: root.voiceState === "recording"
                      loops: Animation.Infinite
                      NumberAnimation { to: 0.2; duration: 550; easing.type: Easing.InOutQuad }
                      NumberAnimation { to: 1.0; duration: 550; easing.type: Easing.InOutQuad }
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Grabando " + root.mmss(root.voiceSeconds) + " / " + root.mmss(root.voiceMaxSeconds)
                    color: root.contentForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Row {
                  id: recButtons
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Button {
                    text: "Cancelar"
                    bordered: true
                    foreground: root.contentForeground
                    accent: root.alertColor
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onClicked: root.cancelVoice()
                  }

                  Button {
                    text: "Detener"
                    bordered: true
                    foreground: root.accentColor
                    accent: root.accentColor
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onClicked: root.stopVoice()
                  }
                }
              }
            }

            // Mode 4: Audio Preview / Send
            Rectangle {
              id: previewBar
              width: parent.width
              height: Style.space(34)
              implicitHeight: height
              radius: Style.cornerRadius
              visible: root.voiceState === "preview" || root.voiceState === "sending"
              color: Util.alpha(root.accentColor, 0.15)
              border.color: Util.alpha(root.accentColor, 0.4)
              border.width: 1

              Item {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)

                Row {
                  anchors.left: parent.left
                  anchors.right: prevButtons.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Escuchar"
                    iconText: root.iconPlay
                    bordered: true
                    foreground: root.contentForeground
                    accent: root.accentColor
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onClicked: root.playVoiceDraft()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Listo (" + root.mmss(root.voiceSeconds) + ")"
                    color: Util.alpha(root.contentForeground, 0.75)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Row {
                  id: prevButtons
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Button {
                    text: "Descartar"
                    bordered: true
                    enabled: root.voiceState === "preview"
                    foreground: root.contentForeground
                    accent: root.accentColor
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onClicked: root.cancelVoice()
                  }

                  Button {
                    text: root.voiceState === "sending" ? "…" : "Enviar"
                    bordered: true
                    enabled: root.voiceState === "preview"
                    foreground: root.accentColor
                    accent: root.accentColor
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onClicked: root.sendVoice()
                  }
                }
              }
            }
          }
        }
      }

      // --- Read receipt overlay ---
      Rectangle {
        anchors.fill: parent
        visible: root.markReadBusy
        color: Util.alpha(Color.background, 0.7)
        z: 999

        MouseArea {
          anchors.fill: parent
          onClicked: { root.markReadPending = 0 }
        }

        Row {
          anchors.centerIn: parent
          spacing: Style.space(8)

          Text {
            id: markReadSpinner
            anchors.verticalCenter: parent.verticalCenter
            text: root.iconRefresh
            color: root.contentForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.icon

            RotationAnimator {
              target: markReadSpinner
              from: 0; to: 360
              duration: 800
              loops: Animation.Infinite
              running: root.markReadBusy
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Marcando como leído…"
            color: root.contentForeground
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}

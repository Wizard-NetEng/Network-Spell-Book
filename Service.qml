import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Owns everything off-GUI: running the catalog scan, tracking which tools are
// installed, persisting collapsed-section state, and copying a reference
// command to the clipboard.
//
// Note what is absent by design: there is no code path here that executes a
// catalogued tool. The scan resolves binaries on PATH (a stat, not a fork) and
// the only other subprocess is the clipboard helper, which reads from stdin.
Item {
  id: root

  property var settings: ({})

  // ---- exposed state -----------------------------------------------------
  property var categories: []        // [{name, blurb, tools:[...]}]
  property int total: 0
  property int installed: 0
  property bool loaded: false
  property bool scanning: false
  property string lastError: ""
  property string copyStatus: ""

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string binDir: pluginDir + "bin/"

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  readonly property bool showMissing: String(setting("showMissing", true)) !== "false"
  readonly property int rescanMinutes: Math.max(5, Math.min(720,
      parseInt(setting("rescanMinutes", 30), 10) || 30))
  readonly property bool startCollapsed: String(setting("startCollapsed", false)) === "true"

  // ---- collapsed-section state (persisted) -------------------------------
  property var collapsed: ({})
  property bool uiStateLoaded: false

  // State is read and written ONLY through bin/spellbook-state, never through
  // a FileView on a fixed path. A FileView follows symlinks on both read and
  // write, so a planted `ui-state.json` link redirects our write to another
  // file, and it has no size cap on the read. The helper opens the state
  // directory with O_NOFOLLOW|O_DIRECTORY and performs every operation
  // relative to that descriptor, so the kernel refuses a swapped path
  // atomically rather than us racing a check against an act.
  Process {
    id: stateReadProc
    command: [root.binDir + "spellbook-state", "read"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var c = ({})
        var applied = false
        try {
          var doc = JSON.parse(text || "{}")
          if (doc.ok !== false && doc.present === true) {
            var list = doc.collapsed || []
            for (var i = 0; i < list.length; i++) c[String(list[i])] = true
            applied = true
          }
        } catch (e) {
          // Unreadable state is not fatal; fall through to the default.
        }
        if (!applied && root.startCollapsed) {
          // First run: honour the manifest default rather than starting empty.
          for (var j = 0; j < root.categories.length; j++)
            c[root.categories[j].name] = true
        }
        root.collapsed = c
        root.uiStateLoaded = true
      }
    }
    onExited: function(code) {
      if (!root.uiStateLoaded) {
        root.collapsed = ({})
        root.uiStateLoaded = true
      }
    }
  }

  function isCollapsed(name) { return collapsed[name] === true }

  // QML change signals fire on REASSIGNMENT, not mutation. Copy-modify-assign,
  // never collapsed[k] = v, or the UI never rebuilds.
  function toggleSection(name) {
    var next = ({})
    for (var k in collapsed) next[k] = collapsed[k]
    if (next[name]) delete next[name]
    else next[name] = true
    collapsed = next
    persistUiState()
  }

  function setAllCollapsed(want) {
    var next = ({})
    if (want) {
      for (var i = 0; i < categories.length; i++) next[categories[i].name] = true
    }
    collapsed = next
    persistUiState()
  }

  function persistUiState() {
    if (!uiStateLoaded) return
    var list = []
    for (var k in collapsed) if (collapsed[k]) list.push(k)
    // The helper creates the directory 0700, tightens it on the open
    // descriptor, writes an O_EXCL 0600 temp file and renames it into place
    // — so there is no separate chmod step that could be retargeted by a
    // symlinked directory, and no world-readable window.
    stateWriteProc.pending = JSON.stringify({ collapsed: list })
    stateWriteProc.running = false
    stateWriteProc.stdinEnabled = true
    stateWriteProc.running = true
  }

  // Writes state via stdin. Fixed argv, no shell, no interpolation.
  Process {
    id: stateWriteProc
    command: [root.binDir + "spellbook-state", "write"]
    stdinEnabled: true
    property string pending: ""
    // stdin must be written in onStarted — the pipe is not open before that.
    onStarted: {
      if (pending.length > 0) {
        write(pending)
        pending = ""
      }
      stdinEnabled = false
    }
  }

  // ---- catalog scan ------------------------------------------------------
  // One process for the whole catalog. Never one per tool.
  Process {
    id: scanProc
    command: [root.binDir + "spellbook-scan"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var doc = JSON.parse(text || "{}")
          if (doc.ok === false) {
            root.lastError = doc.error || "scan failed"
          } else {
            root.categories = doc.categories || []
            root.total = doc.total || 0
            root.installed = doc.installed || 0
            root.lastError = ""
          }
        } catch (e) {
          root.lastError = "could not parse scan output"
        }
        root.loaded = true
        root.scanning = false
      }
    }
    onExited: function(code) {
      root.scanning = false
      if (code !== 0 && !root.loaded) {
        root.lastError = "scan helper exited " + code
        root.loaded = true
      }
    }
  }

  function scan() {
    if (scanning) return
    scanning = true
    scanProc.running = false
    scanProc.running = true
  }

  // ---- clipboard ---------------------------------------------------------
  // The command text goes over stdin, never argv: argv is world-readable in
  // /proc, and a string starting with "-" would be parsed as an option.
  Process {
    id: copyProc
    command: [root.binDir + "spellbook-copy"]
    stdinEnabled: true
    property string pending: ""
    // stdin must be written in onStarted — the pipe is not open before that.
    onStarted: {
      if (pending.length > 0) {
        write(pending)
        pending = ""
      }
      stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) root.copyStatus = "Copy failed"
      copyStatusTimer.restart()
    }
  }

  function copyCommand(text, label) {
    if (!text || text.length === 0) return
    copyProc.running = false
    copyProc.pending = String(text)
    copyProc.stdinEnabled = true
    copyProc.running = true
    copyStatus = "Copied: " + (label || text)
    copyStatusTimer.restart()
  }

  // Show a transient message without touching the clipboard. Used when an
  // action is a no-op (already installed, nothing missing) so it reports
  // honestly instead of silently doing nothing.
  function flashStatus(msg) {
    copyStatus = msg
    copyStatusTimer.restart()
  }

  Timer {
    id: copyStatusTimer
    interval: 2600
    onTriggered: root.copyStatus = ""
  }

  // ---- periodic rescan ---------------------------------------------------
  // Only ticks after the popup has been opened once, so an untouched widget
  // costs nothing.
  property bool everOpened: false

  Timer {
    id: rescanTimer
    interval: root.rescanMinutes * 60 * 1000
    repeat: true
    running: root.everOpened
    onTriggered: root.scan()
  }

  function notifyOpened() {
    if (!everOpened) {
      everOpened = true
      if (!loaded) scan()
    }
  }

  Component.onCompleted: {
    // FileView loaded itself; a Process must be started explicitly.
    stateReadProc.running = true
    scan()
  }
}

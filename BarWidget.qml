import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Release activity for the repositories you track.
//
//      19          nothing new
//      3 ●         releases in the last day
//      19 ⚠2       repositories past their own release cadence
//
// The watching is done by `bin/omarchy-github-monitor`, which reads each
// repository's releases.atom feed and writes a JSON state file. This widget
// only reads that file — it makes no network requests of its own.
//
// Left click opens the list. Middle click forces a poll.
BarWidget {
  id: root
  moduleName: "io.github.irhop.github-monitor"

  // ---- settings (shell.json layout entry, `omarchy bar set`)
  // Escaped, not literal: a private-use character does not survive every
  // tool between here and the file on disk.
  readonly property string icon: String(setting("icon", String.fromCodePoint(0xF09B)))
  readonly property bool showOverdue: setting("showOverdue", true) !== false
  readonly property bool showCount: setting("showCount", true) !== false

  // ---- state, straight off the daemon's file
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/omarchy-github-monitor/state.json"

  property var state: null
  property date now: new Date()

  readonly property var repos: state && state.repos ? state.repos : []
  readonly property int trackedCount: repos.length

  // Unseen, not recent: the dot should mean "you have not looked at this",
  // which goes quiet when you do rather than when a timer runs out.
  readonly property int newCount: {
    var count = 0
    for (var i = 0; i < repos.length; i++) if (repos[i].unseen === true) count++
    return count
  }

  readonly property int overdueCount: {
    if (!showOverdue) return 0
    var count = 0
    for (var i = 0; i < repos.length; i++) if (repos[i].overdue === true) count++
    return count
  }

  // The daemon says how long a poll may be missing before its own numbers
  // stop meaning anything; the widget does not second-guess it.
  readonly property bool stale: {
    if (!state || !state.generated_at) return true
    var generated = Date.parse(state.generated_at)
    if (isNaN(generated)) return true
    return (now.getTime() - generated) > (Number(state.stale_after_seconds) || 3600) * 1000
  }

  readonly property bool everRun: state !== null && state !== undefined

  readonly property string label: {
    if (!everRun) return "—"
    if (!showCount) return ""
    return String(newCount > 0 ? newCount : trackedCount)
  }

  readonly property string tooltip: {
    if (!everRun) return "No poll yet — run: omarchy-github-monitor bootstrap"
    if (stale) return "Feed poll has stopped — check omarchy-github-monitor.timer"
    var parts = [trackedCount + " repositories"]
    if (newCount > 0) parts.push(newCount + " not yet seen")
    if (overdueCount > 0) parts.push(overdueCount + " past their usual cadence")
    return parts.join(" · ")
  }

  function refresh() {
    now = new Date()
    stateFile.reload()
  }

  function poll() {
    pollProcess.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        root.state = JSON.parse(text())
      } catch (e) {
        root.state = null
      }
    }
    onLoadFailed: root.state = null
  }

  // Only to re-evaluate staleness and ages; the file itself is watched.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.now = new Date()
  }

  Process {
    id: pollProcess
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.irhop.github-monitor/bin/omarchy-github-monitor", "fetch", "--quiet"]
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    labelVisible: root.vertical
    hasVisualContent: true
    active: root.newCount > 0
    dimmed: root.stale || !root.everRun
    tooltipText: root.tooltip
    fixedWidth: root.vertical ? -1 : Math.ceil(content.implicitWidth + button.scaledHorizontalMargin * 2)

    onPressed: function(pressedButton) {
      if (pressedButton === Qt.MiddleButton) root.poll()
      else root.togglePanel()
    }

    // A horizontal bar gets the whole readout. A narrow vertical bar gets the
    // icon alone, with the rest in the tooltip and the panel.
    Row {
      id: content
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.icon
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        color: button.active ? button.activeColor : button.foreground
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: root.label !== ""
        text: root.label
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        color: button.active ? button.activeColor : button.foreground
      }

      // The dot says something shipped. It is the accent color because it is
      // news, not a problem.
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: root.newCount > 0
        text: "●"
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        color: Color.accent
      }

      // The warning says something stopped shipping, which is the one state
      // worth the urgent color.
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: root.overdueCount > 0
        text: "⚠" + root.overdueCount
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        color: button.activeColor
      }
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

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Shape contract for the bar's summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  // The bar host already registers the plugin id as an IPC target, so this
  // one takes a distinct name rather than being silently ignored.
  IpcHandler {
    target: "github-monitor"

    function refresh(): void { root.broadcast("refresh") }
    function poll(): void { root.poll() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    // Open straight to the add view, for a keybind.
    function add(): void {
      if (!panelLoader.item) return
      panelLoader.item.adding = true
      root.open()
    }
    // Open straight to one repository's notes, for a keybind or a script.
    function show(repo: string): void {
      if (!panelLoader.item) return
      panelLoader.item.selectedRepo = repo
      root.open()
    }
  }
}

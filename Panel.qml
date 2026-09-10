import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The repository list behind the bar widget.
//
// Rows are ordered by how recently each project released, so what just shipped
// is at the top and what has gone quiet sinks — the same order you would want
// when scanning for something to update.
//
// Built on KeyboardPanel (layer-shell) rather than PopupCard (xdg-popup): a
// popup window declared by a plugin widget does not map, which costs an
// afternoon to discover and nothing to avoid.
Panel {
  id: root
  moduleName: "io.github.irhop.github-monitor"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property string selectedRepo: ""

  // The add/search view. One text field serves both: a value that looks like
  // a repository is added directly, anything else is searched for.
  property bool adding: false
  onAddingChanged: if (adding) Qt.callLater(function () { queryField.forceActiveFocus() })
  property string query: ""
  property var results: []
  property string notice: ""
  property bool busy: false

  readonly property string monitorBin:
    Qt.resolvedUrl("bin/omarchy-github-monitor").toString().replace("file://", "")

  // A child that installs nothing still has no business inheriting whatever
  // environment the compositor was started with.
  function monitorEnvironment() {
    var env = { "PATH": "/usr/local/bin:/usr/bin:/bin" }
    var keep = ["HOME", "USER", "LOGNAME", "XDG_CONFIG_HOME", "XDG_STATE_HOME"]
    for (var i = 0; i < keep.length; i++) {
      var value = Quickshell.env(keep[i])
      if (value) env[keep[i]] = value
    }
    return env
  }

  // `owner/repo` or a github.com URL is unambiguous, so it is added rather
  // than searched for. Everything else is a search query.
  function looksLikeRepo(value) {
    var trimmed = value.trim()
    if (trimmed.indexOf("github.com/") >= 0) return true
    return /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(trimmed)
  }

  function submitQuery() {
    var value = query.trim()
    if (value === "" || busy) return
    notice = ""
    busy = true
    if (looksLikeRepo(value)) {
      addProcess.command = [monitorBin, "add", "--json", value]
      addProcess.running = true
    } else {
      // On Enter, never per keystroke: search allows ten requests a minute.
      searchProcess.command = [monitorBin, "search", "--json", "-n", "12", value]
      searchProcess.running = true
    }
  }

  function addRepo(repo) {
    if (busy) return
    busy = true
    notice = ""
    addProcess.command = [monitorBin, "add", "--json", repo]
    addProcess.running = true
  }

  function runBootstrap() {
    if (busy) return
    busy = true
    notice = ""
    bootstrapProcess.running = true
  }

  Process {
    id: bootstrapProcess
    clearEnvironment: true
    // XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are how `systemctl --user`
    // reaches the session manager. Without them the timer install fails.
    environment: {
      var env = root.monitorEnvironment()
      var keep = ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]
      for (var i = 0; i < keep.length; i++) {
        var value = Quickshell.env(keep[i])
        if (value) env[keep[i]] = value
      }
      return env
    }
    command: [root.monitorBin, "bootstrap"]
    onExited: function (exitCode) {
      root.busy = false
      root.notice = exitCode === 0
        ? "Polling every 15 minutes."
        : "Could not install the timer. Run `omarchy-github-monitor bootstrap` to see why."
      if (root.hostWidget) root.hostWidget.refresh()
    }
  }

  function closeAdd() {
    adding = false
    query = ""
    results = []
    notice = ""
  }

  Process {
    id: searchProcess
    clearEnvironment: true
    environment: root.monitorEnvironment()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        try {
          var payload = JSON.parse(text)
          if (payload.error) {
            root.notice = payload.error
            root.results = []
          } else {
            root.results = payload.items || []
            root.notice = root.results.length === 0 ? "No repositories found." : ""
          }
        } catch (e) {
          root.notice = "Search failed."
          root.results = []
        }
      }
    }
  }

  Process {
    id: addProcess
    clearEnvironment: true
    environment: root.monitorEnvironment()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        try {
          var payload = JSON.parse(text)
          if (payload.error) {
            root.notice = payload.error
          } else {
            root.notice = payload.already ? payload.added + " is already tracked."
                                          : "Added " + payload.added
            root.query = ""
            root.results = []
            if (root.hostWidget) root.hostWidget.refresh()
          }
        } catch (e) {
          root.notice = "Could not add that repository."
        }
      }
    }
  }

  readonly property var repos: hostWidget ? hostWidget.repos : []
  // No state file at all means the daemon has never run here, which is a
  // different situation from a poll that has stopped, and needs different
  // words: nothing is broken, nothing has been set up.
  readonly property bool everRun: hostWidget ? hostWidget.everRun : false
  readonly property bool empty: repos.length === 0
  readonly property bool stale: hostWidget ? hostWidget.stale : false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var sorted: {
    var rows = repos.slice()
    rows.sort(function (a, b) {
      var left = a.days_since_release
      var right = b.days_since_release
      if (left === null || left === undefined) return 1
      if (right === null || right === undefined) return -1
      return left - right
    })
    return rows
  }

  readonly property var selected: {
    for (var i = 0; i < repos.length; i++) if (repos[i].repo === selectedRepo) return repos[i]
    return null
  }

  function isNew(entry) {
    return entry.unseen === true
  }

  function markSeen() {
    seenProcess.command = [monitorBin, "seen"]
    seenProcess.running = true
  }

  function togglePrereleases(entry) {
    if (!entry || busy) return
    busy = true
    // Only two states from the panel: following prereleases or not. The
    // third, "whatever the global setting says", stays a CLI concern.
    preProcess.command = entry.prereleases_included
      ? [monitorBin, "pre", "--off", entry.repo]
      : [monitorBin, "pre", entry.repo]
    preProcess.running = true
  }

  Process {
    id: preProcess
    clearEnvironment: true
    environment: root.monitorEnvironment()
    onExited: {
      root.busy = false
      if (root.hostWidget) root.hostWidget.refresh()
    }
  }

  function toggleMute(entry) {
    if (!entry || busy) return
    busy = true
    muteProcess.command = entry.overdue_muted
      ? [monitorBin, "mute", "--unmute", entry.repo]
      : [monitorBin, "mute", entry.repo]
    muteProcess.running = true
  }

  Process {
    id: seenProcess
    clearEnvironment: true
    environment: root.monitorEnvironment()
    onExited: if (root.hostWidget) root.hostWidget.refresh()
  }

  Process {
    id: muteProcess
    clearEnvironment: true
    environment: root.monitorEnvironment()
    onExited: {
      root.busy = false
      if (root.hostWidget) root.hostWidget.refresh()
    }
  }

  function cadenceText(entry) {
    if (entry.error) return entry.error
    var avg = entry.avg_days_between_releases
    if (avg === null || avg === undefined) return "no cadence yet"
    // A project that ships several times a day has no useful hour figure,
    // and rounding one produces "usually every 0h".
    if (avg * 24 < 1) return "several a day"
    if (avg < 1) return "usually every " + Math.round(avg * 24) + "h"
    return "usually every " + (avg < 10 ? avg.toFixed(1) : Math.round(avg)) + "d"
  }

  function openInBrowser(url) {
    if (!url) return
    Quickshell.execDetached(["xdg-open", url])
  }

  function repoUrl(entry) {
    return entry ? "https://github.com/" + entry.repo : ""
  }

  // The release page when the feed gave one, the releases index otherwise —
  // a row whose feed errored still has somewhere sensible to go.
  function releaseUrl(entry) {
    if (!entry) return ""
    return entry.url ? entry.url : repoUrl(entry) + "/releases"
  }

  function copyToClipboard(value, description) {
    if (!value) return
    copyProcess.command = ["wl-copy", "--", value]
    copyProcess.running = true
    toast = "Copied " + description
    toastTimer.restart()
  }

  // Confirmation for a copy, which is otherwise invisible.
  property string toast: ""

  Timer {
    id: toastTimer
    interval: 2500
    onTriggered: root.toast = ""
  }

  Process {
    id: copyProcess
    clearEnvironment: true
    // wl-copy talks to the compositor, so it needs the display socket the
    // daemon environment deliberately drops.
    environment: {
      var env = root.monitorEnvironment()
      var keep = ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"]
      for (var i = 0; i < keep.length; i++) {
        var value = Quickshell.env(keep[i])
        if (value) env[keep[i]] = value
      }
      return env
    }
  }

  onOpenedChanged: {
    if (!opened) {
      selectedRepo = ""
      closeAdd()
      // Closing is the moment you have finished looking, so the dots clear
      // then rather than the instant the list appears.
      markSeen()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Without this the layer surface never takes keyboard focus, and the
    // query field silently ignores every keystroke.
    focusTarget: root.adding ? queryField : null
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(Style.space(400), Style.space(620))

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.space(8)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      PanelSectionHeader {
        Layout.fillWidth: true
        foreground: root.foreground
        text: root.adding ? "Add a repository"
                          : (root.selected ? root.selected.repo : "Tracked repositories")
      }

      PanelActionButton {
        visible: !root.adding && root.selected === null
        iconText: "\uf067"
        tooltipText: "Add a repository"
        foreground: root.foreground
        onClicked: {
          root.adding = true
          Qt.callLater(function () { queryField.forceActiveFocus() })
        }
      }
    }

    // ---- add and search
    ColumnLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: root.adding
      spacing: Style.space(8)

      TextField {
        id: queryField
        Layout.fillWidth: true
        foreground: root.foreground
        placeholderText: "owner/repo, a github.com URL, or words to search for"
        text: root.query
        enabled: !root.busy
        onTextChanged: root.query = text
        // Enter, never per keystroke: search allows ten requests a minute.
        onAccepted: root.submitQuery()
        Keys.onEscapePressed: root.closeAdd()
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        visible: root.notice !== "" || root.busy
        text: root.busy ? "working…" : root.notice
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: root.dim
      }

      ListView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.space(2)
        model: root.results

        delegate: Rectangle {
          required property var modelData
          width: ListView.view.width
          height: Style.space(34)
          radius: Style.space(4)
          color: resultMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
                                           : "transparent"

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: modelData.repo + (modelData.tracked ? "  (tracked)" : "")
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: modelData.tracked ? root.dim : root.foreground
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: modelData.description || ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                color: root.dim
              }
            }

            Text {
              textFormat: Text.PlainText
              text: modelData.stars >= 1000 ? Math.round(modelData.stars / 100) / 10 + "k★"
                                            : modelData.stars + "★"
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: root.dim
            }
          }

          MouseArea {
            id: resultMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: !modelData.tracked && !root.busy
            onClicked: root.addRepo(modelData.repo)
          }
        }
      }
    }

    // ---- release notes for the selected row
    Loader {
      Layout.fillWidth: true
      Layout.fillHeight: true
      active: root.selected !== null && !root.adding
      visible: active

      sourceComponent: Item {
        Flickable {
          anchors.fill: parent
          contentHeight: notes.implicitHeight
          clip: true

          Column {
            width: parent.width
            spacing: Style.space(6)

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: (root.selected.tag || "") + "  ·  " + (root.selected.age || "")
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: root.foreground
              }

              PanelActionButton {
                iconText: "\uf0c1"
                tooltipText: "Open the release on GitHub"
                foreground: root.foreground
                onClicked: root.openInBrowser(root.releaseUrl(root.selected))
              }

              PanelActionButton {
                iconText: "\uf09b"
                tooltipText: "Open the repository on GitHub"
                foreground: root.foreground
                onClicked: root.openInBrowser(root.repoUrl(root.selected))
              }

              PanelActionButton {
                iconText: "\uf0c5"
                tooltipText: "Copy the tag"
                foreground: root.foreground
                onClicked: root.copyToClipboard(root.selected.tag, "tag " + root.selected.tag)
              }

              PanelActionButton {
                iconText: "\uf0c3"
                tooltipText: root.selected.prereleases_included
                  ? "Stable releases only"
                  : "Follow prereleases too"
                foreground: root.selected.prereleases_included ? Color.accent : root.dim
                onClicked: root.togglePrereleases(root.selected)
              }

              PanelActionButton {
                iconText: root.selected.overdue_muted ? "\uf1f6" : "\uf0f3"
                tooltipText: root.selected.overdue_muted
                  ? "Warn again when this one goes quiet"
                  : "Stop warning when this one goes quiet"
                foreground: root.selected.overdue_muted ? root.dim : root.foreground
                onClicked: root.toggleMute(root.selected)
              }

              PanelActionButton {
                iconText: "\uf0ac"
                tooltipText: "Copy the release link"
                foreground: root.foreground
                onClicked: root.copyToClipboard(root.releaseUrl(root.selected), "release link")
              }
            }

            Text {
              id: notes
              width: parent.width
              // Plain text, never RichText: these notes are written by third
              // parties and the daemon has already flattened the markup.
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.selected.notes || "No release notes."
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: root.dim
            }
          }
        }
      }
    }

    // ---- first run
    ColumnLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: root.empty && !root.adding && root.selected === null
      spacing: Style.space(10)

      Item { Layout.fillHeight: true }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: root.everRun
          ? "Nothing tracked yet."
          : "Nothing tracked yet, and no poll has run."
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        color: root.foreground
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: "Add a repository with +, or search for one by name.\nNo GitHub account needed."
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: root.dim
      }

      Button {
        Layout.alignment: Qt.AlignHCenter
        visible: !root.everRun
        text: root.busy ? "Setting up…" : "Check every 15 minutes"
        enabled: !root.busy
        // Installing a user timer is a decision, so it happens on a click and
        // never as a side effect of enabling the plugin.
        onClicked: root.runBootstrap()
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        visible: !root.everRun
        text: "Installs a systemd user timer. Nothing was installed when you enabled this."
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: root.dim
      }

      Item { Layout.fillHeight: true }
    }

    // ---- the list
    ListView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: root.selected === null && !root.adding && !root.empty
      clip: true
      spacing: Style.space(2)
      model: root.sorted

      delegate: Rectangle {
        required property var modelData
        width: ListView.view.width
        height: Style.space(34)
        radius: Style.space(4)
        color: rowMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
                                      : "transparent"

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: modelData.overdue ? "⚠" : (root.isNew(modelData) ? "●" : "")
            width: Style.space(14)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: modelData.overdue ? (root.bar ? root.bar.urgent : Color.urgent) : Color.accent
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: modelData.repo
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: modelData.error ? root.dim : root.foreground
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: (modelData.tag || "—")
                + (modelData.prerelease ? "  (prerelease)" : "")
                + "  ·  " + root.cadenceText(modelData)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: root.dim
            }
          }

          Text {
            textFormat: Text.PlainText
            text: modelData.age || ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: root.dim
          }
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton
          onClicked: function (mouse) {
            if (mouse.button === Qt.MiddleButton) root.openInBrowser(modelData.url)
            else root.selectedRepo = modelData.repo
          }
        }
      }
    }

    // ---- footer
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: root.dim
        // Nothing about the poll needs a token, so there is nothing to say
        // when one is absent. The line is for real trouble only.
        text: {
          if (root.toast !== "") return root.toast
          if (root.notice !== "" && !root.adding) return root.notice
          if (!root.everRun) return ""
          if (root.stale) return "poll has stopped — check omarchy-github-monitor.timer"
          if (root.selected === null && !root.adding) return "click a row for notes · middle click opens GitHub"
          return ""
        }
      }

      // PanelActionButton is icon-only, which suits a footer that should not
      // compete with the list for attention.
      PanelActionButton {
        visible: root.selected !== null
        iconText: ""
        tooltipText: "Back to the list"
        foreground: root.foreground
        onClicked: { if (root.adding) root.closeAdd(); else root.selectedRepo = "" }
      }

      PanelActionButton {
        iconText: "󰑐"
        tooltipText: "Poll the feeds now"
        foreground: root.foreground
        onClicked: if (root.hostWidget) root.hostWidget.poll()
      }
    }
  }
  }
}

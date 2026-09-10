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
  readonly property bool stale: hostWidget ? hostWidget.stale : false
  readonly property bool authenticated: hostWidget && hostWidget.state
    ? hostWidget.state.authenticated === true : false
  readonly property int newWindowHours: hostWidget ? hostWidget.newWindowHours : 24

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
    var days = entry.days_since_release
    return days !== null && days !== undefined && days * 24 <= newWindowHours
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

  onOpenedChanged: if (!opened) { selectedRepo = ""; closeAdd() }

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

            Text {
              textFormat: Text.PlainText
              text: (root.selected.tag || "") + "  ·  " + (root.selected.age || "")
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.foreground
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

    // ---- the list
    ListView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: root.selected === null && !root.adding
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
              text: (modelData.tag || "—") + "  ·  " + root.cadenceText(modelData)
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
        // A statement of fact, not a request. There is nothing to click and
        // nothing is broken; two enrichment fields are simply absent.
        text: root.stale
          ? "poll has stopped — check omarchy-github-monitor.timer"
          : (root.authenticated ? "" : "unauthenticated — commits since tag unavailable")
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

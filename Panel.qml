import QtQuick
import QtQuick.Layouts
import Quickshell
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

  onOpenedChanged: if (!opened) selectedRepo = ""

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(Style.space(400), Style.space(620))

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.space(8)

    PanelSectionHeader {
      Layout.fillWidth: true
      text: root.selected ? root.selected.repo : "Tracked repositories"
    }

    // ---- release notes for the selected row
    Loader {
      Layout.fillWidth: true
      Layout.fillHeight: true
      active: root.selected !== null
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
      visible: root.selected === null
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
        onClicked: root.selectedRepo = ""
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

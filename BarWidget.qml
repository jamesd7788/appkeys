import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// appkeys' bar widget: one button per workspace, labelled with the apps on it
// and their caps keys instead of a number. The app <-> key matching lives in the
// Hyprland module (hypr/appkeys.lua); this asks it via `hyprctl repl` whenever
// windows open, close or move.
BarWidget {
  id: root
  moduleName: "io.github.jamesd7788.appkeys"

  property var spaces: []
  property bool moduleMissing: false

  readonly property string labelMode: (settings && settings.labels) || "Key and name"
  readonly property int maxName: (settings && settings.maxNameLength) || 14
  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  function shorten(name) {
    return name.length > root.maxName ? name.slice(0, root.maxName - 1) + "…" : name
  }

  function appLabel(app) {
    var key = app.key ? app.key.toUpperCase() : ""
    if (root.labelMode === "Key") return key || "·"
    if (root.labelMode === "Name" || !key) return root.shorten(app.name)
    return key + " " + root.shorten(app.name)
  }

  function spaceLabel(space) {
    var tiled = space.apps.filter(function (a) { return !a.floating })
    var apps = tiled.length ? tiled : space.apps
    return apps.map(root.appLabel).join(" + ")
  }

  function spaceTooltip(space) {
    return space.apps.map(function (a) {
      return (a.key ? "caps+" + a.key + "  " : "") + a.name
    }).join("\n")
  }

  function parse(text) {
    var trimmed = String(text || "").trim()
    if (trimmed.charAt(0) !== "[") {
      // The Hyprland module isn't loaded: install.sh hasn't run.
      root.moduleMissing = true
      root.spaces = []
      return
    }
    try {
      root.spaces = JSON.parse(trimmed)
      root.moduleMissing = false
    } catch (e) {
      root.spaces = []
    }
  }

  function refresh() {
    if (query.running) refreshAgain = true
    else query.running = true
  }
  property bool refreshAgain: false

  Process {
    id: query
    command: ["hyprctl", "repl", "return appkeys and appkeys.labels() or 'missing'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
    onExited: if (root.refreshAgain) { root.refreshAgain = false; query.running = true }
  }

  Timer {
    id: debounce
    interval: 120
    onTriggered: root.refresh()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      switch (String(event.name)) {
      case "openwindow":
      case "closewindow":
      case "movewindowv2":
      case "createworkspacev2":
      case "destroyworkspacev2":
      case "changefloatingmode":
      case "configreloaded":
        debounce.restart()
      }
    }
  }

  Component.onCompleted: refresh()

  implicitWidth: row.implicitWidth + trailingGap
  implicitHeight: row.implicitHeight

  GridLayout {
    id: row
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.spaces.length + (missingHint.visible ? 1 : 0))
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.spaces

      WidgetButton {
        required property var modelData

        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData.id

        bar: root.bar
        text: root.vertical ? (modelData.apps[0].key ? modelData.apps[0].key.toUpperCase() : String(modelData.id)) : root.spaceLabel(modelData)
        tooltipText: root.spaceTooltip(modelData)
        opacity: focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedHeight: root.barSize
        onPressed: function () {
          if (root.bar) root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + modelData.id + "\" })"))
        }
      }
    }

    WidgetButton {
      id: missingHint
      visible: root.moduleMissing
      bar: root.bar
      text: "appkeys: run install.sh"
      tooltipText: "The Hyprland half of appkeys isn't loaded. Run install.sh from the plugin folder."
      dimmed: true
      fixedHeight: root.barSize
    }
  }
}

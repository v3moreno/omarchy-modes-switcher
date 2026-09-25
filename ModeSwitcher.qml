import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "engine/state.js" as State
import "engine/dropin.js" as Dropin

BarWidget {
  id: root
  moduleName: "omarchy-modes.switcher"

  readonly property string stateDirectory: Quickshell.env("HOME") + "/.local/state/omarchy-modes"
  readonly property string statePath: stateDirectory + "/state.json"
  readonly property string dropinDirectory: Quickshell.env("HOME") + "/.local/state/omarchy/toggles/hypr"
  readonly property string dropinPath: dropinDirectory + "/omarchy-modes.lua"
  readonly property int hyprctlTimeoutMs: 5000
  readonly property var modes: ["floating", "dwindle", "master", "scrolling"]
  // Manifest defaults are descriptive only. Accept only actual booleans from
  // the inline shell.json entry; malformed user values use the safe defaults.
  readonly property bool enableKeybinds: setting("enableKeybinds", false) === true

  property var modeState: State.defaultState()
  property bool stateLoaded: false
  property string stateError: ""
  property bool menuOpen: false
  property bool opened: false
  property bool applying: false
  property string applyPhase: "idle"
  property string applyError: ""
  property string applyingWorkspaceId: ""
  property var pendingState: null
  property var sweepAddresses: []
  property int sweepIndex: 0
  property var hyprctlContinuation: null
  property string hyprctlDescription: ""
  property int menuCursor: 0
  property bool dropinMissing: false
  property bool dropinNeedsReload: false

  // This is a live mirror maintained by Quickshell's Hyprland IPC integration.
  // It changes on workspace events; no polling is involved.
  readonly property var currentWorkspace: Hyprland.focusedWorkspace
  readonly property string currentWorkspaceId: workspaceIdFromWorkspace(currentWorkspace)
  readonly property string currentMode: modeForWorkspace(currentWorkspaceId)
  readonly property string currentModeLabel: modeLabel(currentMode)

  function validWorkspaceId(value) {
    return typeof value === "string" && /^(?:0|[1-9][0-9]*)$/.test(value)
  }

  function validAddress(value) {
    return typeof value === "string" && /^0x[0-9a-fA-F]+$/.test(value)
  }

  function workspaceIdFromWorkspace(workspace) {
    if (!workspace) return ""
    var name = String(workspace.name || "")
    if (validWorkspaceId(name)) return name
    var id = Number(workspace.id)
    return isFinite(id) && Math.floor(id) === id && id >= 0 ? String(id) : ""
  }

  function workspaceIdFromClient(client) {
    if (!client || !client.workspace) return ""
    var name = String(client.workspace.name || "")
    if (validWorkspaceId(name)) return name
    var id = Number(client.workspace.id)
    return isFinite(id) && Math.floor(id) === id && id >= 0 ? String(id) : ""
  }

  function fallbackModeForCurrentWorkspace() {
    // The state file becomes authoritative after the first choice. Until then,
    // reflect Hyprland's live tiled layout when it is one of the supported modes.
    var raw = currentWorkspace && currentWorkspace.lastIpcObject
      ? String(currentWorkspace.lastIpcObject.tiledLayout || "") : ""
    return modes.indexOf(raw) !== -1 && raw !== "floating" ? raw : "dwindle"
  }

  function modeForWorkspace(workspaceId) {
    if (validWorkspaceId(workspaceId) && modeState && modeState.modes
        && State.isMode(modeState.modes[workspaceId])) {
      return modeState.modes[workspaceId]
    }
    return fallbackModeForCurrentWorkspace()
  }

  function modeLabel(mode) {
    if (mode === "floating") return "Floating"
    if (mode === "master") return "Master"
    if (mode === "scrolling") return "Scrolling"
    return "Dwindle"
  }

  function modeGlyph(mode) {
    if (mode === "floating") return "󰉈"
    if (mode === "master") return "󰕮"
    if (mode === "scrolling") return "󰕰"
    return "󰕭"
  }

  function open() {
    if (applying) return
    menuCursor = Math.max(0, modes.indexOf(currentMode))
    menuOpen = true
    opened = true
  }

  function close() {
    menuOpen = false
    opened = false
  }

  function toggle() {
    if (menuOpen) close()
    else open()
  }

  function loadState(text) {
    var result = State.readState(text)
    stateLoaded = true
    stateError = result.ok ? "" : result.error
    if (result.ok) modeState = result.state
    reconcileDropin()
  }

  // Widget teardown removes the drop-in, so a fresh instance rewrites it from
  // persisted state — otherwise a shell restart would silently drop the rules.
  // The reload is deferred to onSaved; FileView writes are async.
  function reconcileDropin() {
    if (!stateLoaded || !dropinMissing) return
    if (Object.keys(modeState.modes).length === 0) return
    dropinMissing = false
    dropinNeedsReload = true
    try {
      dropinFile.setText(Dropin.generateDropin(modeState, {
        enableKeybinds: root.enableKeybinds
      }))
    } catch (error) {
      dropinNeedsReload = false
    }
  }

  function failApply(message) {
    applying = false
    applyPhase = "failed"
    applyError = String(message || "Mode change failed.")
    hyprctlWatchdog.stop()
    hyprctlContinuation = null
  }

  function cycleMode() {
    if (applying) return "busy"
    if (!stateLoaded) return "not-ready"
    var index = modes.indexOf(currentMode)
    if (index < 0) index = 0
    return startApply(modes[(index + 1) % modes.length])
  }

  function setMode(mode) {
    if (typeof mode !== "string" || !State.isMode(mode)) return "invalid-mode"
    return startApply(mode)
  }

  function startApply(mode) {
    var workspaceId = currentWorkspaceId
    var next

    if (applying) return "busy"
    if (!stateLoaded) return "not-ready"
    if (stateError !== "") {
      failApply("state.json is invalid; refusing to overwrite it.")
      return "invalid-state"
    }
    if (!validWorkspaceId(workspaceId) || !State.isMode(mode)) {
      failApply("The active workspace cannot be represented safely.")
      return "invalid-mode"
    }

    next = JSON.parse(JSON.stringify(modeState))
    next.modes[workspaceId] = mode
    try {
      // Keep the pure module as the validation authority shared with Node.
      State.validateState(next)
      pendingState = next
    } catch (error) {
      failApply(error.message)
      return "invalid-state"
    }

    applying = true
    applyError = ""
    applyingWorkspaceId = workspaceId
    close()
    applyPhase = "ensuring-directories"
    ensureDirectories.command = ["mkdir", "-p", stateDirectory, dropinDirectory]
    ensureDirectories.running = true
    return "started"
  }

  function writeState() {
    try {
      applyPhase = "writing-state"
      stateFile.setText(State.writeState(pendingState))
    } catch (error) {
      failApply("Could not write state.json: " + error.message)
    }
  }

  function writeDropin() {
    try {
      // Do not assemble Lua here. The shared pure generator owns the fixed
      // vocabulary and rejects anything else before serialisation.
      State.validateState(pendingState)
      applyPhase = "writing-dropin"
      dropinFile.setText(Dropin.generateDropin(pendingState, {
        enableKeybinds: root.enableKeybinds
      }))
    } catch (error) {
      failApply("Could not generate the drop-in: " + error.message)
    }
  }

  function startHyprctl(args, description, continuation) {
    if (!applying || hyprctlProcess.running) {
      failApply("Could not start hyprctl " + description + ".")
      return
    }
    hyprctlDescription = description
    hyprctlContinuation = continuation
    hyprctlProcess.command = ["hyprctl"].concat(args)
    hyprctlProcess.running = true
    hyprctlWatchdog.restart()
  }

  function parseJson(text, description) {
    try {
      return JSON.parse(text)
    } catch (error) {
      failApply("hyprctl " + description + " did not return JSON: " + error.message)
      return null
    }
  }

  function expectedWorkspaceIds() {
    return Object.keys(pendingState.modes).sort(function(left, right) {
      return left.length === right.length ? (left < right ? -1 : (left > right ? 1 : 0))
        : left.length - right.length
    })
  }

  function workspaceIdFromRule(rule) {
    if (!rule || typeof rule !== "object") return ""
    var values = [rule.workspaceString, rule.workspace, rule.workspaceName, rule.name]
    for (var i = 0; i < values.length; i++) {
      if (typeof values[i] === "number" && isFinite(values[i])
          && Math.floor(values[i]) === values[i] && values[i] >= 0) return String(values[i])
      if (validWorkspaceId(values[i])) return values[i]
    }
    return ""
  }

  function verifyWorkspaceRules(rules) {
    if (!Array.isArray(rules)) {
      failApply("hyprctl -j workspacerules did not return an array.")
      return false
    }
    var found = ({})
    for (var i = 0; i < rules.length; i++) {
      var workspaceId = workspaceIdFromRule(rules[i])
      if (workspaceId !== "" && rules[i].enabled !== false) found[workspaceId] = true
    }
    var expected = expectedWorkspaceIds()
    var missing = []
    for (var j = 0; j < expected.length; j++) {
      if (!found[expected[j]]) missing.push(expected[j])
    }
    if (missing.length > 0) {
      failApply("Hyprland did not report workspace rule(s) after reload: " + missing.join(", ") + ".")
      return false
    }
    return true
  }

  function verifyThenSweep(rawRules) {
    var rules = parseJson(rawRules, "-j workspacerules")
    if (!rules || !verifyWorkspaceRules(rules)) return
    startHyprctl(["-j", "clients"], "-j clients", beginSweep)
  }

  function beginSweep(rawClients) {
    var clients = parseJson(rawClients, "-j clients")
    if (!clients || !Array.isArray(clients)) {
      if (clients) failApply("hyprctl -j clients did not return an array.")
      return
    }
    sweepAddresses = []
    for (var i = 0; i < clients.length; i++) {
      if (clients[i] && validAddress(clients[i].address)
          && workspaceIdFromClient(clients[i]) === applyingWorkspaceId) {
        sweepAddresses.push(clients[i].address)
      }
    }
    sweepIndex = 0
    sweepNextWindow()
  }

  function floatCommand(address, floating) {
    if (!validAddress(address)) return ""
    return "hl.dsp.window.float({ window = \"address:" + address + "\", action = \""
      + (floating ? "enable" : "disable") + "\" })"
  }

  function sweepNextWindow() {
    if (!applying) return
    if (sweepIndex >= sweepAddresses.length) {
      modeState = pendingState
      applying = false
      applyPhase = "idle"
      return
    }
    startHyprctl(["-j", "clients"], "-j clients", checkCurrentSweepWindow)
  }

  function checkCurrentSweepWindow(rawClients) {
    var clients = parseJson(rawClients, "-j clients")
    var address = sweepAddresses[sweepIndex]
    if (!clients || !Array.isArray(clients)) {
      if (clients) failApply("hyprctl -j clients did not return an array.")
      return
    }
    var client = null
    for (var i = 0; i < clients.length; i++) {
      if (clients[i] && clients[i].address === address) {
        client = clients[i]
        break
      }
    }
    if (!client || workspaceIdFromClient(client) !== applyingWorkspaceId) {
      sweepIndex += 1
      sweepNextWindow()
      return
    }
    var command = floatCommand(address, pendingState.modes[applyingWorkspaceId] === "floating")
    if (command === "") {
      failApply("Refusing to dispatch to an invalid window address.")
      return
    }
    startHyprctl(["dispatch", command], "dispatch window float", function() {
      sweepIndex += 1
      sweepNextWindow()
    })
  }

  implicitWidth: triggerRow.implicitWidth
  implicitHeight: triggerRow.implicitHeight

  IpcHandler {
    target: "omarchy-modes.switcher"

    function cycle(): string { return root.cycleMode() }
    function setMode(mode: string): string { return root.setMode(mode) }
  }

  Row {
    id: triggerRow
    anchors.fill: parent
    spacing: Style.space(1)

    BarIconButton {
      id: modeButton
      bar: root.bar
      text: root.modeGlyph(root.currentMode)
      tooltipText: root.currentModeLabel
      active: root.menuOpen || root.applying
      onPressed: root.toggle()
    }

    WidgetButton {
      id: modeLabelButton
      bar: root.bar
      text: root.currentModeLabel + " 󰅂"
      tooltipText: root.applyError !== "" ? root.applyError : root.currentModeLabel
      horizontalMargin: Style.spaceReal(3)
      active: root.menuOpen || root.applying
      onPressed: root.toggle()
    }
  }

  KeyboardPanel {
    id: modeMenu
    anchorItem: modeButton
    owner: root
    bar: root.bar
    open: root.menuOpen
    focusTarget: menuKeys
    contentWidth: modeMenu.fittedContentWidth(Style.space(220))
    contentHeight: modeMenu.fittedContentHeight(menuRows.implicitHeight)

    PanelKeyCatcher {
      id: menuKeys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        root.menuCursor = Math.max(0, Math.min(root.modes.length - 1, root.menuCursor + dy))
      }
      onActivateRequested: root.startApply(root.modes[root.menuCursor])
      onCloseRequested: root.close()

      Column {
        id: menuRows
        width: parent.width
        spacing: Style.spacing.labelGap

        Repeater {
          model: root.modes

          Rectangle {
            required property string modelData
            required property int index
            readonly property bool activeMode: root.currentMode === modelData
            readonly property bool cursorMode: root.menuCursor === index
            width: menuRows.width
            height: Style.spacing.popupRowHeight
            radius: Math.max(1, Style.cornerRadius - Style.spacing.hairline)
            color: cursorMode
              ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"
            opacity: root.applying ? 0.55 : 1

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.verticalCenter: parent.verticalCenter
              text: parent.activeMode ? "●" : " "
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.controlPaddingX + Style.space(18)
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.controlPaddingX
              anchors.verticalCenter: parent.verticalCenter
              text: root.modeLabel(parent.modelData)
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            MouseArea {
              anchors.fill: parent
              enabled: !root.applying
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.menuCursor = parent.index
              onClicked: root.startApply(parent.modelData)
            }
          }
        }
      }
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState(null)
    onFileChanged: reload()
    onSaved: if (root.applying && root.applyPhase === "writing-state") root.writeDropin()
    onSaveFailed: root.failApply("Could not save state.json.")
  }

  FileView {
    id: dropinFile
    path: root.dropinPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoadFailed: {
      root.dropinMissing = true
      root.reconcileDropin()
    }
    onFileChanged: reload()
    onSaved: {
      if (root.dropinNeedsReload) {
        root.dropinNeedsReload = false
        Quickshell.execDetached(["hyprctl", "reload"])
      }
      if (root.applying && root.applyPhase === "writing-dropin") {
        root.applyPhase = "reloading"
        root.startHyprctl(["reload"], "reload", function() {
          root.applyPhase = "verifying"
          root.startHyprctl(["-j", "workspacerules"], "-j workspacerules", root.verifyThenSweep)
        })
      }
    }
    onSaveFailed: {
      root.dropinNeedsReload = false
      root.failApply("Could not save the generated drop-in.")
    }
  }

  Process {
    id: ensureDirectories
    onExited: function(exitCode) {
      if (!root.applying || root.applyPhase !== "ensuring-directories") return
      if (exitCode !== 0) root.failApply("Could not create the state directories.")
      else root.writeState()
    }
  }

  Process {
    id: hyprctlProcess
    stdout: StdioCollector { id: hyprctlStdout; waitForEnd: true }
    stderr: StdioCollector { id: hyprctlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      hyprctlWatchdog.stop()
      if (!root.applying) return
      var continuation = root.hyprctlContinuation
      root.hyprctlContinuation = null
      if (exitCode !== 0) {
        root.failApply("hyprctl " + root.hyprctlDescription + " failed" +
          (hyprctlStderr.text ? ": " + String(hyprctlStderr.text).trim() : "."))
        return
      }
      if (continuation) continuation(String(hyprctlStdout.text || ""))
    }
  }

  Timer {
    id: hyprctlWatchdog
    interval: root.hyprctlTimeoutMs
    repeat: false
    onTriggered: {
      if (!hyprctlProcess.running || !root.applying) return
      hyprctlProcess.signal(9)
      root.failApply("hyprctl " + root.hyprctlDescription + " did not answer within "
        + root.hyprctlTimeoutMs + "ms; Hyprland IPC may be wedged.")
    }
  }

  // A Process child dies with the widget tree and ids are already torn down by
  // destruction time, so cleanup goes through execDetached. state.json stays —
  // it is user data, and reconcileDropin() restores the drop-in from it.
  Component.onDestruction: {
    Quickshell.execDetached(["sh", "-c",
      "rm -f -- \"$1\" && hyprctl reload >/dev/null 2>&1 || :",
      "omarchy-modes-switcher-cleanup", dropinPath])
  }
}

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "engine/state.js" as State
import "engine/dropin.js" as Dropin
import "engine/snap.js" as Snap
import "Model.js" as Model

// The view is Model.build(snap, ui) — plain rows; this file draws them and
// turns actions back into calls. ipcTarget adds open/close/toggle IPC on
// "omarchy-modes.switcher.widget"; the custom handler below keeps the
// mode/snap verbs on "omarchy-modes.switcher".
Panel {
  id: root
  moduleName: "omarchy-modes.switcher"
  ipcTarget: "omarchy-modes.switcher.widget"

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
  property bool dropinReady: false
  property bool dropinNeedsReload: false
  property string dropinExisting: ""

  // Snap assist: non-consuming SUPER+drag press/release binds land on the
  // snapDragStart/snapDragEnd IPC handlers while Omarchy's own drag bind moves
  // the window. State machine: idle -> probing -> dragging -> (armed) -> snap.
  property bool snapLoaded: false
  property bool snapEnabled: false
  property bool snapDragging: false
  property bool snapReleased: false
  property double snapPressX: 0
  property double snapPressY: 0
  property string snapWindow: ""
  property var snapMonitors: []
  property var snapAreas: ({})
  property var snapGapsIn: Snap.parseGaps("")
  property var snapGapsOut: Snap.parseGaps("")
  property string snapHoverMonitor: ""
  // The one snap the cursor currently implies — null away from every edge.
  property var snapCandidate: null
  // Release failsafe: while the dragged floating window tracks the cursor the
  // grab offset stays constant; once released the window stops following and
  // a few consecutive diverged polls stand in for a missed release bind.
  property double snapGrabX: 0
  property double snapGrabY: 0
  property int snapDiverged: 0
  property double snapLastX: -1
  property double snapLastY: -1
  property var snapContinuation: null
  property string snapDescription: ""
  property bool snapPendingWrite: false
  readonly property int snapPollMs: 40
  readonly property int snapDragTimeoutMs: 45000
  readonly property int snapDivergencePx: 60
  readonly property int snapDivergenceTicks: 3
  // Snap settings persisted in snap-assist.json. columns: 0 = auto-detect from
  // the monitor's aspect, else a fixed 2/3/4. rows: the per-column upper/lower
  // half snaps on the top/bottom edges. reach: edge proximity preset index.
  property int snapColumns: 0
  property bool snapRows: true
  property int snapReach: 1
  readonly property var snapReachScales: [0.7, 1.0, 1.5]
  readonly property real snapReachScale: snapReachScales[Math.max(0, Math.min(2, snapReach))]

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

  function modeLabel(mode) { return Model.modeLabel(mode) }
  function modeGlyph(mode) { return Model.modeGlyph(mode) }

  // Shadow Panel's open/close: opening refuses while a mode is being
  // applied and lands the cursor on the current mode's row.
  function open() {
    if (applying) return
    menuCursor = 0
    for (var i = 0; i < menuModel.length; i++) {
      if (menuModel[i].type === "mode" && menuModel[i].id === currentMode) {
        menuCursor = i
        break
      }
    }
    controller.show()
  }

  function close() {
    controller.hide()
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
  // The reload is deferred to onSaved; FileView writes are async. Regenerates
  // whenever the on-disk content differs from what the current state + flags
  // would produce (missing file, stale file, or a toggled flag).
  function reconcileDropin() {
    if (!stateLoaded || !snapLoaded || !dropinReady) return
    var expected
    try {
      expected = Dropin.generateDropin(modeState, dropinFlags())
    } catch (error) {
      console.warn("omarchy-modes.switcher: could not generate drop-in: " + error.message)
      return
    }
    if (expected === dropinExisting) return
    // Nothing to emit yet — leave the file absent rather than write a stub.
    if (Object.keys(modeState.modes).length === 0 && !snapEnabled) return
    dropinNeedsReload = true
    // Track the write synchronously — dropinExisting updates via async
    // reloads and a fast toggle-off/on would otherwise skip a needed write.
    dropinExisting = expected
    dropinFile.setText(expected)
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
      var dropinText = Dropin.generateDropin(pendingState, dropinFlags())
      root.dropinExisting = dropinText
      dropinFile.setText(dropinText)
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

  // ---- snap assist ----

  function dropinFlags() {
    return { enableKeybinds: root.enableKeybinds, snapAssist: root.snapEnabled }
  }

  function parseCursorPos(text) {
    var match = /^\s*(-?\d+)[,\s]\s*(-?\d+)/.exec(String(text))
    if (!match) return null
    return { x: Number(match[1]), y: Number(match[2]) }
  }

  // Topmost window under a global point: geometry hit-test restricted to
  // workspaces that are actually displayed on a monitor — off-workspace
  // clients keep stale geometry that can contain the cursor. Lowest
  // focusHistoryID (0 = most recently focused) wins overlaps.
  function windowAtCursor(clients, x, y, visibleWorkspaces) {
    var best = ""
    var bestFocus = -1
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      if (!c || !c.mapped || c.hidden) continue
      var ws = c.workspace ? String(c.workspace.name || "") : ""
      if (ws.indexOf("special:") === 0) continue
      if (visibleWorkspaces && visibleWorkspaces[ws] !== true) continue
      var at = c.at, size = c.size
      if (!at || !size || x < at[0] || x >= at[0] + size[0] || y < at[1] || y >= at[1] + size[1]) continue
      var focus = typeof c.focusHistoryID === "number" ? c.focusHistoryID : 2147483647
      if (best === "" || focus < bestFocus) {
        bestFocus = focus
        best = c.address
      }
    }
    return best
  }

  function snapMonitorMeta(name) {
    for (var i = 0; i < snapMonitors.length; i++) {
      if (snapMonitors[i] && snapMonitors[i].name === name) return snapMonitors[i]
    }
    return null
  }

  function runSnap(command, description, continuation) {
    if (snapProcess.running) {
      console.warn("omarchy-modes.switcher: snap step busy: " + description)
      return false
    }
    snapDescription = description
    snapContinuation = continuation
    snapProcess.command = command
    snapProcess.running = true
    snapWatchdog.restart()
    return true
  }

  function snapNotify(summary, body) {
    if (snapNotifier.running) return
    snapNotifier.command = ["notify-send", "-a", "Omarchy Modes Switcher", summary, body]
    snapNotifier.running = true
  }

  function resetSnapDrag() {
    snapDragging = false
    snapReleased = false
    snapWindow = ""
    snapMonitors = []
    snapAreas = ({})
    snapHoverMonitor = ""
    snapCandidate = null
    snapDiverged = 0
    snapContinuation = null
    snapCursorTimer.stop()
    snapTimeout.stop()
    snapWatchdog.stop()
  }

  function snapFail(message) {
    console.warn("omarchy-modes.switcher: " + message)
    snapNotify("Snap failed", message)
    resetSnapDrag()
  }

  function snapDragStart() {
    console.log("omarchy-modes.switcher: snapDragStart IPC (enabled=" + snapEnabled
      + " loaded=" + snapLoaded + " dragging=" + snapDragging + ")")
    if (!snapLoaded || !snapEnabled) return "disabled"
    if (snapDragging || snapProcess.running) return "busy"
    snapDragging = true
    snapReleased = false
    snapHoverMonitor = ""
    snapCandidate = null
    snapWindow = ""
    snapDiverged = 0
    snapTimeout.restart()
    runSnap(["sh", "-c", "hyprctl cursorpos; echo ===; hyprctl -j clients; echo ===; hyprctl -j monitors"
      + "; echo ===; hyprctl -j getoption general:gaps_in; echo ===; hyprctl -j getoption general:gaps_out"
      + "; echo ===; hyprctl -j activewindow"],
      "drag probe", onSnapProbe)
    return "probing"
  }

  function onSnapProbe(text) {
    var parts = String(text).split("\n===\n")
    if (parts.length !== 6) { snapFail("drag probe: unexpected output"); return }
    var pos = parseCursorPos(parts[0])
    var clients, monitors, gapsInOpt, gapsOutOpt, activeWin
    try {
      clients = JSON.parse(parts[1])
      monitors = JSON.parse(parts[2])
      gapsInOpt = JSON.parse(parts[3])
      gapsOutOpt = JSON.parse(parts[4])
      activeWin = JSON.parse(parts[5])
    } catch (error) {
      snapFail("drag probe did not return JSON: " + error.message)
      return
    }
    if (!pos || !Array.isArray(clients) || !Array.isArray(monitors)) {
      snapFail("drag probe returned unusable data")
      return
    }
    snapGapsIn = Snap.parseGaps(gapsInOpt && gapsInOpt.css)
    snapGapsOut = Snap.parseGaps(gapsOutOpt && gapsOutOpt.css)
    snapPressX = pos.x
    snapPressY = pos.y
    snapMonitors = monitors
    var areas = ({})
    var visible = ({})
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      if (m && m.name) {
        var area = Snap.workArea(m)
        areas[String(m.name)] = { area: area, cols: Snap.columnsFor(area.width, area.height, root.snapColumns) }
      }
      var aw = m && m.activeWorkspace
      if (aw) visible[String(aw.name || "")] = true
    }
    snapAreas = areas
    // The focused window is the dragged window in a real drag — prefer it.
    // The probe runs ~200ms late, so the cursor may already hover a different
    // window; hit-testing it would snap the wrong window. The hit-test only
    // proves the press started on a window: over any window, or near the
    // active window's rect (fast drags leave it behind). A SUPER+click on
    // wallpaper far from the focused window still arms nothing.
    var underCursor = windowAtCursor(clients, pos.x, pos.y, visible)
    snapWindow = ""
    if (activeWin && validAddress(activeWin.address)) {
      var activeClient = null
      for (var ai = 0; ai < clients.length; ai++) {
        if (clients[ai] && clients[ai].address === activeWin.address) {
          activeClient = clients[ai]
          break
        }
      }
      var near = false
      if (activeClient && activeClient.at && activeClient.size) {
        near = pos.x >= activeClient.at[0] - 600
          && pos.x <= activeClient.at[0] + activeClient.size[0] + 600
          && pos.y >= activeClient.at[1] - 600
          && pos.y <= activeClient.at[1] + activeClient.size[1] + 600
      }
      if (underCursor !== "" || near) snapWindow = activeWin.address
    }
    if (snapWindow === "") snapWindow = underCursor
    if (!validAddress(snapWindow) || snapReleased) {
      console.log("omarchy-modes.switcher: snap probe found no window at "
        + pos.x + "," + pos.y + " (released=" + snapReleased + ")")
      resetSnapDrag()
      return
    }
    console.log("omarchy-modes.switcher: snap drag armed on " + snapWindow)
    // Grab offset for the release-divergence failsafe: while a floating
    // window is dragged its position stays press-at - press-cursor.
    snapGrabX = 0
    snapGrabY = 0
    for (var c = 0; c < clients.length; c++) {
      if (clients[c] && clients[c].address === snapWindow && clients[c].at) {
        snapGrabX = clients[c].at[0] - pos.x
        snapGrabY = clients[c].at[1] - pos.y
        break
      }
    }
    snapCursorTimer.restart()
  }

  function snapCursorTick() {
    if (!snapDragging || snapProcess.running) return
    runSnap(["sh", "-c", "hyprctl cursorpos; echo ===; hyprctl -j activewindow"],
      "cursor poll", function(text) {
      var parts = String(text).split("\n===\n")
      var pos = parseCursorPos(parts[0])
      if (!pos) return
      snapLastX = pos.x
      snapLastY = pos.y
      var monitor = Snap.monitorAt(snapMonitors, pos.x, pos.y)
      snapHoverMonitor = monitor ? String(monitor.name) : ""
      // Clicks are not drags: the cursor must travel before any edge can
      // offer a snap. Candidate stays null in the workspace interior.
      snapCandidate = null
      if (monitor && Snap.dragIsArmed(snapPressX, snapPressY, pos.x, pos.y)) {
        var meta = snapAreas[snapHoverMonitor]
        if (meta) {
          snapCandidate = Snap.edgeCandidate(meta.area, meta.cols, pos.x, pos.y, snapGapsOut, snapGapsIn,
            { rows: root.snapRows, reach: root.snapReachScale })
        }
      }
      // Release failsafe: if the release bind never reaches us, the dragged
      // floating window stops tracking the cursor — three diverged polls is
      // the drop. Tiled drags do not follow the cursor, so floating-only.
      var win = null
      if (parts.length === 2) {
        try { win = JSON.parse(parts[1]) } catch (e) { win = null }
      }
      if (win && win.address === snapWindow && win.floating === true && win.at) {
        var diverged = Math.abs(win.at[0] - (pos.x + snapGrabX)) > snapDivergencePx
          || Math.abs(win.at[1] - (pos.y + snapGrabY)) > snapDivergencePx
        snapDiverged = diverged ? snapDiverged + 1 : 0
        if (snapDiverged >= snapDivergenceTicks) snapDragEnd()
      } else {
        snapDiverged = 0
      }
    })
  }

  function snapDragEnd() {
    console.log("omarchy-modes.switcher: snapDragEnd IPC (dragging=" + snapDragging
      + " candidate=" + JSON.stringify(snapCandidate) + ")")
    if (!snapDragging) return "ignored"
    // A release that lands while a probe/poll is still in flight is deferred —
    // the process exit handler re-invokes this once the pipe is free.
    if (snapProcess.running) {
      snapReleased = true
      return "deferred"
    }
    var candidate = snapCandidate
    var monitor = snapMonitorMeta(snapHoverMonitor)
    if (!candidate || !monitor || !validAddress(snapWindow)) {
      resetSnapDrag()
      return "ignored"
    }
    executeSnap(candidate, monitor, snapWindow)
    return "snapping"
  }

  // The drop chain: re-read clients for liveness + float state, move across
  // workspaces if the drop landed on another monitor, float, then exact
  // pixel resize + move, then verify. One hyprctl call per step.
  function executeSnap(zone, monitor, address) {
    snapCursorTimer.stop()
    snapTimeout.stop()
    runSnap(["hyprctl", "-j", "clients"], "snap clients", function(text) {
      var clients
      try { clients = JSON.parse(text) } catch (e) { snapFail("snap clients not JSON"); return }
      var client = null
      for (var i = 0; i < clients.length; i++) {
        if (clients[i] && clients[i].address === address) { client = clients[i]; break }
      }
      if (!client) { resetSnapDrag(); return }
      var steps = []
      var targetWorkspace = monitor.activeWorkspace ? String(monitor.activeWorkspace.name || "") : ""
      var currentWorkspace = client.workspace ? String(client.workspace.name || "") : ""
      // Cross-monitor drops land on that monitor's active workspace.
      if (validWorkspaceId(targetWorkspace) && targetWorkspace !== currentWorkspace) {
        steps.push("hl.dsp.window.move({ workspace = \"" + targetWorkspace +
          "\", window = \"address:" + address + "\", follow = false })")
      }
      if (client.floating !== true) {
        steps.push("hl.dsp.window.float({ window = \"address:" + address +
          "\", action = \"enable\" })")
      }
      Array.prototype.push.apply(steps, Snap.snapCommands(address, zone))
      runSnapSteps(steps, address, zone)
    })
  }

  function runSnapSteps(steps, address, zone) {
    if (steps.length === 0) { verifySnap(address, zone); return }
    var step = steps[0]
    runSnap(["hyprctl", "dispatch", step], "snap step", function() {
      runSnapSteps(steps.slice(1), address, zone)
    })
  }

  function verifySnap(address, zone) {
    runSnap(["hyprctl", "-j", "clients"], "snap verify", function(text) {
      var clients
      try { clients = JSON.parse(text) } catch (e) { snapFail("snap verify not JSON"); return }
      var client = null
      for (var i = 0; i < clients.length; i++) {
        if (clients[i] && clients[i].address === address) { client = clients[i]; break }
      }
      resetSnapDrag()
      if (!client) return
      // Min/max window sizes can clamp the resize, so verify position rather
      // than demanding the exact rectangle.
      var onTarget = client.at && Math.abs(client.at[0] - zone.x) < 40
        && Math.abs(client.at[1] - zone.y) < 40
      if (!onTarget) snapNotify("Snap did not land", "The window did not move to the snap zone.")
    })
  }

  function snapFilePayload() {
    return JSON.stringify({
      enabled: snapEnabled, columns: snapColumns, rows: snapRows, reach: snapReach
    }) + "\n"
  }

  // snap-assist.json lives in stateDirectory, which a fresh profile may not
  // have yet — ensure it exists first rather than failing the write silently.
  function persistSnapFile() {
    if (ensureDirectories.running) {
      snapFile.setText(snapFilePayload())
      return
    }
    snapPendingWrite = true
    ensureDirectories.command = ["mkdir", "-p", stateDirectory, dropinDirectory]
    ensureDirectories.running = true
  }

  function loadSnapFile(text) {
    snapLoaded = true
    var parsed = null
    try {
      parsed = JSON.parse(text || "")
    } catch (error) {
      parsed = null
    }
    if (parsed) {
      snapEnabled = parsed.enabled === true
      snapColumns = parsed.columns === 2 || parsed.columns === 3 || parsed.columns === 4
        ? parsed.columns : 0
      snapRows = parsed.rows !== false
      snapReach = parsed.reach === 0 || parsed.reach === 1 || parsed.reach === 2
        ? parsed.reach : 1
    }
    reconcileDropin()
  }

  function toggleSnapAssist() {
    if (!snapLoaded) return "not-ready"
    // Optimistic: flip now and regenerate the drop-in immediately — the
    // FileView save is durable state for the next shell start, not the
    // switch that arms the binds in this session.
    snapEnabled = !snapEnabled
    if (!snapEnabled && snapDragging) resetSnapDrag()
    reconcileDropin()
    persistSnapFile()
    return "toggled"
  }

  // Every snap setting is a rotary: dir +1/-1 steps through its values
  // (binary settings flip either way).
  function rotateSnap(id, dir) {
    if (id === "enabled") { toggleSnapAssist(); return }
    if (id === "rows") { snapRows = !snapRows; persistSnapFile(); return }
    if (id === "columns") {
      var opts = [0, 2, 3, 4]
      var i = opts.indexOf(snapColumns)
      snapColumns = opts[((i < 0 ? 0 : i) + dir + opts.length) % opts.length]
      persistSnapFile()
      return
    }
    if (id === "reach") {
      snapReach = ((snapReach + dir) % 3 + 3) % 3
      persistSnapFile()
    }
  }

  function rotateSnapAtCursor(dir) {
    var item = menuModel[menuCursor]
    if (item && item.type === "spin") rotateSnap(item.id, dir)
  }

  function snapFileLoaded(text) {
    loadSnapFile(text)
  }

  // ---- menu model ----
  // The view is built by Model.js from a plain snapshot; rows are typed
  // ("sec", "mode", "spin", "error") and carry a
  // "verb|arg" action. What a type draws is a row component below.
  readonly property string menuFont: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  readonly property color theme: bar ? bar.foreground : Color.foreground
  readonly property color bg: Color.popups.background
  readonly property color menuSurface: Util.alpha(theme, 0.07)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Tones are measured against the card surface (Model.tones), not guessed —
  // labels stay readable on light and high-contrast themes alike.
  readonly property var menuTones: Model.tones(theme, bg, menuSurface, urgent)
  readonly property color menuInk: Qt.rgba(menuTones.ink.r, menuTones.ink.g, menuTones.ink.b, 1)
  readonly property color menuValue: Qt.rgba(menuTones.value.r, menuTones.value.g, menuTones.value.b, 1)
  readonly property color menuLabel: Qt.rgba(menuTones.label.r, menuTones.label.g, menuTones.label.b, 1)
  readonly property color menuAlert: Qt.rgba(menuTones.alert.r, menuTones.alert.g, menuTones.alert.b, 1)
  readonly property int menuGutter: Style.space(18)
  readonly property int menuEdge: Style.space(8)
  readonly property int menuSlot: Style.space(18)
  readonly property int menuRowH: Style.space(24)
  readonly property int menuHeadH: Style.space(14)
  readonly property int menuGroupGap: Style.space(16)
  readonly property int menuTopPad: Style.space(10)

  // The plain snapshot the view is built from
  readonly property var snap: ({
    mode: currentMode, snapEnabled: snapEnabled, snapColumns: snapColumns,
    snapRows: snapRows, snapReach: snapReach,
    applying: applying, problem: applyError
  })
  readonly property var view: {
    try {
      return Model.build(snap)
    } catch (e) {
      return { title: "MODES", mark: "error",
        rows: [{ type: "error", label: String(e.message || e) }] }
    }
  }
  readonly property var menuModel: view.rows
  onMenuModelChanged: menuCursor = Math.max(0, Math.min(menuModel.length - 1, menuCursor))

  function rowIsActionable(row) {
    return row && (row.type === "mode" || row.type === "spin")
  }

  function moveMenuCursor(dy) {
    var items = menuModel, i = menuCursor
    for (;;) {
      var next = i + dy
      if (next < 0 || next >= items.length) break
      i = next
      if (rowIsActionable(items[i])) break
    }
    menuCursor = i
  }

  // An action is "verb|arg...", from Model.js
  function activate(action) {
    var a = (action || "").split("|")
    if (a[0] === "mode") startApply(a[1])
    else if (a[0] === "spin") rotateSnap(a[1], 1)
  }

  function activateMenuItem() {
    var item = menuModel[menuCursor]
    if (rowIsActionable(item)) activate(item.action)
  }

  implicitWidth: modeButton.implicitWidth
  implicitHeight: modeButton.implicitHeight

  IpcHandler {
    target: "omarchy-modes.switcher"

    function cycle(): string { return root.cycleMode() }
    function setMode(mode: string): string { return root.setMode(mode) }
    function menu(): string { root.toggle(); return "toggled" }
    function snapDragStart(): string { return root.snapDragStart() }
    function snapDragEnd(): string { return root.snapDragEnd() }
    function snapToggle(): string { return root.toggleSnapAssist() }
    function snapDebug(): string {
      try {
        var meta = root.snapAreas[root.snapHoverMonitor]
        return JSON.stringify({
          enabled: root.snapEnabled, dragging: root.snapDragging,
          window: root.snapWindow, hoverMonitor: root.snapHoverMonitor,
          candidate: root.snapCandidate, diverged: root.snapDiverged,
          lastX: root.snapLastX, lastY: root.snapLastY,
          pressX: root.snapPressX, pressY: root.snapPressY,
          pollRunning: snapProcess.running, timerRunning: snapCursorTimer.running,
          gapsIn: root.snapGapsIn, gapsOut: root.snapGapsOut,
          areas: Object.keys(root.snapAreas).map(function(k) {
            return k + ":" + root.snapAreas[k].cols + "col"
          }),
          monitors: root.snapMonitors.map(function(m) { return m.name }),
          cols: meta ? meta.cols : 0
        })
      } catch (e) { return "debug-error: " + e.message }
    }
  }

  // The mark: the current mode's glyph — urgent on a failed apply, pulsing
  // while one is in flight, lit otherwise.
  BarIconButton {
    id: modeButton
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.applyError !== "" ? root.applyError : root.currentModeLabel
    active: root.opened || root.applying
    onPressed: root.toggle()
    iconComponent: Component {
      Item {
        Text {
          id: glyph
          anchors.centerIn: parent
          text: root.modeGlyph(root.currentMode)
          color: root.view.mark === "error" ? root.menuAlert : root.theme
          font.family: root.menuFont
          font.pixelSize: Style.font.body
          SequentialAnimation on opacity {
            running: root.view.mark === "busy"
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 400 }
            NumberAnimation { to: 1; duration: 400 }
            onStopped: glyph.opacity = 1
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: modeMenu
    anchorItem: modeButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: menuKeys
    contentWidth: modeMenu.fittedContentWidth(Style.space(230))
    contentHeight: modeMenu.fittedContentHeight(menuRows.implicitHeight)

    PanelKeyCatcher {
      id: menuKeys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveMenuCursor(dy)
        else if (dx !== 0) root.rotateSnapAtCursor(dx)
      }
      onActivateRequested: root.activateMenuItem()
      onCloseRequested: root.close()

      Column {
        id: menuRows
        width: parent.width
        spacing: 0
        topPadding: Style.space(8)
        bottomPadding: root.menuTopPad

        // The top line: the name and the current mode, styled like a section header
        Item {
          width: parent.width
          height: root.menuHeadH
          Text {
            id: menuHead
            x: root.menuGutter
            anchors.verticalCenter: parent.verticalCenter
            text: root.view.title || ""
            color: root.menuLabel
            font.family: root.menuFont
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            anchors.left: menuHead.right
            anchors.leftMargin: Style.space(8)
            anchors.baseline: menuHead.baseline
            text: root.view.version || ""
            color: Util.alpha(root.menuLabel, 0.55)
            font.family: root.menuFont
            font.pixelSize: Style.font.caption - 2
          }
        }

        Repeater {
          // keyed by position, so a refresh updates rows in place instead of rebuilding them (no flicker)
          model: (root.menuModel || []).length

          Item {
            required property int index
            readonly property var item: (root.menuModel || [])[index] || ({ type: "" })
            readonly property bool isRow: root.rowIsActionable(item)
            readonly property bool isError: item.type === "error"
            readonly property bool cursor: isRow && root.menuCursor === index
            // A leading slot holds the mode glyph.
            readonly property bool hasSlot: item.type === "mode"
            width: menuRows.width
            height: isRow ? root.menuRowH
              : isError ? errText.implicitHeight + Style.space(8)
              : (index === 0 ? 0 : root.menuGroupGap) + root.menuHeadH
            opacity: root.applying && item.type === "mode" ? 0.55 : 1

            // An apply failure, inline instead of a tooltip
            Text {
              id: errText
              visible: parent.isError
              x: root.menuGutter
              width: parent.width - 2 * root.menuGutter
              anchors.verticalCenter: parent.verticalCenter
              text: parent.item.label
              color: root.menuAlert
              font.family: root.menuFont
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Section header ("LAYOUT", "SNAP") — sits on its group's rows.
            Text {
              visible: !parent.isRow && !parent.isError
              x: root.menuGutter
              anchors.bottom: parent.bottom
              text: parent.item.label
              color: root.menuLabel
              font.family: root.menuFont
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Rectangle {
              visible: parent.isRow
              x: root.menuEdge
              width: parent.width - 2 * root.menuEdge
              height: root.menuRowH
              radius: 2
              color: parent.cursor ? root.menuSurface : "transparent"
            }

            Text {
              visible: parent.isRow && parent.hasSlot
              x: root.menuGutter
              anchors.verticalCenter: parent.verticalCenter
              text: parent.item.glyph || ""
              color: root.menuValue
              font.family: root.menuFont
              font.pixelSize: Style.font.body
            }

            Text {
              visible: parent.isRow
              x: root.menuGutter + (parent.hasSlot ? root.menuSlot : 0)
              width: parent.width - x - root.menuGutter - Style.space(64)
              anchors.verticalCenter: parent.verticalCenter
              text: parent.item.label
              color: root.menuInk
              font.family: root.menuFont
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              visible: parent.isRow && !!parent.item.value
              anchors.right: parent.right
              anchors.rightMargin: root.menuGutter
              anchors.verticalCenter: parent.verticalCenter
              // spins read "< value >"; the mode check is a bare ✓
              text: parent.item.type === "spin"
                ? "< " + String(parent.item.value || "") + " >"
                : String(parent.item.value || "")
              color: parent.item.type === "mode" ? root.menuInk : root.menuValue
              font.family: root.menuFont
              font.pixelSize: Style.font.body
            }

            MouseArea {
              visible: parent.isRow
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              enabled: !(root.applying && parent.item.type === "mode")
              onEntered: root.menuCursor = parent.index
              onClicked: root.activateMenuItem()
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
    onLoaded: {
      root.dropinExisting = text()
      root.dropinReady = true
      root.reconcileDropin()
    }
    onLoadFailed: {
      root.dropinExisting = ""
      root.dropinReady = true
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

  FileView {
    id: snapFile
    path: root.stateDirectory + "/snap-assist.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.snapFileLoaded(text())
    onLoadFailed: root.snapFileLoaded(null)
    onFileChanged: reload()
    // A failed save only means the next session starts disabled — the
    // in-memory flag keeps this session consistent.
    onSaveFailed: console.warn("omarchy-modes.switcher: could not persist snap-assist.json")
  }

  Process {
    id: ensureDirectories
    onExited: function(exitCode) {
      if (root.snapPendingWrite) {
        root.snapPendingWrite = false
        if (exitCode === 0) {
          snapFile.setText(root.snapFilePayload())
        } else {
          console.warn("omarchy-modes.switcher: could not create state directories for snap toggle")
        }
        return
      }
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

  // ---- snap assist plumbing ----

  Process {
    id: snapProcess
    stdout: StdioCollector { id: snapStdout; waitForEnd: true }
    stderr: StdioCollector { id: snapStderr; waitForEnd: true }
    onExited: function(exitCode) {
      snapWatchdog.stop()
      var continuation = root.snapContinuation
      root.snapContinuation = null
      if (exitCode !== 0) {
        console.warn("omarchy-modes.switcher: snap step '" + root.snapDescription
          + "' failed" + (snapStderr.text ? ": " + String(snapStderr.text).trim() : "."))
        if (root.snapDragging) root.resetSnapDrag()
        return
      }
      if (continuation) continuation(String(snapStdout.text || ""))
      // A release deferred while this step ran now evaluates the drop.
      if (root.snapReleased && root.snapDragging && !snapProcess.running) {
        root.snapReleased = false
        root.snapDragEnd()
      }
    }
  }

  Timer {
    id: snapWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (!snapProcess.running) return
      snapProcess.signal(9)
      console.warn("omarchy-modes.switcher: snap step '" + root.snapDescription + "' timed out")
      if (root.snapDragging) root.resetSnapDrag()
    }
  }

  Timer {
    id: snapCursorTimer
    interval: root.snapPollMs
    repeat: true
    onTriggered: root.snapCursorTick()
  }

  // Failsafe: if the release IPC never arrives (bind removed mid-drag, IPC
  // wedged), the drag must not leak the overlay forever.
  Timer {
    id: snapTimeout
    interval: root.snapDragTimeoutMs
    repeat: false
    onTriggered: {
      if (root.snapDragging) {
        console.warn("omarchy-modes.switcher: snap drag timed out; resetting")
        root.resetSnapDrag()
      }
    }
  }

  Process {
    id: snapNotifier
  }

  // Click-through snap cue: surfaces exist for the whole drag so the cue
  // paints the same frame the candidate flips on — creating a layer surface
  // at candidate time lags behind a real drag. mask: Region {} keeps them
  // visual-only; Omarchy's drag owns the pointer throughout.
  Variants {
    model: root.snapDragging ? Quickshell.screens : []

    PanelWindow {
      id: snapOverlay
      required property var modelData
      property string screenName: modelData ? String(modelData.name || "") : ""
      property var monitorMeta: root.snapMonitorMeta(screenName)
      // Cue only on the screen whose monitor owns the candidate.
      readonly property bool cueHere: root.snapCandidate !== null
        && root.snapHoverMonitor === screenName
      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "omarchy-modes-snap"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      Rectangle {
        readonly property var candidate: root.snapCandidate
        visible: snapOverlay.cueHere && candidate !== null
        x: (candidate ? candidate.x : 0) - (snapOverlay.monitorMeta ? snapOverlay.monitorMeta.x : 0)
        y: (candidate ? candidate.y : 0) - (snapOverlay.monitorMeta ? snapOverlay.monitorMeta.y : 0)
        width: candidate ? candidate.width : 0
        height: candidate ? candidate.height : 0
        radius: Style.cornerRadius
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.38)
        border.color: Color.accent
        border.width: 3
      }
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

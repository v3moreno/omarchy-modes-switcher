/*
 * Lua is executable configuration, so this module accepts only the small,
 * checked vocabulary that can affect a rule. Titles, classes, and every other
 * window string remain state data and are never rendered into this file.
 */

var State = typeof require === "function" ? require("./state.js") : null;
var MODES = ["floating", "dwindle", "master", "scrolling"];
var WORKSPACE_ID = /^(?:0|[1-9][0-9]*)$/;
var LAYOUT_FOR_MODE = {
    floating: "dwindle",
    dwindle: "dwindle",
    master: "master",
    scrolling: "scrolling"
};

// Emitted into the drop-in only when enableKeybinds is set, so the binding is
// opt-in and cannot carry a workspace id, title, class, or other input.
var KEYBIND_LINES = [
    'hl.bind("SUPER + ALT + SPACE", hl.dsp.exec_cmd("qs ipc -n -p \\\"$OMARCHY_PATH/shell\\\" call omarchy-modes.switcher cycle"), { description = "Cycle Omarchy mode" }) -- omarchy-modes-switcher'
];

function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function compareWorkspaceIds(left, right) {
    if (left.length !== right.length) {
        return left.length - right.length;
    }
    if (left < right) {
        return -1;
    }
    if (left > right) {
        return 1;
    }
    return 0;
}

function validateModesForGeneration(state) {
    var modes;
    var workspaceIds;
    var index;
    var workspaceId;
    var mode;

    if (State) {
        State.validateState(state);
    }

    if (!isObject(state) || !isObject(state.modes)) {
        throw new TypeError("Cannot generate omarchy-modes.lua: state.modes must be an object.");
    }

    modes = state.modes;
    workspaceIds = Object.keys(modes).sort(compareWorkspaceIds);
    for (index = 0; index < workspaceIds.length; index += 1) {
        workspaceId = workspaceIds[index];
        mode = modes[workspaceId];
        if (!WORKSPACE_ID.test(workspaceId)) {
            throw new TypeError("Cannot generate omarchy-modes.lua: invalid workspace id " + JSON.stringify(workspaceId) + ".");
        }
        if (MODES.indexOf(mode) === -1) {
            throw new TypeError("Cannot generate omarchy-modes.lua: invalid mode for workspace " + JSON.stringify(workspaceId) + ".");
        }
    }

    return workspaceIds;
}

function normalizeOptions(options) {
    var normalized = {
        enableKeybinds: false
    };

    if (typeof options === "undefined") {
        return normalized;
    }
    if (!isObject(options)) {
        throw new TypeError("Drop-in options must be an object.");
    }
    if (typeof options.enableKeybinds !== "undefined") {
        if (typeof options.enableKeybinds !== "boolean") {
            throw new TypeError("enableKeybinds must be a boolean.");
        }
        normalized.enableKeybinds = options.enableKeybinds;
    }
    return normalized;
}

function luaString(value) {
    // JSON string literals are valid Lua string literals for our ASCII vocabulary.
    return JSON.stringify(value);
}

function generateDropin(state, options) {
    var workspaceIds = validateModesForGeneration(state);
    var flags = normalizeOptions(options);
    var lines = [
        "-- omarchy-modes-switcher: generated, do not edit"
    ];
    var index;
    var workspaceId;
    var mode;
    var layout;

    for (index = 0; index < workspaceIds.length; index += 1) {
        workspaceId = workspaceIds[index];
        mode = state.modes[workspaceId];
        layout = LAYOUT_FOR_MODE[mode];
        lines.push("");
        lines.push("hl.workspace_rule({ workspace = " + luaString(workspaceId) +
            ", layout = " + luaString(layout) + " }) -- omarchy-modes-switcher");

        if (mode === "floating") {
            lines.push("hl.window_rule({ match = { workspace = " + luaString(workspaceId) +
                " }, float = true }) -- omarchy-modes-switcher");
        }
    }

    if (flags.enableKeybinds) {
        lines.push("");
        Array.prototype.push.apply(lines, KEYBIND_LINES);
    }

    return lines.join("\n") + "\n";
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        KEYBIND_LINES: KEYBIND_LINES,
        LAYOUT_FOR_MODE: LAYOUT_FOR_MODE,
        generateDropin: generateDropin
    };
}

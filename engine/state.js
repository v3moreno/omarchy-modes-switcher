/*
 * State is deliberately parsed as an all-or-nothing document. A half-loaded
 * mode map would make a bad file look like a compositor problem, which is far
 * harder to diagnose than rejecting it at the boundary.
 */

var MODES = ["floating", "dwindle", "master", "scrolling"];
var WORKSPACE_ID = /^(?:0|[1-9][0-9]*)$/;
var WINDOW_ADDRESS = /^0x[0-9a-fA-F]+$/;

function StateValidationError(message) {
    this.name = "StateValidationError";
    this.message = message;
    if (Error.captureStackTrace) {
        Error.captureStackTrace(this, StateValidationError);
    }
}

StateValidationError.prototype = Object.create(Error.prototype);
StateValidationError.prototype.constructor = StateValidationError;

function defaultState() {
    return { modes: {}, minimized: {} };
}

function hasOwn(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
}

function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isMode(value) {
    return typeof value === "string" && MODES.indexOf(value) !== -1;
}

function compareWorkspaceIds(left, right) {
    // Decimal-string ordering stays deterministic even beyond Number's safe range.
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

function fail(path, expectation) {
    throw new StateValidationError("Invalid state.json at " + path + ": " + expectation + ".");
}

function requireExactKeys(object, keys, path) {
    var actual = Object.keys(object).sort();
    var expected = keys.slice().sort();
    var index;

    if (actual.length !== expected.length) {
        fail(path, "expected exactly " + expected.join(", "));
    }

    for (index = 0; index < expected.length; index += 1) {
        if (actual[index] !== expected[index]) {
            fail(path, "expected exactly " + expected.join(", "));
        }
    }
}

function validateWorkspaceId(id, path) {
    if (typeof id !== "string" || !WORKSPACE_ID.test(id)) {
        fail(path, "workspace id must be a non-negative decimal integer string");
    }
}

function validateState(state) {
    var normalized = defaultState();
    var workspaceIds;
    var addresses;
    var index;
    var workspaceId;
    var address;
    var minimized;

    if (!isObject(state)) {
        fail("$", "expected an object");
    }
    requireExactKeys(state, ["modes", "minimized"], "$");

    if (!isObject(state.modes)) {
        fail("$.modes", "expected an object");
    }
    if (!isObject(state.minimized)) {
        fail("$.minimized", "expected an object");
    }

    workspaceIds = Object.keys(state.modes).sort(compareWorkspaceIds);
    for (index = 0; index < workspaceIds.length; index += 1) {
        workspaceId = workspaceIds[index];
        validateWorkspaceId(workspaceId, "$.modes[" + JSON.stringify(workspaceId) + "]");
        if (!isMode(state.modes[workspaceId])) {
            fail("$.modes[" + JSON.stringify(workspaceId) + "]",
                "mode must be one of " + MODES.join(", "));
        }
        normalized.modes[workspaceId] = state.modes[workspaceId];
    }

    addresses = Object.keys(state.minimized).sort();
    for (index = 0; index < addresses.length; index += 1) {
        address = addresses[index];
        if (!WINDOW_ADDRESS.test(address)) {
            fail("$.minimized[" + JSON.stringify(address) + "]",
                "window address must be a hexadecimal 0x address");
        }

        minimized = state.minimized[address];
        if (!isObject(minimized)) {
            fail("$.minimized[" + JSON.stringify(address) + "]", "expected an object");
        }
        requireExactKeys(minimized, ["origin", "title", "class"],
            "$.minimized[" + JSON.stringify(address) + "]");
        validateWorkspaceId(minimized.origin,
            "$.minimized[" + JSON.stringify(address) + "].origin");
        if (typeof minimized.title !== "string") {
            fail("$.minimized[" + JSON.stringify(address) + "].title", "expected a string");
        }
        if (typeof minimized["class"] !== "string") {
            fail("$.minimized[" + JSON.stringify(address) + "].class", "expected a string");
        }

        // Titles and classes are persisted for display only; they never reach Lua.
        normalized.minimized[address] = {
            origin: minimized.origin,
            title: minimized.title,
            "class": minimized["class"]
        };
    }

    return normalized;
}

function parseState(text) {
    var parsed;

    if (typeof text !== "string") {
        throw new StateValidationError("Invalid state.json: expected JSON text.");
    }

    try {
        parsed = JSON.parse(text);
    } catch (error) {
        throw new StateValidationError("Invalid state.json: invalid JSON (" + error.message + ").");
    }

    return validateState(parsed);
}

function readState(text) {
    if (text === null || typeof text === "undefined") {
        return { ok: true, missing: true, state: defaultState(), error: null };
    }

    try {
        return { ok: true, missing: false, state: parseState(text), error: null };
    } catch (error) {
        return {
            ok: false,
            missing: false,
            state: defaultState(),
            error: error.name + ": " + error.message
        };
    }
}

function writeState(state) {
    return JSON.stringify(validateState(state), null, 2) + "\n";
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        MODES: MODES,
        StateValidationError: StateValidationError,
        defaultState: defaultState,
        isMode: isMode,
        validateState: validateState,
        parseState: parseState,
        readState: readState,
        writeState: writeState
    };
}

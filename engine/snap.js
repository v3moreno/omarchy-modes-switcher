/*
 * Edge-triggered snap geometry. Pure: no filesystem, no subprocess — callers
 * feed it hyprctl monitor/client data and Hyprland's configured gaps, and get
 * back the one snap rectangle the cursor currently implies, or null.
 *
 * Model (Windows-like):
 *   - default layout is a single row of two columns on any monitor;
 *   - dragging near a side edge offers that side's column (full height);
 *   - dragging near the top/bottom edge offers the upper/lower half of the
 *     column under the cursor (up to two rows per column); on wide monitors
 *     the centre portion of those edges offers the full middle column;
 *   - pushing all the way to the very top (onto the bar / top bezel) offers
 *     fullscreen;
 *   - away from every edge: no candidate, no overlay.
 *
 * Columns by aspect class of the monitor (auto), or a fixed 2/3/4 when the
 * user overrides it:
 *   < 1.9  (16:9, 16:10, ...)        -> 2 columns (side edges only)
 *   < 3.0  (21:9 ultrawide, ~34")    -> 3 columns (middle edges enabled)
 *   >= 3.0 (32:9 super-ultrawide)    -> 4 columns (middle edges span the two
 *                                          inner columns)
 *
 * Rectangles reproduce Hyprland's own gaps: gaps_out against the monitor
 * work-area edge and gaps_in between windows, so a snapped window lands where
 * a tiled window would.
 */

var MIN_COLS_RATIO_2 = 1.9;
var MIN_COLS_RATIO_3 = 3.0;
var SNAP_ARM_DISTANCE = 40;
// Proximity that counts as "next to" an edge, in logical pixels.
var EDGE_X = 140;
var EDGE_Y = 110;
// Extra slack below the work-area top still treated as "all the way up".
// The bar already lives in reserved space above the work area, so reaching
// the physical top means y <= work-area top + this pad.
var FULL_TOP_PAD = 8;

// `override` pins the layout to a fixed column count regardless of aspect;
// 0/undefined means detect from the monitor.
function columnsFor(width, height, override) {
    if (override === 2 || override === 3 || override === 4) return override;
    if (typeof width !== "number" || typeof height !== "number" || height <= 0) {
        return 2;
    }
    var ratio = width / height;
    if (ratio >= MIN_COLS_RATIO_3) return 4;
    if (ratio >= MIN_COLS_RATIO_2) return 3;
    return 2;
}

// hyprctl monitors "reserved" is [left, top, right, bottom].
function workArea(monitor) {
    var reserved = Array.isArray(monitor && monitor.reserved) ? monitor.reserved : [0, 0, 0, 0];
    var left = reserved[0] || 0;
    var top = reserved[1] || 0;
    var right = reserved[2] || 0;
    var bottom = reserved[3] || 0;
    return {
        x: (monitor.x || 0) + left,
        y: (monitor.y || 0) + top,
        width: Math.max(0, (monitor.width || 0) - left - right),
        height: Math.max(0, (monitor.height || 0) - top - bottom)
    };
}

// CSS shorthand "top right bottom left" as Hyprland reports it for
// general:gaps_in / general:gaps_out (e.g. "5 5 5 5", "10", "10 20").
function parseGaps(css) {
    var parts = String(css || "").trim().split(/\s+/);
    var nums = [];
    for (var i = 0; i < parts.length; i += 1) {
        var n = parseFloat(parts[i]);
        nums.push(isFinite(n) ? Math.max(0, n) : 0);
    }
    if (nums.length === 0) nums = [0];
    var top = nums[0];
    var right = nums.length > 1 ? nums[1] : nums[0];
    var bottom = nums.length > 2 ? nums[2] : nums[0];
    var left = nums.length > 3 ? nums[3] : right;
    return { top: top, right: right, bottom: bottom, left: left };
}

function rect(x, y, width, height, name) {
    return {
        x: Math.round(x),
        y: Math.round(y),
        width: Math.round(Math.max(0, width)),
        height: Math.round(Math.max(0, height)),
        name: name
    };
}

// The cell grid: `segments` equal cells across the work area, inset by the
// outer gap. Window rectangles are cells further inset by gaps_in, exactly
// how Hyprland lays out tiled windows (inter-window gap = gaps_in * 2).
function cellRects(area, segments, horizontal, gapsOut, gapsIn) {
    var cells = [];
    var outerA = horizontal ? gapsOut.left : gapsOut.top;
    var outerB = horizontal ? gapsOut.right : gapsOut.bottom;
    var innerA = horizontal ? gapsIn.left : gapsIn.top;
    var innerB = horizontal ? gapsIn.right : gapsIn.bottom;
    var start = (horizontal ? area.x : area.y) + outerA;
    var span = Math.max(0, (horizontal ? area.width : area.height) - outerA - outerB);
    var cell = span / segments;
    var i;
    for (i = 0; i < segments; i += 1) {
        if (horizontal) {
            cells.push(rect(start + i * cell + innerA, area.y + gapsOut.top + gapsIn.top,
                cell - innerA - innerB, area.height - gapsOut.top - gapsOut.bottom - gapsIn.top - gapsIn.bottom, ""));
        } else {
            cells.push(rect(area.x + gapsOut.left + gapsIn.left, start + i * cell + innerA,
                area.width - gapsOut.left - gapsOut.right - gapsIn.left - gapsIn.right, cell - innerA - innerB, ""));
        }
    }
    return cells;
}

// The middle column for cols >= 3: the inner cells merged (one cell for 3
// columns, two for 4). Also used as the hit band on the top/bottom edges.
function middleColumn(area, cols, gapsOut, gapsIn) {
    var cells = cellRects(area, cols, true, gapsOut, gapsIn);
    if (cells.length < 3) return null;
    var first = cells[1];
    var last = cells[cells.length - 2];
    return rect(first.x, first.y, last.x + last.width - first.x, first.height, "col-middle");
}

// Split a column's window rect into its upper/lower row, keeping the same
// gaps_in spacing between the two windows as Hyprland tiles would.
function rowHalf(colRect, top, gapsIn, name) {
    var innerGap = gapsIn.top + gapsIn.bottom;
    var h = (colRect.height - innerGap) / 2;
    if (top) return rect(colRect.x, colRect.y, colRect.width, h, name);
    return rect(colRect.x, colRect.y + h + innerGap, colRect.width, h, name);
}

// Which grid column a global x lands in, using cell (not window-rect)
// boundaries so cursor positions inside the gaps still resolve.
function columnIndexAt(area, cols, gapsOut, x) {
    var usableX = area.x + gapsOut.left;
    var usableW = Math.max(1, area.width - gapsOut.left - gapsOut.right);
    var idx = Math.floor((x - usableX) / (usableW / cols));
    return Math.max(0, Math.min(cols - 1, idx));
}

function fullscreenRect(area, gapsOut, gapsIn) {
    return rect(area.x + gapsOut.left + gapsIn.left, area.y + gapsOut.top + gapsIn.top,
        area.width - gapsOut.left - gapsOut.right - gapsIn.left - gapsIn.right,
        area.height - gapsOut.top - gapsOut.bottom - gapsIn.top - gapsIn.bottom,
        "fullscreen");
}

/*
 * The single snap the cursor implies on this monitor, or null when it is not
 * near an actionable edge. `x`/`y` are global coordinates; `area` is the
 * monitor's work area and `cols` its column count.
 *
 * `opts` tunes the behaviour:
 *   opts.rows  — when false the top/bottom edge never offers the per-column
 *                half rows (middle column and fullscreen still apply);
 *   opts.reach — scales the edge proximity bands (1 = normal).
 */
function edgeCandidate(area, cols, x, y, gapsOut, gapsIn, opts) {
    if (!area || area.width <= 0 || area.height <= 0) return null;
    var rows = !opts || opts.rows !== false;
    var reach = opts && isFinite(opts.reach) && opts.reach > 0 ? opts.reach : 1;
    var edgeX = EDGE_X * reach;
    var edgeY = EDGE_Y * reach;
    if (x < area.x || x >= area.x + area.width + edgeX) return null;
    if (y < area.y - edgeY - gapsOut.top || y > area.y + area.height + edgeY) return null;

    // All the way up: over the bar / top bezel -> fullscreen.
    if (y <= area.y + FULL_TOP_PAD) {
        return fullscreenRect(area, gapsOut, gapsIn);
    }

    var colsCells = cellRects(area, cols, true, gapsOut, gapsIn);

    var distLeft = x - area.x;
    var distRight = area.x + area.width - x;
    var distTop = y - area.y;
    var distBottom = area.y + area.height - y;

    var horiz = Math.min(distTop, distBottom) <= edgeY ? (distTop <= distBottom ? "top" : "bottom") : null;
    var vert = Math.min(distLeft, distRight) <= edgeX ? (distLeft <= distRight ? "left" : "right") : null;
    if (!horiz && !vert) return null;

    var candidate = null;
    if (horiz) {
        var colIdx = columnIndexAt(area, cols, gapsOut, x);
        // Wide monitors: the centre stretch of the top/bottom edge snaps to
        // the full middle column; elsewhere the edge snaps that column's row.
        var middle = cols >= 3 ? middleColumn(area, cols, gapsOut, gapsIn) : null;
        if (middle && colIdx >= 1 && colIdx <= cols - 2) {
            candidate = middle;
        } else if (rows && colsCells[colIdx]) {
            candidate = rowHalf(colsCells[colIdx], horiz === "top", gapsIn,
                "row-" + horiz + "-col" + colIdx);
        }
    }
    // Top/bottom proximity wins outright: side columns are only offered along
    // the middle stretch of the side edge, never over a corner row snap.
    if (!candidate && vert) {
        candidate = vert === "left" ? colsCells[0] : colsCells[colsCells.length - 1];
        if (candidate) candidate.name = "col-" + vert;
    }
    return candidate || null;
}

function monitorAt(monitors, x, y) {
    var index;
    var monitor;
    if (!Array.isArray(monitors)) return null;
    for (index = 0; index < monitors.length; index += 1) {
        monitor = monitors[index];
        if (monitor && x >= monitor.x && x < monitor.x + monitor.width
                && y >= monitor.y && y < monitor.y + monitor.height) {
            return monitor;
        }
    }
    return null;
}

// Enough cursor travel between press and release that the release was a
// drag, not a click. Plain SUPER+clicks must never snap anything.
function dragIsArmed(pressX, pressY, x, y) {
    var dx = x - pressX;
    var dy = y - pressY;
    return dx * dx + dy * dy >= SNAP_ARM_DISTANCE * SNAP_ARM_DISTANCE;
}

function snapCommands(address, zone) {
    var addressArg = "address:" + address;
    return [
        "hl.dsp.window.resize({ window = \"" + addressArg + "\", x = " +
            Math.round(zone.width) + ", y = " + Math.round(zone.height) + " })",
        "hl.dsp.window.move({ window = \"" + addressArg + "\", x = " +
            Math.round(zone.x) + ", y = " + Math.round(zone.y) + " })"
    ];
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        SNAP_ARM_DISTANCE: SNAP_ARM_DISTANCE,
        EDGE_X: EDGE_X,
        EDGE_Y: EDGE_Y,
        FULL_TOP_PAD: FULL_TOP_PAD,
        columnsFor: columnsFor,
        workArea: workArea,
        parseGaps: parseGaps,
        cellRects: cellRects,
        middleColumn: middleColumn,
        fullscreenRect: fullscreenRect,
        edgeCandidate: edgeCandidate,
        monitorAt: monitorAt,
        dragIsArmed: dragIsArmed,
        snapCommands: snapCommands
    };
}

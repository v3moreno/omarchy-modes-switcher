// What the switcher shows, as data: the live workspace mode plus snap-assist
// settings in, a view out. ModeSwitcher.qml draws the view and turns its
// actions ("verb|arg") into calls back into the widget. No Qt, no side
// effects — build() is a pure function and can be exercised with plain node.

// APCA-W3 0.1.9 lightness contrast (Lc) of text on a background. Colors are {r, g, b} in 0..1, as Qt gives them.
// Every text and line color in the panel is picked by the Lc it must reach, so any theme stays readable.
function lum(c) { return 0.2126729 * Math.pow(c.r, 2.4) + 0.7151522 * Math.pow(c.g, 2.4) + 0.072175 * Math.pow(c.b, 2.4) }
function apca(text, bg) {
  var t = lum(text), b = lum(bg)
  if (t < 0.022) t += Math.pow(0.022 - t, 1.414)
  if (b < 0.022) b += Math.pow(0.022 - b, 1.414)
  if (Math.abs(b - t) < 0.0005) return 0
  var s = b > t ? (Math.pow(b, 0.56) - Math.pow(t, 0.57)) * 1.14 : (Math.pow(b, 0.65) - Math.pow(t, 0.62)) * 1.14
  return Math.abs(s) < 0.1 ? 0 : (s > 0 ? s - 0.027 : s + 0.027) * 100
}
function mix(a, b, t) { return { r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: 1 } }
// a translucent color as it lands on an opaque one
function over(c, bg) { var a = c.a === undefined ? 1 : c.a; return mix(bg, c, a) }
// the color closest to `from` on the way to `to` that reaches |Lc| >= target on bg; `to` when nothing does
function reach(from, to, bg, target) {
  if (Math.abs(apca(from, bg)) >= target) return from
  if (Math.abs(apca(to, bg)) < target) return to
  var lo = 0, hi = 1
  for (var i = 0; i < 24; i++) {
    var m = (lo + hi) / 2
    if (Math.abs(apca(mix(from, to, m), bg)) >= target) hi = m
    else lo = m
  }
  return mix(from, to, hi)
}
// The panel's tones, all measured on the card surface (the lighter of its two backgrounds, so the worst case):
// ink is for what matters now, value for what a label names, label for every label, rule for lines that are
// not text, alert for problems.
var LC = { ink: 90, value: 80, label: 60, rule: 15, alert: 60 }
function tones(ink, bg, surface, urgent) {
  var card = over(surface, bg), white = { r: 1, g: 1, b: 1 }, black = { r: 0, g: 0, b: 0 }
  var far = Math.abs(apca(white, card)) > Math.abs(apca(black, card)) ? white : black
  var top = reach(over(ink, bg), far, card, LC.ink)
  return { ink: top, value: reach(card, top, card, LC.value), label: reach(card, top, card, LC.label),
    rule: reach(card, top, card, LC.rule), alert: reach(urgent, top, card, LC.alert), alertRule: reach(urgent, top, card, LC.rule) }
}

var MODES = ["floating", "dwindle", "master", "scrolling"]
var LABELS = { floating: "Floating", dwindle: "Dwindle", master: "Master", scrolling: "Scrolling" }
var GLYPHS = { floating: "󰉈", dwindle: "󰕭", master: "󰕮", scrolling: "󰕰" }
var REACH_NAMES = ["near", "normal", "far"]

function modeLabel(m) { return LABELS[m] || "Dwindle" }
function modeGlyph(m) { return GLYPHS[m] || "󰕭" }

// the bar mark: a failed apply reads urgent, an in-flight one busy, otherwise ready
function mark(s) { return s.problem ? "error" : s.applying ? "busy" : "ready" }

// A snap setting shown as "< value >"; Enter/click steps forward, Left/Right steps.
function spin(id, value) {
  return { type: "spin", id: id, label: id, value: value, action: "spin|" + id }
}

function build(s) {
  s = s || {}
  var rows = []
  if (s.problem) rows.push({ type: "error", label: s.problem })

  MODES.forEach(function(m) {
    rows.push({ type: "mode", id: m, label: modeLabel(m), glyph: modeGlyph(m),
      on: s.mode === m, value: s.mode === m ? "✓" : "", action: "mode|" + m })
  })

  rows.push({ type: "sec", label: "SNAP" })
  rows.push(spin("enabled", s.snapEnabled ? "on" : "off"))
  rows.push(spin("columns", s.snapColumns === 0 ? "auto" : String(s.snapColumns)))
  rows.push(spin("rows", s.snapRows !== false ? "on" : "off"))
  var reach = s.snapReach === 0 || s.snapReach === 2 ? s.snapReach : 1
  rows.push(spin("reach", REACH_NAMES[reach]))
  return { title: "MODES", version: modeLabel(s.mode), rows: rows, mark: mark(s) }
}

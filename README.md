# Omarchy Modes Switcher

Per-workspace layout modes for Hyprland, switched from an Omarchy bar widget.

![Preview Image](preview.png)

Each workspace gets its own mode:

- **Floating** — windows open floating and stay that way
- **Dwindle** — Hyprland's default binary-tree tiling
- **Master** — master/stack tiling
- **Scrolling** — scrolling layout

The widget shows the focused workspace's mode; click it to open the mode menu. Switching rewrites a generated Hyprland drop-in, reloads the compositor, and reconciles already-open windows on that workspace (floats them or tiles them).

## Install

```
omarchy plugin add https://github.com/v3moreno/omarchy-modes-switcher --enable
```

Then add the **Modes** widget to the bar (it defaults to the left section).

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `enableKeybinds` | `false` | Emit `SUPER + ALT + SPACE` → cycle mode for the focused workspace |

## IPC

The widget exposes an IPC target for scripts or your own bindings:

```
qs ipc -n -p "$OMARCHY_PATH/shell" call omarchy-modes.switcher cycle
qs ipc -n -p "$OMARCHY_PATH/shell" call omarchy-modes.switcher setMode master
```

## How it works

- Choices are persisted to `~/.local/state/omarchy-modes/state.json`.
- The widget generates `~/.local/state/omarchy/toggles/hypr/omarchy-modes.lua` with one `hl.workspace_rule` per configured workspace, plus a `float` window rule for floating-mode workspaces. Omarchy auto-loads every file in that directory on `hyprctl reload`.
- Generated Lua only ever carries validated workspace ids and mode names — window titles, classes, and other strings never reach it.
- Disabling or removing the plugin deletes the drop-in and reloads Hyprland. `state.json` is kept, so re-enabling restores your modes.

## Notes

- Pairs well with [omarchy-resizeable](https://github.com/v3moreno/omarchy-resizeable), which enables border-drag resizing — handy in floating mode.
- A workspace with no recorded mode shows its live layout (or Dwindle) until you pick one.

## License

MIT — see [LICENSE](LICENSE).

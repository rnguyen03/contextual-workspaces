# Contextual Workspaces

Named app/workspace contexts for Hyprland: launch a group of apps together with
one click, keep specific apps pinned to specific workspaces no matter how
they're launched, and optionally switch wallpaper/color scheme to match
whichever context you're in — including automatically when you navigate
workspaces manually, or when the Pomodoro Timer plugin starts a work/break
session.

## Features
- **Named contexts**: e.g. "Work", "Research", "Personal" — each a list of apps
  with a launch command, a target workspace, and an optional pin, plus an
  optional wallpaper and color scheme.
- **Launch a context**: starts every app in the context, each opened directly
  on its target workspace, and applies its wallpaper/color scheme.
- **Pinning**: any member with "Always pin to this workspace" enabled also gets
  a generated Hyprland `windowrule` (via `hl.window_rule`) matching its window
  class, so that app lands on the same workspace even when opened some other
  way (app launcher, a shortcut, clicking a link, etc.) — not just when
  launched through this plugin.
- **Live workspace-navigation awareness**: manually switching workspaces
  (`SUPER+N`) applies the wallpaper/color scheme of whichever context owns
  that workspace, not just an explicit launch. Toggle with `Auto-switch on
  workspace navigation`.
- **Pomodoro Timer integration** (opt-in): if the `thepunkoff/pomodoro` plugin
  is installed, this plugin can switch to a designated "focus" or "break"
  context's wallpaper/color scheme when a work or break session starts.
- **Bar widget**: shows the active context's glyph; click to open the panel.

## How it works

A **context** is just a name (e.g. "Work") plus a list of **members** — apps,
each with a launch command, a target workspace number, and whether it's
pinned — and an optional wallpaper/color scheme. Contexts are stored as a
JSON file in this plugin's own data directory, not in Noctalia settings, and
are only ever edited through the panel.

There are three independent ways a context actually affects your desktop,
and it's worth knowing which is which:

1. **Launching a context** (panel's play button, a keybind, or IPC) runs
   `hyprctl dispatch` once per member to open it directly on its workspace,
   then applies the context's wallpaper/color scheme. This is a one-shot
   action — it does nothing to apps you open afterward.
2. **Pinning** is the "no matter how it's opened" behavior. Every time you
   save a context, the service regenerates a small Hyprland include
   (`hyprland-rules-file`) with one `windowrule`-style rule per pinned
   member, matching its window class to its workspace, and (by default)
   runs `hyprctl reload` so it takes effect immediately. This is why pinning
   needs the one-time `hyprland.lua` wiring in step 3 below — without it,
   Hyprland never loads the generated rules, so pinning silently does
   nothing.
3. **Live workspace-navigation awareness** is a background watcher (the
   service tails Hyprland's IPC event socket via `socat`, if installed): the
   moment you switch to a workspace that belongs to some context — even with
   plain `SUPER+N`, not through this plugin at all — it applies that
   context's wallpaper/color scheme. This is separate from pinning; it
   reacts to *you* navigating, not to a window appearing.

The bar widget and panel are just the UI on top of this: the widget shows
the active context's glyph, and the panel is the only place you create,
edit, launch, or delete contexts (there is no config-file workflow for
contexts themselves — only the generated pin file is a real file on disk).

The opt-in Pomodoro integration is a fourth, independent trigger: it calls
the exact same "apply this context's wallpaper/color scheme" code as live
navigation, just triggered by a signal from the Pomodoro Timer plugin
instead of a workspace switch.

## Setup
1. Enable the plugin and add the bar widget.
2. Open the panel (click the widget) and create a context: name, glyph,
   optional wallpaper path and color scheme, and one row per app (label,
   launch command, window class regex, workspace number, and whether to pin
   it).
3. Add this once to `~/.config/hypr/hyprland.lua`, near your other `require`s:
   ```lua
   local cwPath = os.getenv("HOME") .. "/.config/hypr/contextual-workspaces.lua"
   local cwFile = io.open(cwPath, "r")
   if cwFile then
       cwFile:close()
       require("contextual-workspaces")
   end
   ```
   This file is generated and rewritten by the plugin every time you save a
   context (never hand-edit it) — the guard just avoids an error before the
   plugin has run once.
4. Save a context in the panel. With "Auto-reload Hyprland" on (default), the
   plugin runs `hyprctl reload` for you so pins take effect immediately.

Optionally bind a context launch to a key, in `hyprland.lua`:
```lua
hl.bind(mainMod .. " + ALT + 1", hl.dsp.exec_cmd(
  "noctalia msg plugin rnguyen03/contextual-workspaces:service all launch <context-id>"))
```
(Context IDs are shown by editing a context — currently `ctx-<timestamp>`.)

### Pomodoro Timer integration
1. Enable `React to Pomodoro Timer` in this plugin's settings.
2. Set `Focus context ID` and/or `Break context ID` to the ID of an existing
   context (find a context's ID by editing it in the panel).
3. Make sure `Switch wallpaper with context` and/or `Switch color scheme with
   context` are enabled — the pomodoro nudge reuses those same toggles.

## Window class regex
The class field matches Hyprland's `windowrulev2`-style class matching, e.g.
`^(kitty)$` for an exact match on the `kitty` window class. Use `hyprctl
clients -j` to find a running app's class if you're not sure.

## Plugin
| Field | Value |
| --- | --- |
| ID | `rnguyen03/contextual-workspaces` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

## Requirements
- `hyprctl` (part of Hyprland).
- (optional) `socat`, for live workspace-navigation awareness — it tails
  Hyprland's IPC event socket. Without it, that feature is silently disabled;
  explicit context launches still work.

## Settings
| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `auto-reload-hyprland` | `bool` | `true` | Run `hyprctl reload` automatically after saving a context so workspace pins take effect immediately. |
| `hyprland-rules-file` | `string` | `~/.config/hypr/contextual-workspaces.lua` | Where the generated window-rule include is written. |
| `enable-wallpaper-switch` | `bool` | `true` | Apply a context's wallpaper on launch and on live workspace-navigation switching. |
| `enable-theme-switch` | `bool` | `false` | Apply a context's color scheme the same way. Off by default since it affects the whole shell's palette. |
| `auto-switch-on-workspace-change` | `bool` | `true` | Apply wallpaper/color scheme when you navigate to one of a context's workspaces manually. |
| `enable-pomodoro-integration` | `bool` | `false` | React to work/break transitions from `thepunkoff/pomodoro`. |
| `pomodoro-focus-context-id` | `string` | (empty) | Context to switch to when a Pomodoro work session starts. |
| `pomodoro-break-context-id` | `string` | (empty) | Context to switch to when a Pomodoro break session starts. |

## IPC
```sh
# Launch a context by ID
noctalia msg plugin rnguyen03/contextual-workspaces:service all launch <context-id>
```

`pomodoro-state` is also accepted (sent by `thepunkoff/pomodoro`, not meant to
be called manually): a JSON payload `{"isRunning": bool, "stage": 1|2}`, acted
on only when `enable-pomodoro-integration` is on.

## Notes
- Every context save regenerates `hyprland-rules-file` (a small, clearly
  labeled, plugin-owned include — never `hyprland.lua` itself) and, unless
  disabled, runs `hyprctl reload`.
- Launching a context runs `hyprctl dispatch` once per app member, plus
  `noctalia msg color-scheme-set` when color-scheme switching is enabled for
  that context.
- Contexts are stored as JSON in this plugin's data directory, not in
  `plugin.toml` settings (the manifest has no nested-object setting type).
- With `socat` available, the service holds one long-lived subprocess tailing
  Hyprland's IPC event socket for the lifetime of the plugin.

## Licensing
MIT License.

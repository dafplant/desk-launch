# desk-launch

A small command-line app that opens a set of apps on specific desktops, across
specific displays, with pauses in between — and picks a different plan depending
on which external display is attached.

```
Slack, Mail        → built-in, desktop 1   (wait 3s)
Spotify            → built-in, desktop 3   (wait 3s)
Helium             → external, desktop 1   (wait 3s)
Ghostty            → external, desktop 2
```

## Install

Requires macOS 13 or newer, and the Xcode Command Line Tools
(`xcode-select --install`) to build.

```sh
git clone https://github.com/dafplant/desk-launch.git desk-launch
cd desk-launch
./install.sh
```

That builds a release binary, symlinks it to `~/.local/bin/desk-launch`, and
creates `~/.config/desk-launch/config.json` from `config.example.json` if you
don't have one. The example profiles match a BenQ at home and any other BenQ at
work — change `externalName` (or use `externalUUID`) to match your own monitors.
`desk-launch --list-displays -v` prints every monitor's name, UUID, vendor,
model and serial.

Then add an alias (optional):

```sh
echo "alias desk='$HOME/.local/bin/desk-launch'" >> ~/.zshrc
```

## One-time permission

Switching desktops needs **Accessibility** permission for the app that runs the
command — your terminal (Ghostty, iTerm, Terminal), not `desk-launch` itself.
If you trigger it from Raycast or Tinycast instead, that app needs the grant; see
[Launching from Raycast or Tinycast](#launching-from-raycast-or-tinycast).

1. Run `desk-launch` once. macOS shows a permission prompt.
2. Or add it manually: **System Settings → Privacy & Security → Accessibility**.
3. Quit and reopen the terminal after granting.

Verify everything with:

```sh
desk-launch --doctor
desk-launch --test-desktops   # switches through your desktops and back, launches nothing
desk-launch --dry-run         # shows the plan without touching anything
```

## How display-dependent plans work

Each profile has a `when` block. The **first profile whose conditions all match**
the connected displays is used. Display names, serials and UUIDs are stable per
monitor, so "BenQ at home, BenQ at work" is just two profiles.

```json
{
  "name": "work-benq",
  "when": { "externalName": "BenQ*" },
  "steps": [ ... ]
}
```

`when` predicates (all ANDed):

| Key | Matches |
| --- | --- |
| `externalName` | glob against the external display's name (`"BenQ*"`, `"BenQ PD2706U"`) |
| `externalVendor` | glob against vendor id (`"0x1e6d"`) or name (`"LG"`) |
| `externalModel` | glob against the model id (`"0x1015"` or `"4117"`) |
| `externalUUID` | glob against the display UUID (most precise) |
| `externalSerial` | glob against the serial number |
| `builtinPresent` | `true` / `false` — `false` is clamshell mode |
| `minExternal` / `maxExternal` | how many external displays are attached |
| `anyExternal` | `true` / `false` |
| `isCatchAll` | `true` — matches anything; keep it last |

Run `desk-launch --list-displays -v` to see exactly what your monitors report:
name, UUID, vendor, model and serial.

## Two monitors of the same brand

Vendor can't separate two BenQs, and `"externalName": "BenQ*"` matches both. The
remaining keys increase in specificity:

| Key | Distinguishes | Caveat |
| --- | --- | --- |
| `externalName` | models, if the name includes the model | falls back to a generic name on some cables/adapters |
| `externalModel` | two different models | useless for two units of one model |
| `externalSerial` | individual units | some monitors report `0` or duplicate it |
| `externalUUID` | individual units | changes if the monitor is replaced or its EDID board is |

The pattern that always works: pin the monitor you know by UUID, and let a
broader profile catch the other. Order matters — first match wins.

```json
{ "name": "home-benq", "when": { "externalUUID": "9F10C41E-3CAC-498B-AC47-D3F4BED7C94B" }, "steps": [ ... ] },
{ "name": "work-benq", "when": { "externalName": "BenQ*" }, "steps": [ ... ] }
```

Once you're at the office, `--list-displays -v` gives you that unit's UUID too,
and you can pin both — then neither profile depends on being tried first.

If no profile matches, the run stops with an error listing the connected
displays. Keep a `{ "isCatchAll": true }` profile as the fallback.

## Steps

| Key | Meaning |
| --- | --- |
| `app` | Bundle id (`com.apple.mail`), name (`Mail`) or path (`/Applications/Mail.app`) |
| `display` | `builtin`, `external`, `main`, a name glob, or a UUID. Default `main` |
| `desktop` | 1-based desktop number on that display. Default `1` |
| `wait` | Seconds to wait **after** this step finishes (default from `defaults.wait`) |
| `quitFirst` | Quit an already-running app before launching it |

Global `defaults`:

| Key | Default | Meaning |
| --- | --- | --- |
| `wait` | `0` | Default per-step wait |
| `windowTimeout` | `10` | Max seconds to wait for a window to appear |
| `settle` | `0.8` | Pause after a desktop switch, before launching |
| `fallbackToMain` | `true` | If a step's display is missing, use the main display |
| `quitFirst` | `false` | Default for `quitFirst` |

## Capturing a profile from the current screen

Instead of writing steps by hand, save what is on screen right now:

```sh
desk-launch capture --name home
```

```
On screen now
  1. Slack → Built-in Retina Display, desktop 1
  2. Mail → Built-in Retina Display, desktop 1
  3. Helium → BenQ PD2706U, desktop 1
  4. Ghostty → BenQ PD2706U, desktop 1

Created profile "home"
  ✓ Wrote ~/.config/desk-launch/config.json
```

It records every app with a visible window, the display it sits on, and that
display's current desktop, then derives a `when` block from the displays you
have attached — so running `capture` at home and at work produces two profiles
that pick themselves. New profiles are inserted before any catch-all, since
matching is first-match-wins.

| Flag | Effect |
| --- | --- |
| `--all-desktops` | Include windows on desktops that aren't currently visible |
| `--merge` | Add the current screen to an existing profile, skipping duplicates |
| `--from-profile <name>` | Copy another profile's steps, rebind to the current displays |
| `--print-only` | Show the resulting JSON without writing |
| `--exclude <bundle-id>` | Skip an app (repeatable) |

Each step gets the desktop the window actually lives on, read from the window
server — so an app sitting on desktop 2 of the external display is recorded as
desktop 2 even when you're looking at desktop 1. By default only what is visible
is captured; `--all-desktops` takes the whole arrangement in one pass.

**Capture rewrites the config file** in normalised JSON. Valid, but your blank
lines and grouping are not preserved.

## What it does, step by step

1. Reads the connected displays, and the desktop layout from `com.apple.spaces`.
2. Picks a profile.
3. For each step: moves the pointer onto the target display, presses
   <kbd>Ctrl</kbd>+<kbd>N</kbd> to show desktop N there, launches the app,
   waits for a window on that display, then sleeps for `wait`.
4. Restores the pointer to where it was.

## Honest limitations

- **macOS has no *public* API for Spaces.** Desktops are switched with the
  "Switch to Desktop" shortcut, which acts on the display under the pointer.
  If you have rebound or disabled those shortcuts, `--doctor` will say so.
  Reading the layout and each window's desktop uses the window server's private
  calls (the same ones Mission Control uses), falling back to `com.apple.spaces`
  — whose `Current Space` value is written lazily and can be stale.
- **Only 9 desktops** are reachable (Ctrl+1…9).
- **Desktops must already exist.** New spaces can't be created by script; add
  them once in Mission Control and the config will use them. A step asking for a
  desktop that doesn't exist is clamped to the last one, with a warning.
- **Already-running apps** get activated, not moved: macOS cannot drag an
  existing window to another desktop. New windows land on the target desktop.
  Set `"quitFirst": true` on a step to get a fresh window every time.
- **The first window wait can be slow**: cold starts (Slack, Spotify) can exceed
  `windowTimeout`; the app still launches, you just get a warning.

## Launching from Raycast or Tinycast

`commands/` holds four Raycast-format script commands. Both launchers read that
format, so there's nothing to configure per command:

| Command | Runs |
| --- | --- |
| Desk Launch | `desk-launch` |
| Desk Launch (dry run) | `desk-launch --dry-run` |
| Desk Launch (doctor) | `desk-launch --doctor` |
| Desk Launch (capture) | `desk-launch capture --name <profile>` (asks for the name) |

### Raycast

1. Search **Script Commands** → **Add Script Directory** → choose
   `~/projects/desk-launch/commands` (wherever you cloned it).
2. Grant Raycast Accessibility: **System Settings → Privacy & Security →
   Accessibility**. It may already have it for other features.
3. Find "Desk Launch" in Raycast, press <kbd>⌘</kbd><kbd>K</kbd> → **Add Hotkey**
   (or **Configure Command** for an alias).

Raycast watches the folder, so edited scripts and new ones appear without adding
anything again.

### Tinycast

1. **Settings → Commands** → enable Custom Commands (off out of the box).
2. **Import Raycast Scripts** → choose the same `commands/` folder.
3. **Settings → Shortcuts** → search "Desk Launch" → record a hotkey.
4. Grant Tinycast Accessibility: **System Settings → Privacy & Security →
   Accessibility**.

Import is a one-shot copy, not a watched folder: after importing, editing these
files changes nothing until you delete the entries and import again.

### Which app needs the permission?

Whichever app spawns the command — Raycast, Tinycast, or your terminal. The grant
follows the parent process, so granting your terminal does nothing for a launcher
hotkey. Run **Desk Launch (doctor)** *from that launcher*: its output reports the
grant that actually applies, while a terminal run reports the terminal's.

## Running it automatically

- **At login**: System Settings → General → Login Items → add a small wrapper
  script, or a `launchd` agent running it at login.
- **Apple Shortcuts**: "Run Shell Script" → `~/.local/bin/desk-launch`, with a
  keyboard shortcut or a login automation.

## Layout

```
Sources/DeskLaunch/
  main.swift        CLI, profile selection, execution loop
  Config.swift      JSON schema
  Displays.swift    display enumeration and matching
  Spaces.swift      desktop layout + Ctrl+N switching
  Launch.swift      app resolution, launch, window detection
  Capture.swift     build a profile from what is on screen
  Support.swift     helpers
config.example.json example config (home BenQ / work BenQ / fallback)
commands/           Raycast-format script commands, for Raycast and Tinycast
install.sh          build + symlink + install config
```

## License

MIT — see [LICENSE](LICENSE).

## Upgrading an existing install

```sh
cd desk-launch
git pull
./install.sh
```

`install.sh` keeps `~/.config/desk-launch/config.json` and rebuilds the binary.
Pulling alone is not enough: `~/.local/bin/desk-launch` is a symlink into
`.build/`, so the old binary keeps running until it is rebuilt. Commands already
added to Raycast or Tinycast point at that same path and keep working, and
Accessibility grants survive.

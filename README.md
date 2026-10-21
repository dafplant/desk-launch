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
don't have one. The example profiles are matched against a BenQ at home and an
LG at work — change `externalName` in each profile to match your own monitors
(`desk-launch --list-displays` prints their names).

Then add an alias (optional):

```sh
echo "alias desk='$HOME/.local/bin/desk-launch'" >> ~/.zshrc
```

## One-time permission

Switching desktops needs **Accessibility** permission for the app that runs the
command — your terminal (Ghostty, iTerm, Terminal), not `desk-launch` itself.

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
the connected displays is used. Display names, vendor ids and UUIDs are all
stable per monitor, so "BenQ at home, LG at work" is just two profiles.

```json
{
  "name": "work-lg",
  "when": { "externalName": "LG*" },
  "steps": [ ... ]
}
```

`when` predicates (all ANDed):

| Key | Matches |
| --- | --- |
| `externalName` | glob against the external display's name (`"BenQ*"`, `"LG*"`) |
| `externalVendor` | glob against vendor id (`"0x1e6d"`) or name (`"LG"`) |
| `externalUUID` | glob against the display UUID (most precise) |
| `externalSerial` | glob against the serial number |
| `builtinPresent` | `true` / `false` — `false` is clamshell mode |
| `minExternal` / `maxExternal` | how many external displays are attached |
| `anyExternal` | `true` / `false` |
| `isCatchAll` | `true` — matches anything; keep it last |

Run `desk-launch --list-displays` to see exactly what your monitors report.

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

## Running it from Tinycast

`commands/` holds three Raycast-format script commands, which Tinycast imports as
custom commands (Settings → Commands → Import Raycast Scripts → pick that folder):

| Command | Runs |
| --- | --- |
| Desk Launch | `desk-launch` |
| Desk Launch (dry run) | `desk-launch --dry-run` |
| Desk Launch (doctor) | `desk-launch --doctor` |
| Desk Launch (capture) | `desk-launch capture --name <profile>` |

Import is a one-shot copy: after importing, editing these files changes nothing
until you import again (delete the old entries first).

Custom Commands is off out of the box — enable it in **Settings → Commands**.
Then record a hotkey in **Settings → Shortcuts**.

Because Tinycast spawns the command, **Tinycast** needs Accessibility, not
Ghostty. `desk-launch --doctor` run from a terminal reports the terminal's grant,
which is a different thing — run the doctor command *from Tinycast* to see the
grant that actually matters.

## Running it automatically

It's just a command, so bind it however you like:

- **Apple Shortcuts**: "Run Shell Script" → `~/.local/bin/desk-launch`, assign a
  keyboard shortcut or run it at login.
- **Login item**: System Settings → General → Login Items → add a small wrapper
  script, or a `launchd` agent running it at login.
- **Hotkey**: any launcher that can run a shell command (Tinycast, Alfred, Raycast).

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
config.example.json example config (home BenQ / work LG / fallback)
commands/           Raycast-format script commands, imported by Tinycast
install.sh          build + symlink + install config
```

## License

MIT — see [LICENSE](LICENSE).

#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Desk Launch
# @raycast.mode fullOutput
# @raycast.icon 🖥️
# @raycast.packageName desk-launch
# @raycast.description Open apps on their configured desktops for the connected display
# @raycast.author chrisplant

exec "$HOME/.local/bin/desk-launch" "$@"

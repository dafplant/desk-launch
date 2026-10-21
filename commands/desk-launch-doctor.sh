#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Desk Launch (doctor)
# @raycast.mode fullOutput
# @raycast.icon 🩺
# @raycast.packageName desk-launch
# @raycast.description Check displays, desktops, Accessibility grant and shortcuts
# @raycast.author chrisplant

exec "$HOME/.local/bin/desk-launch" --doctor "$@"

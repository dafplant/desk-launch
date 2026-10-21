#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Desk Launch (capture)
# @raycast.mode fullOutput
# @raycast.icon 📸
# @raycast.packageName desk-launch
# @raycast.description Save what is on screen now as a profile
# @raycast.argument1 { "type": "text", "placeholder": "Profile name" }
# @raycast.author chrisplant

exec "$HOME/.local/bin/desk-launch" capture --name "$1"

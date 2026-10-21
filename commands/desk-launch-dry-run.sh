#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Desk Launch (dry run)
# @raycast.mode fullOutput
# @raycast.icon 🧪
# @raycast.packageName desk-launch
# @raycast.description Show what Desk Launch would do, without touching anything
# @raycast.author chrisplant

exec "$HOME/.local/bin/desk-launch" --dry-run "$@"

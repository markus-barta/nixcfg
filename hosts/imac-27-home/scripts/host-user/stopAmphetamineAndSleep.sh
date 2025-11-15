#!/bin/bash

# Stop Amphetamine session by running AppleScript in the user's GUI context
USER_GUI_ID=$(id -u markus)
sudo launchctl asuser "$USER_GUI_ID" osascript -e 'tell application "Amphetamine" to end session'

# Echo message before initiating sleep
echo "Going to sleep via script..."

# wait for sound to play (if any)
sleep 1

# Put Mac to sleep
sudo pmset sleepnow

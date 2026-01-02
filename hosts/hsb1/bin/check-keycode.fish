#!/usr/bin/env fish
# Check what keycode is ACME BK03 keyboard sending
# Usage: check-keycode

nix-shell -p "python3.withPackages (ps: [ evdev ])" --run 'python3 -c "import evdev; dev = evdev.InputDevice(\"/dev/input/event0\"); print(\"Press: key now...\"); [print(evdev.categorize(e)) for e in dev.read_loop() if e.type == 1]"'

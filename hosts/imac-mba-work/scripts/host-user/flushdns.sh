#!/bin/bash
# Flush macOS DNS cache
# Usage: flushdns.sh

sudo killall -HUP mDNSResponder
echo "macOS DNS Cache Reset"


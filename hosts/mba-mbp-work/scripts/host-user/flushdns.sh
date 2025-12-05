#!/bin/bash
# Flush macOS DNS cache
sudo killall -HUP mDNSResponder
echo "macOS DNS Cache Reset"

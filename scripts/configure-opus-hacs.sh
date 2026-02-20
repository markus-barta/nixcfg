#!/usr/bin/env bash
set -e

echo "We will configure mosquitto on hsb1 to bridge to the OPUS gateway."
echo "1. First, we need to decrypt your agenix secret to get the password (STREAM_PASS)."

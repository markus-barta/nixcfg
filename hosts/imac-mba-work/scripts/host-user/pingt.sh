#!/bin/bash
# Timestamped ping - adds timestamp to each ping response
# Usage: pingt.sh <host>
#
# Example output:
#   [2025-11-27 14:32:01] 64 bytes from 8.8.8.8: icmp_seq=1 ttl=117 time=12.3 ms

if [ -z "$1" ]; then
    echo "Usage: pingt.sh <host>"
    exit 1
fi

/sbin/ping "$@" | while read line; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line"
done


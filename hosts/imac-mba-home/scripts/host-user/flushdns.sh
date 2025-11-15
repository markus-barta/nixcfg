#!/bin/bash
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder

# exit without errors
exit 0

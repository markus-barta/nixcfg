#!/usr/bin/env bash

canonicalize_ed25519_public_key() {
  [ "$#" -eq 2 ] || return 2
  local source_file=$1
  local destination_file=$2

  [ -f "$source_file" ] && [ ! -L "$source_file" ] || return 1
  awk '
    NR != 1 {
      valid = 0
      exit
    }
    $1 == "ssh-ed25519" && $2 ~ /^[A-Za-z0-9+\/]+={0,3}$/ {
      print $1 " " $2
      valid = 1
    }
    END {
      exit(valid && NR == 1 ? 0 : 1)
    }
  ' "$source_file" >"$destination_file"
}

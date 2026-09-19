#!@shell@
# shellcheck shell=bash disable=SC2239 # @shell@ is substituted with the Nix bash at build time
# NIX-516 — $out/bin/{cursor-agent,agent}. Passes --disable-auto-update, the
# hidden root option that stops the vendor background updater, without moving
# argv[2]: the bundle reads that raw for the ACP surface and for the Cursor
# IDE's `agent` alias. After a leading word (subcommand or prompt) the root
# program still consumes the option, so it goes there; before an option it
# goes first. `help` and `bedrock` read argv by position for the Bedrock help
# and never start a chat, so they pass unchanged.
#
# Each name execs the launcher through its own link: the launcher exports
# CURSOR_INVOKED_AS from its $0, so `agent` stays `agent`.
libexec=@libexec@
name=${0##*/}
[ "$name" = agent ] || name=cursor-agent
launcher=$libexec/$name

case "${1-}" in
help | bedrock)
  exec "$launcher" "$@"
  ;;
"" | -*)
  exec "$launcher" --disable-auto-update "$@"
  ;;
*)
  first=$1
  shift
  exec "$launcher" "$first" --disable-auto-update "$@"
  ;;
esac

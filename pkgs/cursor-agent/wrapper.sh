#!@shell@
# shellcheck shell=bash disable=SC2239 # @shell@ is substituted with the Nix bash at build time
# NIX-516 — $out/bin/{cursor-agent,agent}. Passes --disable-auto-update, the
# hidden root option that stops the vendor background updater (it runs only in
# chat runs), without changing what the bundle's raw argv parsers see. Those
# (persist management and restore, the ACP surface, the Cursor IDE `agent`
# alias, Bedrock help) all key on a word at argv[2], so the flag is added only
# where that word cannot change:
# - no arguments, or an option first (interactive, `-p`, Pi's `--print`,
#   agentd's `--model <m> acp`): the flag goes first;
# - `resume`, `ls` (chat commands no raw parser reads): after their name;
#   `sandbox` gets the flag there too, harmlessly: it does not load the chat
#   chunk containing the background updater guard;
# - anything else passes unchanged, including a prompt given first, which then
#   still auto-updates, and the internal `--cursor-persist-restore <id> <name>`
#   re-exec, which the persist parser recognises only as exactly three words.
#
# Each name execs the launcher through its own link: the launcher exports
# CURSOR_INVOKED_AS from its $0, so `agent` stays `agent`.
libexec=@libexec@
name=${0##*/}
[ "$name" = agent ] || name=cursor-agent
launcher=$libexec/$name

case "${1-}" in
--cursor-persist-restore)
  exec "$launcher" "$@"
  ;;
"" | -*)
  exec "$launcher" --disable-auto-update "$@"
  ;;
resume | ls | sandbox)
  first=$1
  shift
  exec "$launcher" "$first" --disable-auto-update "$@"
  ;;
*)
  exec "$launcher" "$@"
  ;;
esac

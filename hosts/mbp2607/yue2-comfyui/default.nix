# NIX-518 — host tooling for the local YuE2 + ComfyUI music stack.
#
# The stack itself (~11 GB: upstream ComfyUI clone, model weights, venv, logs)
# stays an unversioned runtime under ~/Code/yue2-comfyui. Only the authored
# tooling lives here, linked into its original place so the runtime layout is
# unchanged:
#   - bin/yue2-comfyui              start | stop | status wrapper (resolves the
#                                   stack as its own parent directory)
#   - workflows/yue2_full.json      synced into ComfyUI's workflows on start
#   - custom_nodes/yue2_autoload    opens that workflow when the UI starts
#                                   (copied as regular files, see below)
#   - the `yue2` fish command       (was an orphaned stash, 2026-09-17)
# Setup, usage, license and uninstall notes: PPM NIX runbook `yue2-comfyui-mac`.
# Uninstalling means dropping this import BEFORE deleting the stack directory,
# or the next switch re-creates the links. The autoload node files are copies,
# not links: they stay until the runtime tree is deleted.
#
# `yue2 on` / `start` opens the UI in the default browser, except inside a
# guarded agent session (INSPR_AGENT_BROWSER_GUARD set), where it only prints
# the URL (NIX-445). Agents should still prefer `yue2 status`.
{ lib, ... }:

let
  root = "Code/yue2-comfyui";
in
{
  programs.fish.functions.yue2 = {
    description = "YuE2 ComfyUI: start|stop|status (+ --autostop / --idle-stop)";
    body = ''
      set -l bin ~/${root}/bin/yue2-comfyui
      if not test -x $bin
        echo "missing $bin" >&2
        return 1
      end
      if test (count $argv) -eq 0
        $bin status
        return
      end
      switch $argv[1]
        case on up
          $bin start $argv[2..-1]
        case off down
          $bin stop
        case '*'
          $bin $argv
      end
    '';
  };

  home.file = {
    "${root}/bin/yue2-comfyui" = {
      source = ./yue2-comfyui;
      executable = true;
    };
    "${root}/workflows/yue2_full.json".source = ./yue2_full.json;
  };

  # The autoload node must be REGULAR files, not home.file symlinks: ComfyUI
  # serves extension JS through aiohttp static with follow_symlinks=False, so a
  # link into /nix/store answers 404 and the autoload silently stops working.
  # Copy them on every switch, and only into an existing runtime tree.
  # After linkGeneration, so HM's own link cleanup can never remove the copies;
  # `rm -f` first so a leftover store symlink is replaced, not written through.
  # A re-cloned runtime gets the node on the next switch.
  home.activation.yue2AutoloadNode = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    comfy="$HOME/${root}/ComfyUI"
    if [ -d "$comfy/custom_nodes" ]; then
      node="$comfy/custom_nodes/yue2_autoload"
      $DRY_RUN_CMD mkdir -p "$node/js"
      $DRY_RUN_CMD rm -f "$node/__init__.py" "$node/js/yue2_autoload.js"
      $DRY_RUN_CMD install -m 0644 ${./yue2_autoload/__init__.py} "$node/__init__.py"
      $DRY_RUN_CMD install -m 0644 ${./yue2_autoload/js/yue2_autoload.js} "$node/js/yue2_autoload.js"
    else
      echo "yue2: no ComfyUI runtime at $comfy; autoload node not installed" >&2
    fi
  '';
}

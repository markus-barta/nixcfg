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
#   - the `yue2` fish command       (was an orphaned stash, 2026-09-17)
# Setup, disk layout and uninstall notes: PPM OPS runbook `yue2-comfyui-mbp2607`.
#
# `yue2 on` / `start` opens the UI in the default browser. Agent sessions must
# never run it (NIX-445); `yue2 status` is the safe check.
{ ... }:

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
    "${root}/ComfyUI/custom_nodes/yue2_autoload/__init__.py".source = ./yue2_autoload/__init__.py;
    "${root}/ComfyUI/custom_nodes/yue2_autoload/js/yue2_autoload.js".source =
      ./yue2_autoload/js/yue2_autoload.js;
  };
}

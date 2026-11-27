# OPS-737: account-local operator markers, only after an explicit opt-in.
# Enable with inspr.aeonOperatorMac.enable = true in the operator's HM module,
# then commit before switching: inventory provenance requires a clean self.rev.
# Disabling removes the four HM links; agent-kernel.nix restores Claude's
# upstream inline marker writer and preserves personal text outside the block.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.inspr.aeonOperatorMac;
  kernel = config.inspr.agent-kernel;
  validRev = rev: builtins.isString rev && builtins.match "[0-9a-f]{40}" rev != null;
  selfRev = inputs.self.rev or null;
  publicRev = inputs.inspr-modules.rev or null;
  revisionMessage = "inspr.aeonOperatorMac.enable requires clean flake revisions (40 hex): inputs.self.rev and inputs.inspr-modules.rev; commit the nixcfg tree before enabling.";
  inventory =
    assert lib.assertMsg (validRev selfRev && validRev publicRev) revisionMessage;
    {
      kernel_root = config.home.homeDirectory;
      kernel_files = [
        {
          repository = "inspr-at/inspr-modules";
          commit = publicRev;
          path = "docs/AGENTS-KERNEL.md";
          relative_file = ".claude/kernel/AGENTS-KERNEL.md";
        }
        {
          repository = "markus-barta/nixcfg";
          commit = selfRev;
          path = "modules/uzumaki/agent-kernel-private.md";
          relative_file = ".claude/kernel/AGENTS-KERNEL-PRIVATE.md";
        }
      ];
    };
  # Match the pinned upstream marker writer's pre/post preservation logic.
  markerScript = pkgs.writeText "aeon-operator-claude-markers.py" ''
    import pathlib, sys
    dest = pathlib.Path(sys.argv[1])
    payload = pathlib.Path(sys.argv[2]).read_text()
    begin = "<!-- inspr.agent-kernel BEGIN -->"
    end = "<!-- inspr.agent-kernel END -->"
    block = begin + "\n" + payload.rstrip() + "\n" + end + "\n"
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists():
        dest.write_text(block)
        raise SystemExit(0)
    text = dest.read_text()
    if begin in text and end in text:
        pre = text.split(begin, 1)[0]
        post = text.split(end, 1)[1]
        if post.startswith("\n"):
            post = post[1:]
        dest.write_text(pre + block + post)
    else:
        dest.write_text(block + "\n" + text)
  '';
  importsFile = pkgs.writeText "aeon-operator-claude-imports" ''
    @~/.claude/kernel/AGENTS-KERNEL.md
    @~/.claude/kernel/AGENTS-KERNEL-PRIVATE.md
  '';
in
{
  options.inspr.aeonOperatorMac.enable = lib.mkEnableOption "AEON operator Mac account markers and Claude kernel imports";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = validRev selfRev && validRev publicRev;
        message = revisionMessage;
      }
      {
        assertion =
          kernel.enable
          && toString kernel.source == inputs.inspr-modules.outPath + "/docs/AGENTS-KERNEL.md"
          && kernel.extraSources == [ ./agent-kernel-private.md ]
          && !(kernel.markerHarnesses ? claude);
        message = "AEON operator Claude imports require the pinned public source, the single nixcfg private source, and no Claude marker harness.";
      }
    ];

    home.file = {
      ".config/aeon/operator-macs".text = "";
      ".claude/kernel/AGENTS-KERNEL.md".source = kernel.source;
      ".claude/kernel/AGENTS-KERNEL-PRIVATE.md".source = ./agent-kernel-private.md;
      ".aeon-operator-kernel.json".text = builtins.toJSON inventory;
    };

    home.activation.aeonOperatorClaudeImports = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.python3}/bin/python3 ${markerScript} "$HOME/.claude/CLAUDE.md" ${importsFile}
    '';
  };
}

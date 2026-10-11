{ root }:
let
  flake = builtins.getFlake (toString root);
  host = flake.homeConfigurations."mba@mbp2606";
  cfg = host.config.services.aeonRemoteGuard;
  hookPath = "${cfg.repo}/hooks/pre-receive";
  hook = host.config.home.file.${hookPath};
in
{
  checks = {
    enabled = cfg.enable;
    defaultDisabled = !host.options.services.aeonRemoteGuard.enable.default;
    repo = cfg.repo == "${host.config.home.homeDirectory}/aeon-remote.git";
    hold = cfg.holdFile == "${host.config.home.homeDirectory}/.hold-mbp2606";
    policy = cfg.policyFile == "${host.config.home.homeDirectory}/.aeon-remote-policy";
    maxload = cfg.defaultMaxLoad == 12;
    stale = cfg.staleSeconds == 900;
    package = builtins.any (p: (p.name or "") == "aeon-remote-guard") host.config.home.packages;
    hook = hook.enable && hook.executable && hook.source != null;
    target = hook.target == "aeon-remote.git/hooks/pre-receive";
  };
  hookSource = toString hook.source;
}

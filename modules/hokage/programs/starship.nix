{
  config,
  inputs,
  lib,
  ...
}:
let
  inherit (config) hokage;
  cfg = hokage.programs.starship;

  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;

  # Shared Tokyo Night starship config
  sharedStarshipConfig = builtins.fromTOML (builtins.readFile ../../shared/starship.toml);
in
{
  options.hokage.programs.starship = {
    enable = mkEnableOption "Enable Starship support" // {
      default = true;
    };
    useSharedConfig = mkOption {
      type = types.bool;
      default = true;
      description = "Use shared Tokyo Night starship config from modules/shared/starship.toml";
    };
  };

  config = lib.mkIf cfg.enable {
    # https://rycee.gitlab.io/home-manager/options.html
    home-manager.users = lib.genAttrs hokage.usersWithRoot (_userName: {
      # enable https://starship.rs
      programs.starship =
        let
          flavour = "mocha"; # One of `latte`, `frappe`, `macchiato`, or `mocha`
          
          # Legacy catppuccin config (used when useSharedConfig = false)
          legacySettings = {
            directory = {
              truncation_length = 5;
              truncate_to_repo = false;
              style = "bold sky";
            };
            git_branch = {
              style = "bold pink";
            };
            username = {
              disabled = false;
              show_always = true;
            };
            character = {
              success_symbol = "[➜](bold green)";
              error_symbol = "[✗](bold red)";
            };
            hostname = {
              ssh_only = false;
              format = "[$ssh_symbol$hostname]($style) ";
            };
            shell = {
              disabled = false;
              style = "gray";
              fish_indicator = "󰈺";
            };
            status.disabled = false;
            git_metrics.disabled = false;
            memory_usage.disabled = false;
            sudo.disabled = false;
            time = {
              disabled = false;
              format = "[$time]($style) ";
              time_format = "%d.%m.%Y %H:%M";
              style = "bold green";
            };
            format = "$all$time$directory$status$character";
            palette = "catppuccin_${flavour}";
          } // builtins.fromTOML (builtins.readFile "${inputs.catppuccin}/themes/${flavour}.toml");
        in
        {
          enable = true;
          enableFishIntegration = true;
          enableBashIntegration = true;

          # Use shared Tokyo Night config or legacy catppuccin
          settings = if cfg.useSharedConfig then sharedStarshipConfig else legacySettings;
        };
    });
  };
}

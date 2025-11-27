# Shared fish shell configuration for both NixOS and macOS
# Can be imported by both system configurations and Home Manager
{
  # Common fish shell aliases used across all systems
  fishAliases = {
    # Git aliases
    gitc = "git commit";
    gitps = "git push";
    gitplr = "git pull --rec";
    gitpl = "git pull && git submodule update --init";
    gitsub = "git submodule update --init";
    gitpls = "git pull";
    gita = "git add -A";
    gitst = "git status";
    gitd = "git diff";
    gitds = "git diff --staged";
    gitl = "git log";

    # Editor aliases
    vim = "nvim";

    # Utility aliases
    ll = "eza -hal --icons --group-directories-first";
    fish-reload = "exec fish";
    lg = "lazygit";
    duai = "dua interactive";
    j = "just";
  };

  # Common fish shell abbreviations used across all systems
  fishAbbrs = {
    killall = "pkill";
    less = "bat";
    man = "batman";
    du = "dua";
    ncdu = "dua interactive";
    df = "duf";
    tree = "erd";
    tmux = "zellij";
    dig = "dog";
    diff = "difft";
    ping = "pingt"; # not "gping"
    tar = "ouch";
    ps = "procs";
    whois = "rdap";
    vim = "hx";
    # nano = "micro"; # no one likes micro
  };

  # Common fish shell interactive init (functions, etc.)
  # Used across all systems via programs.fish.interactiveShellInit
  fishInteractiveShellInit = ''
    # Load environment variables from a .env file into current Fish session
    # Usage: sourcefish /path/to/.env
    function sourcefish --description 'Load env vars from .env file into Fish session'
      set file "$argv[1]"
      if test -z "$file"
        echo "Usage: sourcefish PATH_TO_ENV_FILE"
        return 1
      end
      if test -f "$file"
        for line in (cat "$file" | grep -v '^[[:space:]]*#' | grep .)
          set key (echo $line | cut -d= -f1)
          set val (echo $line | cut -d= -f2-)
          set -gx $key "$val"
        end
      else
        echo "File not found: $file"
        return 1
      end
    end

    # Default editor
    set -gx EDITOR nano
  '';
}

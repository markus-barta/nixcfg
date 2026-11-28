# OPS-737: real pinned module + nixcfg integration, inert HM/package surfaces.
# No derivations, store writes, builds, network, or user-home activation.
{
  nixpkgs,
  publicSource,
  selfRev,
  enabled ? null,
  doctrineEnabled ? null,
  legacy ? false,
  modulePath ? ../modules/uzumaki/agent-kernel.nix,
  hostHome ? null,
}:
let
  lib = (import (nixpkgs + "/lib")).extend (
    _: _: {
      hm.dag.entryAfter = after: data: {
        inherit after data;
        before = [ ];
      };
    }
  );
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  inputs = {
    self = lib.optionalAttrs (selfRev != null) { rev = selfRev; };
    inspr-modules = {
      outPath = publicSource;
      rev = lock.nodes.inspr-modules.locked.rev;
      homeManagerModules.agent-kernel = publicSource + "/modules/home-manager/agent-kernel.nix";
    };
  };
  # Preserve generated text for executing the exact evaluated marker writers.
  pkgs = {
    python3 = "/fixture/python3";
    writeText = name: text: "OPS737_ASSET_${name}_BEGIN\n${text}OPS737_ASSET_${name}_END";
  };
  previous = {
    imports = [ inputs.inspr-modules.homeManagerModules.agent-kernel ];
    inspr.agent-kernel = {
      enable = true;
      extraSources = [ ../modules/uzumaki/agent-kernel-private.md ];
      harnesses = {
        pi = ".pi/agent/AGENTS.md";
        grok = ".grok/AGENTS.md";
      };
      markerHarnesses = {
        codex = ".codex/AGENTS.md";
        claude = ".claude/CLAUDE.md";
      };
    };
    home.file = {
      ".pi/agent/prompts/inspr.md".source = "${publicSource}/commands/inspr.md";
      ".pi/agent/prompts/inspr-versioning.md".source = "${publicSource}/commands/inspr-versioning.md";
    };
  };
  evaluated = lib.evalModules {
    specialArgs = { inherit inputs pkgs; };
    modules = [
      (if legacy then previous else modulePath)
      {
        options = {
          assertions = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
          };
          home.file = lib.mkOption {
            type = lib.types.attrsOf lib.types.attrs;
            default = { };
          };
          home.activation = lib.mkOption {
            type = lib.types.attrsOf lib.types.attrs;
            default = { };
          };
          home.homeDirectory = lib.mkOption {
            type = lib.types.str;
            default = "/Users/operator";
          };
        };
      }
    ]
    # The same pinned integration also exercises OPS-754 without a host build.
    ++ lib.optional (enabled != null) { inspr.aeonOperatorMac.enable = enabled; }
    ++ lib.optional (doctrineEnabled != null) { inspr.doctrineCopies.enable = doctrineEnabled; }
    # Evaluate the real host's option definitions with the pinned module system.
    # Omit its infrastructure imports and ignore unrelated undeclared HM options;
    # lazy evaluation never demands packages, secrets, or activation derivations.
    ++ lib.optional (hostHome != null) (
      { config, ... }:
      {
        config = {
          _module.check = false;
        }
        // builtins.removeAttrs (import hostHome {
          inherit
            config
            inputs
            lib
            pkgs
            ;
        }) [ "imports" ];
      }
    );
  };
  cfg = evaluated.config;
in
if hostHome != null then
  {
    doctrineEnabled = cfg.inspr.doctrineCopies.enable;
    operatorEnabled = cfg.inspr.aeonOperatorMac.enable;
  }
else
  assert lib.assertMsg (lib.all (a: a.assertion) cfg.assertions) (
    lib.concatStringsSep "\n" (map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions))
  );
  {
    files = lib.mapAttrs (
      _: file:
      file
      // lib.optionalAttrs (file ? source) {
        source = toString file.source;
      }
    ) cfg.home.file;
    activation = cfg.home.activation;
    inherit (cfg.inspr.agent-kernel) markerHarnesses;
    inherit (cfg.inspr.agent-kernel) harnesses;
    kernelSources = map toString (
      [ cfg.inspr.agent-kernel.source ] ++ cfg.inspr.agent-kernel.extraSources
    );
  }

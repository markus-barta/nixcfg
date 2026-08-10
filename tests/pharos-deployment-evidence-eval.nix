let
  mkEvidence = import ../lib/pharos-deployment-evidence.nix;
  lockFile = ../flake.lock;
  lock = builtins.fromJSON (builtins.readFile lockFile);
  rootName = lock.root;
  nixpkgsTarget = lock.nodes.${rootName}.inputs.nixpkgs;
  nixpkgsNodeName =
    if builtins.isString nixpkgsTarget then nixpkgsTarget else builtins.head nixpkgsTarget;
  nixpkgsNode = lock.nodes.${nixpkgsNodeName};
  syntheticSelf = {
    rev = "1111111111111111111111111111111111111111";
  };
  syntheticNixpkgs = {
    inherit (nixpkgsNode.locked) rev lastModified;
  };

  evaluate = args: mkEvidence ({ inherit lockFile; } // args);
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;

  unsafeChannelLock = builtins.toFile "unsafe-channel-flake.lock" (
    builtins.toJSON (
      lock
      // {
        nodes = lock.nodes // {
          ${nixpkgsNodeName} = nixpkgsNode // {
            original = nixpkgsNode.original // {
              ref = "nixos-unstable/../../etc";
            };
          };
        };
      }
    )
  );
  malformedLock = builtins.toFile "malformed-flake.lock" (
    builtins.toJSON {
      version = 7;
      root = "root";
      nodes.root.inputs = { };
    }
  );
  validEvidence = evaluate {
    self = syntheticSelf;
    nixpkgs = syntheticNixpkgs;
  };
in
{
  evidence = validEvidence;
  checks = {
    revisionless_fails = fails (evaluate {
      self = { };
      nixpkgs = syntheticNixpkgs;
    });
    malformed_lock_fails = fails (mkEvidence {
      self = syntheticSelf;
      nixpkgs = syntheticNixpkgs;
      lockFile = malformedLock;
    });
    unsafe_channel_fails = fails (mkEvidence {
      self = syntheticSelf;
      nixpkgs = syntheticNixpkgs;
      lockFile = unsafeChannelLock;
    });
    input_revision_mismatch_fails = fails (evaluate {
      self = syntheticSelf;
      nixpkgs = syntheticNixpkgs // {
        rev = "0000000000000000000000000000000000000000";
      };
    });
    input_timestamp_mismatch_fails = fails (evaluate {
      self = syntheticSelf;
      nixpkgs = syntheticNixpkgs // {
        lastModified = syntheticNixpkgs.lastModified - 1;
      };
    });
  };
}

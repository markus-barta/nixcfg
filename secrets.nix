let
  rules = import ./secrets/secrets.nix;
  prefixed = builtins.listToAttrs (
    map (name: {
      name = "secrets/${name}";
      value = builtins.getAttr name rules;
    }) (builtins.attrNames rules)
  );
in
rules // prefixed

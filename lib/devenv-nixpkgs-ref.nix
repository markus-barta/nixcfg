let
  lock = builtins.fromJSON (builtins.readFile ../devenv.lock);

  edgeName =
    value:
    if builtins.isString value then
      value
    else if
      builtins.isList value && builtins.length value == 1 && builtins.isString (builtins.head value)
    then
      builtins.head value
    else
      throw "devenv lock input edge must resolve to exactly one node name";

  rootNode = lock.nodes.${lock.root} or (throw "devenv lock root node is missing");
  nixpkgsNodeName = edgeName (
    rootNode.inputs.nixpkgs or (throw "devenv lock root has no nixpkgs input")
  );
  nixpkgsNode = lock.nodes.${nixpkgsNodeName} or (throw "devenv nixpkgs node is missing");
  sourceNodeName =
    if nixpkgsNode.inputs ? nixpkgs-src then
      edgeName nixpkgsNode.inputs.nixpkgs-src
    else
      nixpkgsNodeName;
  sourceNode = lock.nodes.${sourceNodeName} or (throw "devenv nixpkgs source node is missing");
  locked = sourceNode.locked or (throw "devenv nixpkgs source is not locked");

  validPart = value: builtins.isString value && builtins.match "[A-Za-z0-9._-]+" value != null;
  validRevision =
    builtins.isString locked.rev
    && builtins.stringLength locked.rev == 40
    && builtins.match "[0-9a-f]+" locked.rev != null;
in
assert locked.type == "github";
assert validPart locked.owner;
assert validPart locked.repo;
assert validRevision;
"github:${locked.owner}/${locked.repo}/${locked.rev}"

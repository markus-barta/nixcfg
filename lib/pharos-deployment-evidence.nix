{
  self,
  nixpkgs,
  lockFile,
}:

let
  fail = message: throw "NIX-348 deployment evidence: ${message}";

  requireGitRevision =
    label: value:
    if builtins.isString value && builtins.match "^([0-9a-f]{40}|[0-9a-f]{64})$" value != null then
      value
    else
      fail "${label} must be a canonical 40- or 64-character Git object id";

  requireSha256 =
    label: value:
    if builtins.isString value && builtins.match "^[0-9a-f]{64}$" value != null then
      value
    else
      fail "${label} must be a canonical SHA-256 hex digest";

  requireTimestamp =
    label: value:
    if builtins.isInt value && value >= 1 && value <= 253402300799 then
      value
    else
      fail "${label} must be a bounded Unix timestamp";

  requireChannel =
    value:
    if
      builtins.isString value
      && builtins.stringLength value >= 1
      && builtins.stringLength value <= 64
      && builtins.match "^[A-Za-z0-9._-]+$" value != null
    then
      value
    else
      fail "the root nixpkgs original.ref must be a bounded channel name";

  lock = builtins.fromJSON (builtins.readFile lockFile);
  nodes = lock.nodes or (fail "flake.lock has no nodes object");
  rootName =
    if builtins.isString (lock.root or null) then
      lock.root
    else
      fail "flake.lock has no string root node name";
  rootNode = nodes.${rootName} or (fail "flake.lock root node ${rootName} is absent");
  nixpkgsTarget = rootNode.inputs.nixpkgs or (fail "flake.lock root node has no nixpkgs input");
  nixpkgsNodeName =
    if builtins.isString nixpkgsTarget then
      nixpkgsTarget
    else if
      builtins.isList nixpkgsTarget
      && nixpkgsTarget != [ ]
      && builtins.isString (builtins.head nixpkgsTarget)
    then
      builtins.head nixpkgsTarget
    else
      fail "flake.lock root nixpkgs target is neither a node name nor a follows path";
  nixpkgsLockNode =
    nodes.${nixpkgsNodeName} or (fail "flake.lock nixpkgs node ${nixpkgsNodeName} is absent");

  lockNixpkgsRevision = requireGitRevision "flake.lock nixpkgs locked.rev" (
    nixpkgsLockNode.locked.rev or null
  );
  inputNixpkgsRevision = requireGitRevision "inputs.nixpkgs.rev" (nixpkgs.rev or null);
  nixpkgsRevision =
    if inputNixpkgsRevision == lockNixpkgsRevision then
      inputNixpkgsRevision
    else
      fail "inputs.nixpkgs.rev does not match the root nixpkgs lock node";

  lockNixpkgsLastModified = requireTimestamp "flake.lock nixpkgs locked.lastModified" (
    nixpkgsLockNode.locked.lastModified or null
  );
  inputNixpkgsLastModified = requireTimestamp "inputs.nixpkgs.lastModified" (
    nixpkgs.lastModified or null
  );
  nixpkgsLastModified =
    if inputNixpkgsLastModified == lockNixpkgsLastModified then
      inputNixpkgsLastModified
    else
      fail "inputs.nixpkgs.lastModified does not match the root nixpkgs lock node";

  evidence = {
    schema = "inspr.pharos.nix-deployment-evidence.v1";
    version = 1;
    source_revision = requireGitRevision "self.rev" (self.rev or null);
    flake_lock_sha256 = requireSha256 "flake.lock hash" (builtins.hashFile "sha256" lockFile);
    nixpkgs_revision = nixpkgsRevision;
    nixpkgs_last_modified = nixpkgsLastModified;
    nixpkgs_channel = requireChannel (nixpkgsLockNode.original.ref or null);
  };
in
# Force every field together. A revisionless/dirty source or malformed lock must
# fail the NixOS evaluation, never leave a partially trustworthy document.
builtins.deepSeq evidence evidence

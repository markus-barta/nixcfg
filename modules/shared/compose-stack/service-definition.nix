# OPS-248: fingerprint one consumer, not unrelated services in its project.
# This selects declarations only; it never resolves env_file or secret values.
{ lib }:
spec: name:
let
  service = spec.services.${name};
  references = entries: map (entry: if builtins.isString entry then entry else entry.source) entries;
  networkNames =
    if service ? network_mode then
      [ ]
    else
      let
        networks = service.networks or [ ];
        names = if builtins.isAttrs networks then builtins.attrNames networks else networks;
      in
      if names == [ ] then [ "default" ] else names;
  volumeNames = lib.filter (source: source != "") (
    map (
      volume:
      if builtins.isString volume then
        let
          parts = lib.splitString ":" volume;
          source = builtins.head parts;
        in
        if
          builtins.length parts < 2
          || lib.hasPrefix "/" source
          || lib.hasPrefix "." source
          || lib.hasPrefix "~" source
        then
          ""
        else
          source
      else if (volume.type or "volume") == "volume" then
        volume.source or ""
      else
        ""
    ) (service.volumes or [ ])
  );
  select =
    section: names:
    lib.genAttrs names (
      key:
      if builtins.hasAttr key (spec.${section} or { }) then
        spec.${section}.${key}
      else if section == "networks" && key == "default" then
        null
      else
        throw "composeStack: ${name} references undeclared ${section}.${key}"
    );
in
{
  name = spec.name or null;
  services.${name} = service;
  networks = select "networks" networkNames;
  volumes = select "volumes" volumeNames;
  configs = select "configs" (references (service.configs or [ ]));
  secrets = select "secrets" (references (service.secrets or [ ]));
}

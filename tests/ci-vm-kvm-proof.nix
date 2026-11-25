# Run INSIDE ci as ci-<id>, against the guest daemon and its existing Bash.
{
  bashStore,
  proofName ? "ci-vm-nixbld-kvm-proof",
}:
let
  bash = builtins.storePath bashStore;
in
builtins.derivation {
  name = proofName;
  system = builtins.currentSystem;
  builder = "${bash}/bin/bash";
  args = [
    "-euc"
    ''
      test "$UID" -ne 0
      test -d /build
      test ! -e /etc/ci-vm-repositories.json
      exec 3<>/dev/kvm
      # Nix maps a nixbld host UID to UID 1000 in its sandbox user namespace.
      host_uid=$UID
      while read -r inside outside count; do
        if (( UID >= inside && UID < inside + count )); then
          host_uid=$((outside + UID - inside))
        fi
      done </proc/self/uid_map
      printf 'uid=%s\nhost_uid=%s\nsandbox_private_etc=yes\nkvm_open=rw\n' "$UID" "$host_uid" >"$out"
    ''
  ];
  requiredSystemFeatures = [ "kvm" ];
  preferLocalBuild = true;
  allowSubstitutes = false;
}

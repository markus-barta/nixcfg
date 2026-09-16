#!/usr/bin/env bash
# T82 — csb1 Aithema declarative speech settings contract (NIX-504).
#
# Pure/static only: verifies shared-flow settings and the pinned package capability;
# it never evaluates a NixOS host, reads protected JSON, builds, switches, or
# contacts a provider.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- run under bash 5\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
shared_flow="$repo_root/hosts/csb1/shared-flow.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"

for file in "$shared_flow" "$host_config"; do
  [ -f "$file" ]
done
command -v jq >/dev/null
command -v nix >/dev/null

nix-instantiate --parse "$shared_flow" >/dev/null
nix-instantiate --parse "$host_config" >/dev/null

speech_json=$(nix eval --impure --json --expr "(import $shared_flow).aithema.speech")
jq -e '
  . == {
    kind: "openai-compatible-transcription",
    providerId: "openrouter",
    model: "openai/whisper-large-v3",
    allowedModels: ["openai/whisper-large-v3"],
    endpoint: "https://openrouter.ai/api/v1/audio/transcriptions",
    acceptedMediaTypes: ["audio/webm", "audio/mp4"],
    limits: {
      maxAudioBytes: 524288,
      maxRequestBytes: 589824,
      maxRecordingMs: 10000,
      maxDurationMs: 30000,
      maxResponseBytes: 65536,
      maxTranscriptChars: 8000
    }
  }
  and (keys | sort) == [
    "acceptedMediaTypes", "allowedModels", "endpoint", "kind", "limits",
    "model", "providerId"
  ]
  and (.limits | keys | sort) == [
    "maxAudioBytes", "maxDurationMs", "maxRecordingMs", "maxRequestBytes",
    "maxResponseBytes", "maxTranscriptChars"
  ]
' <<<"$speech_json" >/dev/null

# The shared-flow selector is the only consumer boundary. Inspect only the
# pinned package metadata, never the NixOS host or protected runtime JSON.
grep -Fq 'speech = sharedFlow.aithema.speech;' "$host_config"
grep -Fq 'speech = {' "$shared_flow"

package_json=$(nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString $repo_root);
    package = flake.inputs.inspr-modules.packages.x86_64-linux.aithema-workspace;
  in {
    inherit (package) version;
    supportsSpeechConfig = package.passthru.supportsSpeechConfig or false;
    sourceRev = package.passthru.release.sourceRev;
    runtimeSha256 = package.passthru.release.runtimeSha256;
  }")
jq -e '
  .version == "0.10.0"
  and .supportsSpeechConfig == true
  and .sourceRev == "d9591b440fdcfa68a2217dd2aefbd92310d151b7"
  and .runtimeSha256 == "2a4deb70f34c525dbd74b23283b67ca69073f9a764d2ed719c8f29d790bca203"
' <<<"$package_json" >/dev/null

printf 'aithema_speech_settings=passed provider=openrouter model=openai/whisper-large-v3 package=0.10.0 speech_capability=true\n'

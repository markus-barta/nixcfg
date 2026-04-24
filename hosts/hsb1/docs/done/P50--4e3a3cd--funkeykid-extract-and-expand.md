# funkeykid-extract-and-expand

**Host**: hsb1
**Priority**: P50
**Status**: Historical planning reference
**Created**: 2026-03-22

> Legacy note: active follow-up tracking now lives in PPM as `FKID-53`.

---

## Problem

child-keyboard-fun outgrew its "press key, hear sound" origin. Needs language-aware letter-sound mapping, Pixoo64 display integration, and TTS to become a real educational tool for children.

## Solution

Extract to own repo (github.com/markus-barta/funkeykid), rename all nixcfg references, add:

- Language packs (de-AT first) with letter → word → sound mapping
- Pixoo display integration via pidicon-light MQTT overlay (192.168.1.189)
- ElevenLabs TTS with caching
- Mode toggles (sound/display/speak independently)

Supersedes: P70--2bef33a--german-letter-sound-mapping

## Implementation

- [x] Create GitHub repo markus-barta/funkeykid
- [x] Scaffold repo: funkeykid.py, config.json, lang/de-AT.json, flake.nix
- [x] Rename all nixcfg references (module, configs, tests, docs, services)
- [ ] Wire funkeykid as flake input in nixcfg
- [ ] Analyze Series 1000.pdf for German letter-sound mapping
- [ ] Build complete de-AT.json with 26+3 letters
- [ ] Deploy sounds to hsb1 /var/lib/funkeykid-sounds/
- [ ] Add wz-pixoo-64-01 (192.168.1.189) to pidicon-light
- [ ] Create funkeykid scene in pidicon-light
- [ ] Set up ElevenLabs API key in agenix
- [ ] Add TTS engine with caching to funkeykid.py
- [ ] Test full flow: key → sound + display + TTS
- [ ] Documentation update

## Acceptance Criteria

- [ ] Each letter A-Z plays a language-appropriate sound (de-AT)
- [ ] Pressed letter appears on Pixoo64 display
- [ ] TTS speaks "X wie Word" when speak mode enabled
- [ ] Modes independently toggleable via config
- [ ] pidicon-light remains SSOT for display
- [ ] Tests pass on hsb1

## Notes

- Sound files NOT in git (copyright, deploy via rsync)
- Pixoo device: 192.168.1.189 (wz-pixoo-64-01), currently showing Divoom stock clock
- TTS: ElevenLabs multilingual v2, cache to avoid repeat API costs
- Language: start DE-AT, expandable to EN etc.

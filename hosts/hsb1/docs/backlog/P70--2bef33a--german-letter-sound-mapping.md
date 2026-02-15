# german-letter-sound-mapping

**Host**: hsb1
**Priority**: P70
**Status**: Backlog
**Created**: 2026-02-15

---

## Problem

Current child-keyboard-fun maps A-Z to generic Warner Bros cartoon sounds (28 files). No educational value — pressing H sounds the same as pressing any other letter. Goal: each letter plays a sound matching a German word starting with that letter, so kids associate letters with meaning.

Example: H → Hammer (hammering sound), K → Katze (cat meow), D → Donner (thunder)

## Sound Libraries Available

Local on imac0 at `/Users/markus/Music/Diverse/sfx/`:

| Collection                                   | Files     | Notes                                            |
| -------------------------------------------- | --------- | ------------------------------------------------ |
| Warner Bros. Sound Effects Library (5 discs) | 490 mp3   | 28 already on hsb1, generic numbered filenames   |
| Sound Ideas 1000 Series (28 CDs)             | 1,947 mp3 | Categorized by type, tracks named `Track NN.mp3` |
| Bonus loose files                            | ~75 wav   | Explosions, lasers, scratches etc.               |

**Key categories for letter mapping** (Sound Ideas):

- `1002 Animals` (81 tracks) — Katze, Hund, Vogel, Elefant...
- `1008 Construction` (77 tracks) — Hammer, Bohrer, Säge...
- `1015 Household Sounds` — Staubsauger, Mixer...
- `1026 Rain, Thunder...` — Donner, Regen, Zug...
- `1028 Water, Whistles, Wind, Zippers` — Wasser, Wind...

**Track index**: `Series 1000.pdf` in the Sound Ideas folder — needed to identify which `Track NN.mp3` is which sound.

## Implementation

- [ ] Read `Series 1000.pdf` to build track-to-sound index
- [ ] Pick 26 German words (A-Z) + map to best matching track
- [ ] Rename/copy selected tracks with descriptive names (e.g. `hammer.mp3`)
- [ ] Upload to hsb1 `/var/lib/child-keyboard-sounds/`
- [ ] Update `child-keyboard-fun.env` with new mappings
- [ ] Keep number keys + unmapped keys as `random` (from full pool)
- [ ] Test all 26 letter keys produce correct sounds
- [ ] Update CHILD-KEYBOARD-FUN.md with letter-word mapping table

## Acceptance Criteria

- [ ] Each letter A-Z plays a sound matching a German word
- [ ] Sounds are distinct and recognizable for a child
- [ ] Mapping documented (letter → German word → sound file)
- [ ] Old random sounds still available for number keys

## Notes

- Sound files are legally owned (original CDs, Austrian private copy law)
- Sound files stay out of git (deploy via scp/rsync to hsb1)
- Consider adding more sounds later (multiple sounds per letter, rotating)

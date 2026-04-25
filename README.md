# Note Defence

Native desktop C++ port of the attached browser prototype.

## What it includes

- Three campaign phases inspired by the JS game:
  - `Invaders`: descending formations
  - `Tempest`: spiralling tunnel lanes
  - `Rez`: lock-on and release chaining
- Score, lives, wave progression, particles, pulses, and start/game-over overlays
- Keyboard controls matching the original note layout:
  - Natural notes: `A B C D E F G`
  - Sharps: `1 2 3 4 5`
- JUCE-powered audio engine for:
  - note hits
  - wrong-key/error tones
  - damage/game-over hits
  - beat-synced kick, snare, hat, and bass backing
  - Rez chain-release synth bursts

## Build

```bash
cmake -S . -B build
cmake --build build
```

If JUCE lives somewhere else on your machine:

```bash
cmake -S . -B build -DJUCE_DIR=/path/to/JUCE
cmake --build build
```

## Run

```bash
open build/NoteDefence.app
```

If your generator places the app inside a configuration folder, open that `.app` bundle instead.

## Notes

- Rendering still uses native macOS drawing through AppKit.
- Sound and music now run through JUCE underneath that window layer.

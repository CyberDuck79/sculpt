# sculpt

A sculpting sampler for [norns](https://monome.org/docs/norns/): a sound source that runs through a chain of texture effects. It is inspired by the Torso S4, and played with the norns alone.

**Work in progress.** Today sculpt is only the first stage: a sample player. The effects are not there yet.

## Where it is going

```
source ─► MOSAIC ─► RING ─► DEFORM ─► VAST ─► output
```

| Stage | What it does | State |
|---|---|---|
| source | sample player, later a looper | sample player done |
| MOSAIC | granular | to do |
| RING | bank of resonant filters | to do |
| DEFORM | drive, crush, compression, noise | to do |
| VAST | delay and reverb | to do |

Modulation will come from the `matrix` and `toolkit` mods, and presets from the norns PSET menu.

## Requirements

- norns (developed on a shield with a Raspberry Pi 4)

## Install

From maiden:

```
;install https://github.com/CyberDuck79/sculpt
```

Then restart the norns (**SYSTEM > RESTART**), so that SuperCollider finds the new engine.

## Controls

| Control | Action |
|---|---|
| E1 | change page within the stage |
| E2 / E3 | the two settings of the page |
| K2 / K3 | the two actions of the stage, named at the top of the screen |
| K1 held + E1 | change stage |

On the **source** stage:

| Control | Action |
|---|---|
| K2 | play from the start / stop |
| K3 | load a sample |
| E2 | level |

A sample is loaded into memory, up to 5 minutes. A mono file plays on both sides. It loops over its whole length.

## The screen

- **Top line:** the stage, what **K2** and **K3** do right now, and the clock (a square that flashes on each beat).
- **Middle:** the waveform of the sample, the playhead and the time.
- **Bottom:** the two settings of the page.

While K1 is held, the top line shows the whole chain, with the current stage bright.

## License

GPL-3.0. See `LICENSE` in the repository.

# sculpt

A sculpting sampler for [norns](https://monome.org/docs/norns/): a sound source that runs through a chain of texture effects. It is inspired by the Torso S4, and played with the norns alone.

**Work in progress.** Today sculpt has a sample player and the first effect, MOSAIC. The other effects are not there yet.

## Where it is going

```
source ─► MOSAIC ─► RING ─► DEFORM ─► VAST ─► output
```

The output goes through a limiter, so a hot sample or a dense effect cannot clip. It leaves anything below full scale untouched and adds 5 ms of latency.

| Stage | What it does | State |
|---|---|---|
| source | sample player, later a looper | sample player done |
| MOSAIC | granular | first 8 settings done |
| RING | bank of resonant filters | first 8 settings done |
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
| K1 held + E2 / E3 | change the mode of that setting, when it has one |

On the **source** stage:

| Control | Action |
|---|---|
| K2 | play from the start / stop |
| K3 | load a sample |
| E2 | level |

A sample is loaded into memory, up to 5 minutes. A mono file plays on both sides. It loops over its whole length.

## MOSAIC

MOSAIC records the last 4 seconds of what it receives, and plays short grains from that buffer. Effects start switched off: **K2** turns the stage on.

| Control | Action |
|---|---|
| K2 | stage on / off |
| K3 | lock the buffer: nothing new is recorded, the grains keep playing what is there |

| Page | E2 | E3 |
|---|---|---|
| 1 | **Pitch** of the grains, in semitones | **Rate**: grains per second |
| 2 | **Size**: length of a grain | **Contour**: shape of a grain, from a sharp attack that fades (-100%), through a bell (0%), to a rise (+100%) |
| 3 | **Scan**: where the grains read | **Spray**: scatters that position at random, up to the whole buffer, and widens the stereo |
| 4 | **Feedback**: sends the grains back into the buffer | **Wet**: dry / effect balance |

**Scan** has two modes, chosen with **K1 held + E2**:

- `delay`: the grains read behind the input, up to 3.5 s back;
- `position`: the grains read at a fixed point of the buffer. This is most useful with the buffer locked.

On the screen, the line is the 4-second buffer and the bright bar is where the input is being written. The grey zone is where grains are born, and the short bars are grains. They are drawn from the settings, not read back from the engine.

## RING

RING is a bank of 48 resonant filters. Each band has its own frequency, level and
ringing time, and every setting shapes those three things. Short ringing times make
the bands overlap into a plain filter; longer ones make each band sing at its own
pitch.

| Control | Action |
|---|---|
| K2 | stage on / off |

| Page | E2 | E3 |
|---|---|---|
| 1 | **Cutoff**: where the response turns | **Resonance**: a peak at the cutoff |
| 2 | **Decay**: how long each band keeps ringing | **Tilt**: leans that ringing towards the low or the high bands |
| 3 | **Slope**: -100% low-pass, 0% band-pass, +100% high-pass | **Tone**: overall lean of the response, lows against highs |
| 4 | **Pitch**: shifts the whole bank, in semitones | **Wet**: dry / effect balance |

On the screen, each bar is a band: its height is the level that band passes, and the
brighter it is, the longer it rings. The tick along the top marks the cutoff.

RING is taken apart when it is switched off, rather than just paused: a resonant
filter holds energy, and a paused one would let it out on the way back. Switched
off, it costs nothing at all.

## The screen

- **Top line:** the stage, what **K2** and **K3** do right now, and the clock (a square that flashes on each beat).
- **Middle:** a view of the stage. For the source: the waveform of the sample, the playhead and the time.
- **Bottom:** the two settings of the page.

While K1 is held, the top line shows the whole chain, with the current stage bright and an effect that is switched off in lower case. A setting that has modes shows its mode.

## License

GPL-3.0. See `LICENSE` in the repository.

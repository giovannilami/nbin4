# nbin4

**nbin4** is a MIDI-input mod for monome norns. It routes four configurable MIDI channels from one input port to four independently selected n.b. voices, alongside the script currently running.

The four parts can use different voices or share one. When parts select the same n.b. voice, they play the same player instance and share its sound parameters, as defined by n.b.

> **Status:** Giovanni confirmed the original four-route MIDI build works on norns on November 17, 2026. Complete cross-script profiles are a new addition and still need hardware testing.

## Features

- Four independent MIDI channel and n.b. voice assignments.
- One selectable MIDI input port, or `<disabled>`.
- Note-on, note-off, velocity, pitch bend, channel pressure and polyphonic key pressure.
- Independent pitch-bend range and pressure destinations for each part.
- Shared-note tracking when multiple parts play the same note through the same n.b. voice.
- An **All notes off** control that releases notes started by nbin4.
- The script's existing MIDI event handler continues receiving messages from the selected port.
- Save, load and delete complete nbin4 profiles that can be recalled from any loaded script.

## Requirements

- monome norns with its mod system.
- The n.b. library, available through `nbout` or as a standalone `nb` library.
- The n.b. voice mods you want to use, installed and enabled on norns.
- A MIDI controller or sequencer connected to a MIDI input port configured in **SYSTEM → DEVICES → MIDI**.

nbin4 does not include n.b. or any sound voices.

## Install

For a local installation, copy the `nbin4` folder into `dust/code/nbin4`. The folder should contain `lib/mod.lua` and this README.

1. Restart norns.
2. Open **SYSTEM → MODS**, select **nbin4**, enable it, and restart norns again.
3. Load any norns script.
4. Open **PARAMETERS → EDIT → NBIN 4**.

Keep the original `nbin` mod disabled while using nbin4, otherwise the same MIDI stream may trigger both mods.

## Quick start

1. In **NBIN 4 → MIDI input**, choose the port connected to your controller. The default is `<disabled>`.
2. Choose an n.b. voice for each part. The default voice selection is `none`, so select the voices before playing.
3. Send notes on MIDI channels 1–4. By default, P1 listens to channel 1, P2 to channel 2, and so on.
4. Adjust the bend range and, for voices that support note modulation, select pressure targets for each part.
5. To reuse the full setup in another script, save it from **NBIN 4 profiles → Save complete profile**, then select it and choose **Load selected profile** in the other script.

## Routing

| Part | Default MIDI channel | Default n.b. voice | Bend range |
| --- | ---: | --- | ---: |
| P1 | 1 | none | 12 semitones |
| P2 | 2 | none | 12 semitones |
| P3 | 3 | none | 12 semitones |
| P4 | 4 | none | 12 semitones |

Each part can listen to any channel from 1–16. The channels are independent assignments; assigning the same channel to multiple parts sends each incoming note to every selected voice on that channel. A part with voice `none` is silent.

Only one MIDI input port can be selected at a time. Changing the port releases notes started through nbin4, restores the previous event handler on the old port, and installs the nbin4 handler on the new port. The mod chains the current script's MIDI event handler on the selected port, so both can receive its messages.

## Parameters

All nbin4 controls are in **PARAMETERS → EDIT → NBIN 4**.

| Parameter | Range or options | Description |
| --- | --- | --- |
| MIDI input | `<disabled>` or an available norns MIDI port | Selects the single port nbin4 listens to. |
| P1–P4 MIDI channel | 1–16 | Selects the input channel routed to that part. Defaults are 1, 2, 3 and 4. Repeated channel assignments fan out to all matching parts. |
| P1–P4 n.b. voice | `none` or an installed n.b. player | Selects the player for that part. |
| P1–P4 bend range | 2–24 semitones; default 12 | Sets the pitch-bend range for notes routed through the part. |
| P1–P4 pressure | `none` or a voice-declared note-mod target | Maps channel pressure and polyphonic key pressure to a target. |
| P1–P4 more pressure | `none` or a voice-declared note-mod target | Maps the upper portion of pressure to a second target. |
| P1–P4 pressure sensitivity | Bipolar | Scales the second pressure mapping. |
| All notes off | Trigger | Sends note-off for notes currently held by nbin4. |

The pressure target lists are built from each selected player's `note_mod_targets` description and update when its voice selector changes. A voice without note-mod targets will offer only `none`.

The selected voices' n.b. parameter groups are added to the parameter menu. If several parts select the same voice, its parameters control that shared instance. n.b. prevents duplicate parameter groups when another n.b.-aware script has already added them.

## MIDI behavior

For each incoming note-on, nbin4 finds the matching part or parts and sends note and normalized velocity to their selected players. A matching note-off is sent to the same players that received its note-on, even if the part's channel or voice assignment has since changed.

When the same n.b. player and pitch are held by more than one routed input, nbin4 keeps a reference count and sends the final note-off only after all matching held notes have been released. This avoids one routed channel cutting off a same-pitch note still held by another channel on that shared voice. The voice's own polyphony and repeated-note behavior still apply.

Pitch bend is applied to the notes currently held on its incoming channel, using each matching part's bend range. Channel pressure affects held notes on that channel; polyphonic key pressure affects the matching pitch. Voices must implement the corresponding n.b. methods for these messages to have an effect.

nbin4 currently handles note-on/off, velocity, pitch bend, channel pressure and key pressure. It does not route sustain pedal, other CCs, program changes or MIDI clock to n.b.; the script's own MIDI event handler may still process those messages.

## Compatibility and saved parameters

nbin4 adds its controls after the loaded script's `init()` function, following the lifecycle used by nbin. This allows it to run alongside scripts without requiring changes to their source. The mod includes compatibility handling for norns builds that do not expose a native post-init hook.

### Complete profiles across scripts

The **NBIN 4 profiles** controls save a separate, reusable profile in `dust/data/nbin4/profiles/`. Profiles are shared across scripts on the same norns. Use **Save complete profile** to name or replace a profile, **Load selected profile** to apply it, and **Delete selected profile** to remove it.

A profile includes the selected MIDI input, all four MIDI channel assignments, all four n.b. voice selections, bend ranges, pressure targets and sensitivities, plus the saveable internal parameters of each selected n.b. voice. A voice used by multiple parts is saved once because those parts share the same player and parameter set. Parameters belonging to the currently loaded script are not included.

Voice selectors are saved by voice name, and option parameters by their displayed choice, so profiles do not depend on option-list positions. The MIDI input is matched by its device name, with its original port as a preference. If that device is unavailable, nbin4 loads the rest of the profile and leaves MIDI input disabled. If a voice or one of its parameters is missing, nbin4 skips it and reports that in the matron log.

Profiles are local to the norns device and are not part of a script's ordinary PSET slots. Back up `dust/data/nbin4/profiles/` separately if you want to transfer them to another device.

### Ordinary script PSETs

The usual norns PSET slots remain script-specific. Because nbin4 adds its controls after script initialization, a script that reads a PSET inside `init()` may do so before nbin4's parameters exist. If its nbin4 settings do not restore from that script's PSET, use a complete nbin4 profile instead.

The mod releases its held notes when its MIDI input changes, when the script is replaced, and when norns shuts down. **All notes off** releases only notes tracked by nbin4; it does not call a global n.b. stop that could silence notes from another source.

## Test checklist

- Confirm that the selected MIDI port receives notes and that `<disabled>` stops nbin4 input.
- Route channels 1–4 to four voices, then change one channel and one voice while the script continues running.
- Assign the same channel to two parts and confirm that both selected voices receive its notes.
- Assign two parts to the same voice and test same-pitch note overlap, note-off, and **All notes off**.
- Test pitch bend, channel pressure and key pressure with voices that support them.
- Confirm that the loaded script still receives MIDI events from the selected port.
- Save a complete profile, load a different norns script, and recall it. Confirm that MIDI input, channel routing, all four voice choices, and each selected voice's sound parameters return.
- Save a profile where two parts share one voice and confirm its internal parameters remain shared after loading.
- Change the MIDI device order or disconnect the saved input, then load the profile and confirm nbin4 selects the matching device by name or disables the input.
- Try a profile with a voice mod disabled and confirm the remaining available settings load safely.

## Development and credits

Developed by Giovanni Lami with AI assistance (ChatGPT / OpenAI Codex). Feature decisions and hardware evaluation are by Giovanni Lami.

The n.b. note-player library is by [sixolet](https://github.com/sixolet/nb). [nbin](https://github.com/sixolet/nbin) is the related single-route MIDI-input mod and the reference for polyphonic pitch-bend and pressure support. nbin4 adds four channel-to-voice routes while keeping n.b.'s shared-player behavior.

No license is included in this repository. Public availability on GitHub does not grant permission to redistribute or modify the code; add a license before reusing it.

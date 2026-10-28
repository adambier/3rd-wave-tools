# Behringer WAVE data formats

This document describes the data the Behringer WAVE (the 2024 recreation of the PPG Wave 2.2/2.3)
sends and receives over MIDI System Exclusive: programs, sequences, global settings, and wavetable
uploads. The WAVE has no file format of its own; a `.syx` file is a sequence of these messages.
The document is written for someone implementing a reader, a writer, or a converter. It exists
here because the WAVE's wavetables have the same shape as the 3rd Wave's P tables (64 frames of
128 samples, with the PPG's four standard waveforms at positions 60–63), which makes the two
instruments natural conversion partners. Nothing in 3rd-wave-tools implements any of this yet.

**Sources.**

- The *WAVE User Manual* V1.0 (Music Tribe, April 2025, for firmware 1.0.11): its SysEx chapter
  (pp. 36–41) defines every message and table below, and its menu descriptions (pp. 22–28) say
  what the values mean. Page numbers in this document refer to the manual.
- Two factory program dumps (`Factory All 200 Presets`), one from a WAVE on firmware 1.0.7 and one
  from firmware 1.0.11 after a factory reset. "Verified" means checked against the 400 program
  records in these dumps.
- Two open-source implementations that agree with the manual where they overlap: the Behringer
  WAVE adaptation in [KnobKraft-orm](https://github.com/christofmuc/KnobKraft-orm)
  (`adaptations/Behringer_Wave.py`, written from the manual and from captured SynthTribe traffic)
  and [wavesweeper](https://github.com/ulmert/wavesweeper), a browser-based wavetable uploader.

Inferences are marked as inferences. Music Tribe's copyright notice ("No part of this document may
be reproduced") applies to the manual; the tables here are restated in this document's own form
and words.

This project is not affiliated with Behringer, Music Tribe, or Groove Synthesis; their product
names say which instruments the data belongs to.

## Contents

1. [Message framing](#1-message-framing)
2. [Message catalog](#2-message-catalog)
3. [Program payload](#3-program-payload)
4. [What the factory dumps show](#4-what-the-factory-dumps-show)
5. [Sequencer payload](#5-sequencer-payload)
6. [Global payload](#6-global-payload)
7. [Wavetable and transient uploads](#7-wavetable-and-transient-uploads)
8. [MIDI CCs and NRPNs](#8-midi-ccs-and-nrpns)
9. [Manual errata](#9-manual-errata)
10. [Open questions](#10-open-questions)
11. [Notes for a 3rd Wave converter](#11-notes-for-a-3rd-wave-converter)

## 1. Message framing

```
F0  00 20 32  00 01 39  00  <PKT>  [<SPKT>]  [payload]  F7
```

| Field | Value | Note |
|---|---|---|
| Manufacturer ID | `00 20 32` | Behringer GmbH |
| Model ID | `00 01 39` | WAVE |
| Device ID | `00` | always 0 for the WAVE (p. 36) |
| PKT | packet type | `0x74` for program, sequencer, wavetable, and calibration messages; `0x75` and `0x76` for global settings |
| SPKT | sub-packet type | absent for PKT `0x75` and `0x76` |
| Version | `0x00` | "Data Package Version Byte (currently 0x0)"; present only in dump messages (p. 36) |

Byte indexes in this document count from the `F0` as index 0: 1–3 manufacturer, 4–6 model,
7 device ID, 8 PKT, 9 SPKT. Every payload byte is 7-bit (0–127).

**Checksum.** `(D0 + … + Dn) & 0x7F`, the low 7 bits of the plain sum of the payload bytes
D0–Dn (pp. 40–41). The bank, preset, wave number, position, and version bytes are outside the sum.
Verified: all 400 program messages in the factory dumps carry this sum over bytes 13–133 alone.

**Acknowledgments.** Every program, sequencer, and wavetable dump sent *to* the WAVE is answered
with a status message: 1 = success, 0 = "Data Length/Checksum were wrong" (pp. 40–41). wavesweeper
waits for the acknowledgment (3 s timeout) before the next wavetable message, then pauses 150 ms;
the manual states no required pacing.

**Prerequisite.** The manual's troubleshooting page says that SynthTribe cannot communicate with
the WAVE unless "the SYSEX parameter in the Program menu is set to 1" (p. 42). The global dump
carries a SYSEX byte (byte 2, "SysEx RX/TX", 0 or 1; p. 39), while the Program menu's SYSEX item
is described on p. 23 as the dump selector of section 2.1, with values 0–6; which setting p. 42
means is not clear from the manual.

## 2. Message catalog

Lengths count the whole message from `F0` to `F7`. "hdr" is the 10-byte prefix
`F0 00 20 32 00 01 39 00 74 <SPKT>`.

### 2.1 Programs (PKT `0x74`, p. 40)

| SPKT | Direction | After hdr | Length | Meaning |
|---|---|---|---|---|
| `05` | to WAVE | `bank preset F7` | 13 | program dump request |
| `06` | both | `bank preset ver D0…D120 chk F7` | 136 | program dump; sent to the WAVE, the program is stored at that bank and preset |
| `07` | to WAVE | `F7` | 11 | edit-buffer dump request |
| `08` | both | `ver D0…D120 chk F7` | 134 | edit-buffer dump; sent to the WAVE, the program loads into the edit buffer |
| `0A` | from WAVE | `bank preset status F7` | 14 | acknowledgment of a `06` store |
| `0C` | from WAVE | `status F7` | 12 | acknowledgment of an `08` load |

- Bank is 0 or 1; preset is 0–99 (`00`–`63`). KnobKraft's test vector for bank 1, program 99 is
  `F0 00 20 32 00 01 39 00 74 05 01 63 F7`.
- In a `06` message D0 is at index 13 and the checksum at index 134; in an `08` message D0 is at
  index 11 and the checksum at index 132. Verified for `06`.
- To convert between the two, replace `hdr(06) bank preset` with `hdr(08)` or the reverse; version,
  payload, and checksum are unchanged (KnobKraft does exactly this).

The WAVE's own SYSEX menu item (Program menu, p. 23) dumps, by its value: 1 the edit buffer,
2 the current program, 3 the current bank, 4 the sequencer edit buffer, 5 the current program's
sequence, 6 the current bank's sequences. A bank dump is 100 consecutive `06` messages (verified:
the factory dumps are 200 `06` messages, bank 0 presets 0–99 followed by bank 1 presets 0–99, with
no file header and nothing between messages).

### 2.2 Sequencer (PKT `0x74`, pp. 40–41)

| SPKT | Direction | After hdr | Length | Meaning |
|---|---|---|---|---|
| `0D` | to WAVE | `bank preset F7` | 13 | sequencer data request |
| `0E` | both | `bank preset ver D0…D577 chk F7` | 593 | sequencer dump; stored when sent |
| `0F` | to WAVE | `F7` | 11 | sequencer edit-buffer request |
| `10` | both | `ver D0…D577 chk F7` | 591 | sequencer edit-buffer dump |
| `12` | from WAVE | `bank preset status F7` | 14 | acknowledgment of `0E` |
| `14` | from WAVE | `status F7` | 12 | acknowledgment of `10` |

### 2.3 Wavetables and transients (PKT `0x74`, p. 41)

| SPKT | Direction | After hdr | Length | Meaning |
|---|---|---|---|---|
| `5D` | to WAVE | `waveNum position ver D0…D308 chk F7` | 324 | one frame (128 samples) of a wavetable or transient |
| `5E` | from WAVE | `waveNum position status F7` | 14 | acknowledgment of `5D` |
| `5F` | to WAVE | `F7` | 11 | slot name list request |
| `60` | from WAVE | `ver D0…D1535 chk F7` | 1549 | slot names for slots 32–127 |

**No message reads a wavetable or transient back from the WAVE.** Only the names can be read
(`5F`/`60`). A converter cannot use a WAVE as a wavetable source over SysEx.

- `waveNum` (index 10): 0 = store in the edit "listen" buffer as a wavetable; 1 = store in the edit
  listen buffer as a transient (sample); 32–127 = store in that user slot (32–63 are transients,
  64–127 wavetables).
- `position` (index 11): frame 0–63 within the table. "After the Wavetable data for Position 63
  has been received it will be stored", and a listen-buffer destination becomes the active table
  (p. 41). A table is 64 messages, positions 0 through 63; nothing is committed before position 63.
  wavesweeper sends all 64 in order and repeats the 16-character name in each.
- `5E` carries the status at index 12 (wavesweeper reads `data[12]`).

Payload format: section 7.

### 2.4 Global settings (PKT `0x75` and `0x76`, p. 41)

| PKT | Direction | After `F0 00 20 32 00 01 39 00 <PKT>` | Length | Meaning |
|---|---|---|---|---|
| `75` | to WAVE | `F7` | 10 | global settings request |
| `76` | both | `ver D0…D19 chk F7` | 32 | global dump; sets the globals when sent to the WAVE |

The heading on p. 41 says "PKT = 0x75 / 0x76 / 0x77" but documents only `75` and `76`. No
acknowledgment of `76` is documented.

### 2.5 Calibration (PKT `0x74`, SPKT `04`, p. 40)

`hdr type F7`, 12 bytes; type 0 = VCA/VCF, 1 = CV in, 2 = mod wheel, 3 = pitch wheel. Listed so
the opcode is not mistaken for anything else.

### 2.6 Undocumented: identity (KnobKraft, from captured SynthTribe traffic)

Request `F0 00 20 32 00 01 39 00 02 F7` (PKT `02`, no SPKT); the reply is
`F0 00 20 32 00 01 39 00 03 00 F7` according to KnobKraft's comment, and the adaptation reads
index 7 (the device ID) from it. What the `00` after `03` means is not stated.

## 3. Program payload

D0–D120, 121 bytes (the manual's "SysEx Preset Data" table, pp. 36–38):

| Bytes | Content |
|---|---|
| 0–15 | program name, 16 ASCII characters 32–126 (`0x20`–`0x7E`) |
| 16–18 | program-level settings shared by both groups |
| 19–69 | group A sound (51 bytes: 13 tuning, 22 analog, 16 digital) |
| 70–120 | group B sound, the same 51-byte layout at +51 |

The WAVE does not store the name. Every program in both factory dumps carries
`"1111111111111111"`, and firmware 1.0.11 has been observed to return that string for a program
sent with a real name (KnobKraft's notes; Gearspace reports through October 2026). A reader must
not rely on the name; a writer can send 16 spaces. KnobKraft identifies factory programs by an MD5
of bytes 16–120 and carries the factory names, which the manual lists on pp. 30–32.

### 3.1 Program level

| Byte | Menu | Parameter | Range | Meaning |
|---|---|---|---|---|
| 16 | PROGRAM | WAVETB | 0–127 | wavetable or transient slot: 0–29 factory wavetables, 30 the Upper Wavetable, 31 the factory transient, 32–63 user transients, 64–127 user wavetables (pp. 22, 36) |
| 17 | PROGRAM | SPLIT | 0–99 | split point for keyboard modes 4–8; the lowest octave in −2 octave mode is 0–12, −1 is 13–24, 0 is 25–36 (p. 23) |
| 18 | PROGRAM | KEYB | 0–9 | keyboard mode (section 3.5) |

### 3.2 Tuning: group A bytes 19–31, group B 70–82

| A | B | Parameter | Range | Meaning |
|---|---|---|---|---|
| 19 | 70 | DETU | 0–9 | sub-oscillator detune: 0 none; 1–4 increasing; 5 = +5 semitones; 6 = +1 octave; 7 = +2 octaves; 8 = −1 octave; 9 = −2 octaves |
| 20 | 71 | MO | 0–1 | LFO to main-oscillator pitch |
| 21 | 72 | MS | 0–1 | LFO to sub-oscillator pitch |
| 22 | 73 | EO | 0–9 | envelope 3 to main-oscillator pitch: 0 off, 1 on, 2–9 portamento with increasing glide time |
| 23 | 74 | ES | 0–1 | envelope 3 to sub-oscillator pitch |
| 24–31 | 75–82 | SEMIT V1–V8 | 0–63 | upward detune in semitones for voices 1–8 |

### 3.3 Analog: group A bytes 32–53, group B 83–104

All 0–127; the factory dumps hold only even values (section 4).

| A | B | Parameter | Meaning |
|---|---|---|---|
| 32 | 83 | DELAY | LFO delay; 127 is 10 s (p. 18) |
| 33 | 84 | WAVESHAPE | LFO shape: triangle, ramp, sawtooth, square, as four zones of the value (section 4) |
| 34 | 85 | RATE | LFO rate, 0.2–12 Hz |
| 35 | 86 | A1 | envelope 1 (filter) attack; above 47 on the panel scale (above 94 here) the attack completes even if the key is released (p. 18) |
| 36 | 87 | D1 | envelope 1 decay |
| 37 | 88 | S1 | envelope 1 sustain |
| 38 | 89 | R1 | envelope 1 release |
| 39 | 90 | VCF-CUTOFF | filter cutoff (a 24 dB/octave low-pass modeled on the SSM2044) |
| 40 | 91 | VCF-EMPHASIS | filter resonance |
| 41 | 92 | WAVES-OSC | main-oscillator frame position (transient: sample start point) |
| 42 | 93 | WAVES-SUB | sub-oscillator frame position (transient: sample start point) |
| 43 | 94 | ATTACK 3 | envelope 3 attack |
| 44 | 95 | DECAY 3 | envelope 3 decay |
| 45 | 96 | ENV 3 ATT | envelope 3 amount: for pitch the midpoint is no modulation, below negative, above positive; for frame position 0 is none and the maximum is 63 frames (p. 20) |
| 46 | 97 | A2 | envelope 2 (loudness) attack, with the same above-47 rule as A1 |
| 47 | 98 | D2 | envelope 2 decay |
| 48 | 99 | S2 | envelope 2 sustain |
| 49 | 100 | R2 | envelope 2 release |
| 50 | 101 | MOD WHL | mod wheel position, stored per group |
| 51 | 102 | ENV 1 → VCF | envelope 1 to filter amount |
| 52 | 103 | ENV 2 → LOUDNESS | the group's program volume |
| 53 | 104 | ENV 1 → WAVES | envelope 1 to frame position amount (transient: loop point) |

### 3.4 Digital: group A bytes 54–69, group B 105–120

| A | B | Parameter | Range | Meaning |
|---|---|---|---|---|
| 54 | 105 | UW | 0–2 | wavetable: 0 = the selected table with positions 60–63 and wrapping enabled; 1 = the Upper Wavetable; 2 = the selected table with 60–63 and wrapping disabled. Transient: loop length 0 = 128, 1 = 2,048, 2 = 8,192 samples (firmware 1.0.11, p. 24) |
| 55 | 106 | SW | 0–6 | sub-oscillator mode: 0 follows the main oscillator plus the WAVES-SUB offset; 1 set by WAVES-SUB alone; 2 envelope 3 replaces envelope 1 for the frame sweep; 3 off; 4 muted and hard-syncing the main oscillator (WAVES-SUB sets the main-oscillator frequency); 5 ring modulation with the main oscillator; 6 noise generator (WAVES-SUB sets the level) |
| 56 | 107 | KW | 0–7 | key to frame position: 0 off; 1–3 higher notes shift higher; 4 one frame per key, descending from WAVES-OSC; 5–7 the same with frames skipped |
| 57 | 108 | KF | 0–7 | key to filter tracking: 0 none; 3 about 100 %; 7 about 200 % |
| 58 | 109 | KL | 0–7 | key to loudness: 0–3 higher keys louder; 4 flat; 5–7 lower keys louder |
| 59 | 110 | MW | 0–9 | mod wheel and LFO to frame position: 0 off; 1 the wheel sets the LFO sweep depth; 2 the wheel sweeps directly; 3–9 constant LFO sweep, 10–100 % |
| 60 | 111 | MF | 0–9 | mod wheel and LFO to filter: 0 off; 1 the wheel sets the LFO depth; 2 the wheel sets the cutoff; 3 the wheel sets the emphasis; 4–9 constant LFO, 10–100 % |
| 61 | 112 | ML | 0–1 | LFO to loudness (with FIRM 1 or 2 the wheel sets the depth) |
| 62 | 113 | BD | 0–7 | bend destination: 0 off; 1 both oscillators; 2 cutoff; 3 frame position; 4 sub-oscillator only; 5 pitch and cutoff; 6 pitch and frame position; 7 cutoff and frame position |
| 63 | 114 | BI | 0–5 | bend range: 0 = 2 semitones; 1 = 4; 2 = 7; 3 = 12; 4 = 24; 5 = 12 in semitone steps |
| 64 | 115 | TW | 0–2 | aftertouch to frame position: 0 off; 1 sweep; 2 LFO depth |
| 65 | 116 | TF | 0–2 | aftertouch to filter: 0 off; 1 cutoff; 2 LFO depth |
| 66 | 117 | TL | 0–2 | aftertouch to loudness: 0 off; 1 loudness; 2 LFO depth |
| 67 | 118 | TM | 0–1 | aftertouch to mod wheel |
| 68 | 119 | VF | 0–3 | velocity to filter: 0 off; 1 low; 2 medium; 3 high |
| 69 | 120 | VL | 0–3 | velocity to loudness: 0 off; 1 low; 2 medium; 3 high |

The aftertouch destinations act only when the global TOUCH setting enables aftertouch (p. 23).

### 3.5 KEYB modes (byte 18, p. 23)

| Value | Mode |
|---|---|
| 0 | poly, 8 notes, one group (A or B, chosen with the Group button) |
| 1 | quad, 4 notes, 2 + 2 oscillators per note, A on the odd voices and B on the even |
| 2 | duo, 2 notes, 4 + 4 oscillators per note |
| 3 | mono (unison), 8 + 8 oscillators |
| 4 | split: A quad (upper), B quad (lower) |
| 5 | split: A mono (4 + 4), B quad |
| 6 | split: A mono (2 + 2), B 6-note poly |
| 7 | split: A 6-note poly, B mono (2 + 2) |
| 8 | split: A mono (4 + 4), B mono (4 + 4) |
| 9 | A 7-note poly, B mono from the CV and gate inputs |

## 4. What the factory dumps show

Two files of 27,200 bytes, each 200 messages of 136 bytes: `Factory All 200 Presets` from firmware
1.0.7, and the same from firmware 1.0.11 after a factory reset (DTF 8). Every message is a `06`
dump with version 0 and a valid checksum, in bank and preset order.

**The analog scale.** All 22 analog bytes of all 400 group records are even, in both files, with a
maximum of 126. The stored value is twice the panel value (the Analog menu shows 00–63, p. 27), so
reading SysEx value ÷ 2 gives the panel value (an inference from the even values and the panel
range). Whether an edit over MIDI CC (0–127) can store an odd value is not known.

**LFO shape.** In the 1.0.7 file WAVESHAPE holds assorted even values (0 to 120); in the 1.0.11
file it holds only 0, 32, and 64. In the programs that changed in nothing else, the 34 changed
WAVESHAPE bytes map 2–24 to 0, 48–60 to 32, and 66–84 to 64.

So the byte holds a knob position, and the shape is the zone the value falls in (value ÷ 32):
0 triangle, 1 ramp, 2 sawtooth, 3 square (the order of the panel legend; an inference). The 1.0.11
factory set stores each zone's first value; no 1.0.11 program uses the fourth zone (one 1.0.7
program held 120 and was rewritten).

**UW on transient programs.** Every UW change between the files outside the rewritten programs
(17 bytes) is in a program whose WAVETB is a transient slot (31–63): values 1 and 2 became 0.
Firmware 1.0.11 gave UW a second meaning for transients (the loop length, p. 24), and the factory
set was reset to 0 (128 samples) for those programs; three of the rewritten transient programs
(bank 0 presets 70, 72, and 73) keep UW 2. This is observed, not stated by the manual.

**What 1.0.11 changed.** The manual lists "Updated presets in bank 0 (70,71,72,73,74)" (p. 14):
those five now play the new factory transients 44–48 (WAVETB 47, 44, 46, 48, 45). Bank 0 presets
79, 80, 81, and 83 were also rewritten (45–66 bytes each, with new wavetables 2, 8, 9, and 18),
which the manual's list does not mention. The rest of the differences are the LFO-shape and UW
normalizations above and one D2 change (bank 0 preset 27, 52 to 50). Bank 1 differs only in the UW
bytes of presets 90 and 91.

**Ranges.** Every value lies within the range the manual gives for its parameter. SW reaches 6 in
both groups (so the "0–3" printed for byte 106 is a typo); EO reaches 3 in group B and 1 in
group A; KEYB takes 0, 1, 3, 4, 7,
and 9 (156 programs are mode 0); SPLIT is 42, 48, or 49 in the 14 programs where it is not 0;
WAVETB values lie in 0–48 (31–48 are transient slots, used by 25 programs) and 64–86;
ENV 2 → LOUDNESS runs 44–126; MOD WHL reaches 126.

**Both groups matter.** Group B differs from group A in 199 of the 200 programs, and in 155 of the
156 mode-0 programs, where only one group plays at a time. SEMIT (per-voice detune) is non-zero
somewhere in 188 programs; the values that occur are mostly 12, 24, and 36 (octaves), 5, and 19,
so the manual's example of group B two octaves up (p. 26) is a common pattern (an inference from
the value lists; the patterns were not counted).

## 5. Sequencer payload

D0–D577, 578 bytes (p. 40):

| Byte | Content | Range |
|---|---|---|
| 0 | GAT, gate time | 0–99 (the menu and the NRPN table say 1–99) |
| 1 | DIV, clock division | 0–6: 1/4, 1/8, 1/16, 1/32, 1/4 triplet, 1/8 triplet, 1/16 triplet |
| 2–513 | step s, voice v: index 2 + 8·(s−1) + (v−1); s = 1–64, v = 1–8 | 0–127 |
| 514–577 | attribute byte for step s: index 514 + (s−1) | 0–127 |

A sequence holds up to 64 steps of up to 8 notes (p. 28). The step-and-voice bytes are presumably
MIDI note numbers; how a rest, a tie, an unused voice, and the step count are encoded is not
documented and is probably in the attribute bytes (an inference). One dump of a known short
sequence would settle the encoding.

## 6. Global payload

D0–D19, 20 bytes (p. 39):

| Byte | Parameter | Range | Meaning |
|---|---|---|---|
| 0 | MIDI | 0–16 | MIDI channel, 0 = off |
| 1 | TUNE (printed "TTUNE") | 0–99 | master tune 400–499 Hz: value + 400 |
| 2 | SYSEX | 0/1 | SysEx receive and transmit |
| 3 | LOCAL | 0/1 | local control |
| 4 | EXP_PED | 0–5 | 0 off, 1 loudness, 2 cutoff, 3 emphasis, 4 frame position, 5 mod wheel |
| 5 | TOUCH | 0–3 | 0 off, 1 MIDI transmit, 2 MIDI receive, 3 both |
| 6 | BRT | 0–99 | LCD brightness |
| 7 | CNT | 0–99 | LCD contrast |
| 8 | PAR-COM | 0–3 | parameter CCs: 0 off, 1 transmit, 2 receive, 3 both |
| 9 | FIRM | 0/1/2 | 0 original, 1 enhanced, 2 enhanced with exponential envelopes (1.0.11) |
| 10 | OSC | 0/1 | oscillator enhancements (less aliasing, smoother sweeps) |
| 11 | LFO | 0/1 | LFO precision enhancement |
| 12 | MOD | 0–2, 11–15, 21–25 | Mode_A + 10·Mode_B; A: 0 sequencer, 1 arpeggiator 1, 2 arpeggiator 2 (octave added); B: 1 up, 2 down, 3 up and down, 4 random, 5 moving (0 when A = 0) |
| 13 | CLK | 00–03, 12, 22, 30–33 | mode + 10·rate; mode 0 internal, 1 DIN, 2 USB, 3 analog trigger; rate 0 = 1 ppqn, 1 = 2, 2 = 24, 3 = 48 (MIDI clocks fixed at 24) |
| 14 | GAT | 1–99 | gate time |
| 15 | DIV | 0–6 | as in section 5 |
| 16 | BPM (MSB) | 40–240 | "Tempo (Bits 8-13)" |
| 17 | BPM (LSB) | 40–240 | "Tempo (Bits 0-7)" |
| 18 | MTN | 0/1 | metronome |
| 19 | OVP | 00/01/10/11 | overdub + 10·key-transpose; overdub 0 disabled, 1 enabled; key transpose 0 enabled, 1 disabled |

The printed BPM split ("bits 8–13" and "bits 0–7") cannot be literal: an 8-bit low byte does not
fit a SysEx byte, and 240 needs bit 7. A 7-and-7 split (MSB = bits 7–13, LSB = bits 0–6; 240 →
`01 70`) is the plausible reading (an inference, not verified).

## 7. Wavetable and transient uploads

Each `5D` message carries one frame: a 272-byte block, packed to 309 bytes (p. 41).

### 7.1 The block

| Bytes | Content |
|---|---|
| 0–15 | wavetable or transient name, 16 ASCII characters 32–126 |
| 16–271 | 128 samples, signed 16-bit integers, **big-endian** ("Hi-Byte, Lo-Byte") |

The name is sent as it is (the characters are already 7-bit); the 256 sample bytes are packed as
below. wavesweeper space-pads and upper-cases the name (wavesweeper's own choice).

### 7.2 Packing

Each group of 7 sample bytes becomes 8 transmitted bytes: a leading byte holding the seven high
bits (byte *i*'s bit 7 in bit *i* of the leading byte, so byte 0's high bit is bit 0), then the
seven low 7-bit remainders in order. 256 = 36 × 7 + 4, so 36 full groups (288 bytes) and one final
group of 4 bytes (5 bytes, high bits in bits 0–3). Total 16 + 288 + 5 = 309 bytes, n = 308.
wavesweeper's encoder is the same.

Reference encoder and decoder (Python 3), tested for a round trip and the 324-byte message length:

```python
def pack7(raw: bytes) -> bytes:
    out = bytearray()
    for i in range(0, len(raw), 7):
        group = raw[i:i + 7]
        hi = 0
        for j, b in enumerate(group):
            if b & 0x80:
                hi |= 1 << j
        out.append(hi)
        out.extend(b & 0x7F for b in group)
    return bytes(out)

def unpack7(packed: bytes, raw_len: int) -> bytes:
    out = bytearray()
    i = 0
    while len(out) < raw_len:
        n = min(7, raw_len - len(out))
        hi = packed[i]
        for j in range(n):
            out.append(packed[i + 1 + j] | (0x80 if hi & (1 << j) else 0))
        i += 1 + n
    return bytes(out)

def wave_message(wave_num: int, position: int, name: str, samples: list[int]) -> bytes:
    """samples: 128 ints in -32768..32767."""
    assert len(samples) == 128 and 0 <= position <= 63
    name16 = name.encode("ascii", "replace")[:16].ljust(16, b" ")
    raw = b"".join(s.to_bytes(2, "big", signed=True) for s in samples)
    payload = name16 + pack7(raw)                      # 309 bytes
    chk = sum(payload) & 0x7F
    return (bytes([0xF0, 0x00, 0x20, 0x32, 0x00, 0x01, 0x39, 0x00, 0x74, 0x5D,
                   wave_num, position, 0x00]) + payload + bytes([chk, 0xF7]))
```

The checksum covers all 309 payload bytes, the name included (wavesweeper sums the name
characters, the high-bit bytes, and the remainders, as the manual's D0…Dn definition says).

### 7.3 Geometry and slots

- A wavetable is 64 frames of 128 samples; "the last four waveforms emulate the typical analog
  waveforms: Sawtooth, pulse, square and triangle" (p. 14). UW 0 or 2 enables or disables positions
  60–63 and wrapping per program (section 3.4), the counterpart of the 3rd Wave's **Use Upper
  Wavetable** setting for P tables.
- SynthTribe down-samples an imported table to 128 samples per frame and 64 frames; more than 64
  frames are cut, fewer leave the rest empty. SynthTribe accepts standard uncompressed mono WAV and
  offers Flip (reverse the frame order), Maximize (normalize), and 8- or 16-bit "resolution"
  (p. 29). How 8-bit resolution is sent is not documented; the message has only the 16-bit field.
- A transient uses "the full wavetable memory" with no down-sampling and loops over 128, 2,048, or
  8,192 samples (pp. 14, 29). The full memory is 64 × 128 = 8,192 samples, so a transient is
  presumably 64 messages of 128 consecutive samples with waveNum 1 or 32–63 (an inference).
- Slot map (byte 16 of a program; waveNum of `5D`; the `60` name list): 0–29 factory wavetables, 30
  the Upper Wavetable, 31 the factory transient, 32–63 user transients (32–48 ship with factory
  content on firmware 1.0.11), 64–127 user wavetables (64–86 ship with factory content)
  (pp. 15–16, 22). SynthTribe's Restore Factory WT/TR puts the factory content back (p. 29).
- The `60` name list (1,536 bytes) holds 16 characters for each of slots 32–127 in order: bytes
  0–15 slot 32, …, 496–511 slot 63, 512–527 slot 64, …, 1520–1535 slot 127 (p. 41). What an empty
  slot holds is not stated.
- The factory wavetables 0–30 are named on p. 15 (0 "Harmonic Bliss" through 29 "PulseShift
  Modulation" and 30 "Upper Wavetable"); the factory user tables 64–86 and transients 32–48 are on
  p. 16. The 31 entries on p. 15 correspond one for one, in order, to the PPG Wave 2.2/2.3's
  wavetables 0–30 as the PPG manual describes them; whether the frames are the PPG's data has
  not been established, since the WAVE cannot dump a table.

## 8. MIDI CCs and NRPNs

Useful for live editing and for what the parameters mean; the SysEx tables above are the storage
form (pp. 34–36).

**CCs** (sent when PAR-COM is 1 or 3, received when 2 or 3):

| CC | Function |
|---|---|
| 0, 32 | bank select MSB and LSB (0–1) |
| 1 | mod wheel |
| 6 | NRPN data |
| 7 | master volume |
| 8 | balance (BASIS) |
| 11 | expression pedal |
| 12, 13, 14 | DELAY, WAVESHAPE, RATE |
| 15, 16, 17 | ATTACK 3, DECAY 3, ENV 3 ATT |
| 18–21 | A1, D1, S1, R1 |
| 22–25 | A2, D2, S2, R2 |
| 26, 27 | WAVES-OSC, WAVES-SUB |
| 28, 29, 30 | ENV 1 → VCF, ENV 2 → LOUDNESS, ENV 1 → WAVES |
| 31 | group select (0 = A, 1 = B, 2 = A and B) |
| 64 | sustain |
| 71, 74 | VCF-EMPHASIS, VCF-CUTOFF |
| 98, 99 | NRPN LSB and MSB |
| 120–123 | standard |

The analog CCs are 0–127; which group an analog CC edits depends on the current group select.

**NRPNs** (`Bn 63 00`, `Bn 62 n`, `Bn 06 value`; MSB always 0; data through CC 6 alone):

| NRPN | Parameter (range) |
|---|---|
| 0, 1, 2 | WAVETB (0–127), SPLIT (0–99), KEYB (0–9) |
| 3 | DTF (0–7) |
| 4–11 | TUNE (0–99), EXP-PEDAL, TOUCH, BRT, CNT, FIRM (0–2), OSC, LFO |
| 12, 13 | UW (0–2), SW (0–6) |
| 14, 15, 16 | KW, KF, KL (0–7 each) |
| 17, 18 | MW, MF (0–9) |
| 19 | ML (0–1) |
| 20, 21 | BD (0–7), BI (0–5) |
| 22, 23, 24 | TW, TF, TL (0–2) |
| 25 | TM (0–1) |
| 26, 27 | VF, VL (0–3) |
| 28 | DETU (0–9) |
| 29, 30 | MO, MS (0–1) |
| 31, 32 | EO (0–9), ES (0–1) |
| 33–40 | SEMIT V1–V8 (0–63) |
| 41 | STATE (0–3: stop, play, record, overdub) |
| 42–46 | MOD (0–25), CLK (0–34), GAT (1–99), DIV (0–6), BPM (40–240, "MSB/LSB") |

The footnote says ParNum = 0–37; the table runs to 46.

Bank select: `Bn 00 00`, `Bn 20 bank` (0 or 1), then program change 0–99 (p. 36).

## 9. Manual errata

- Bytes 31 and 82 are labeled "SEMIT V7" with the note "Voice 8 - Semi Offset"; they are SEMIT V8
  (the NRPN table has 40 = SEMIT V8).
- Byte 106 (group B SW) is printed with range 0–3; byte 55, the Digital-menu text (seven
  settings), NRPN 13, and the factory dumps all give 0–6.
- Byte 22 (group A EO) is printed with range 0–1; byte 73 (group B EO), NRPN 31, and the Tuning
  menu give 0–9, and the factory dumps hold 3 in group B.
- Page 16 introduces the factory user tables as "slots 64 – 83"; the list below it runs to 86.
- Global byte 1 is printed "TTUNE"; the parameter is TUNE everywhere else.
- The `60` description labels bytes 1520–1535 "TR-127"; slot 127 is a wavetable slot.
- "ParNum = 0–37" under the NRPN table, which runs to 46.
- GAT is 0–99 in the sequencer SysEx table and 1–99 in the global table, the NRPN table, and the
  Sequencer menu.
- The BPM bit assignment (section 6).
- The Program menu text (p. 22) calls positions 0–30 "the preset wavetables" and 31 "a preset
  transient wave"; p. 15 lists 0–29 plus 30 "Upper Wavetable". Consistent if 30 is counted as a
  preset table.
- The firmware 1.0.11 notes (p. 14) list bank 0 presets 70–74 as updated; 79, 80, 81, and 83
  changed as well (section 4).

## 10. Open questions

- Whether an edit over MIDI CC stores an odd analog value, or the firmware rounds to the panel's
  64 steps.
- The sequencer's note encoding: rests, ties, unused voices, the step count, and the attribute
  bytes.
- How a transient is split across `5D` messages, and what SynthTribe sends for 8-bit resolution.
- Whether `76` is acknowledged.
- Whether the WAVE accepts a `06` or `08` dump whose version byte is not 0 (a writer sends 0; a
  reader accepts 0 and warns on anything else).
- The meaning of the `00` in the undocumented identity reply.
- Whether the factory wavetables are the PPG's data (section 7.3).

## 11. Notes for a 3rd Wave converter

- A WAVE user wavetable has the 3rd Wave P table's geometry (64 frames of 128 samples, the PPG's
  standard waveforms at 60–63), so a P table and a WAVE table differ only in sample format: float
  within ±1 against int16, scaled by 32,767 and rounded, with no resampling. WAVE names take 16
  ASCII characters (the 3rd Wave's 31), so a name is cut and characters outside 32–126 reported.
- A 3rd Wave U table (64 frames of 1,024 samples) needs each frame reduced to 128 samples
  (`Resampling.resizeCycle`); 2,048-sample Serum-style tables and 256-sample WaveEdit tables reduce
  the same way, and tables of more than 64 frames need the frame reduction the Wavetables page
  already does.
- The only route into the WAVE a tool can write directly is `5D` SysEx, 64 messages per table with
  one acknowledgment each. The alternative is a mono WAV of 64 × 128 samples for the user to send
  with SynthTribe, which resamples to 128 itself. Given the SysEx corruption seen on the 3rd Wave
  (FORMATS.md section 9), the WAV route, or counting all 64 acknowledgments, is the safer one.
- "From the WAVE" means from the user's source files or from a `.syx` holding `5D` messages (e.g.,
  a captured SynthTribe transfer), since the WAVE cannot dump a table. A `.syx` reader therefore
  reassembles `5D` sequences: group by waveNum, order by position, require all 64 positions, unpack,
  and take the name from position 0.
- A WAVE program is one wavetable slot, a split point, a keyboard mode, and two 51-byte sounds
  (A and B), and both sounds are populated in nearly every factory program (section 4). The program
  references the table by slot number alone, so a program conversion needs the table from
  elsewhere: slots 0–30 are the factory tables that the manual describes as the PPG's (section 7.3)
  and that the 3rd Wave carries as P00–P30; 64–86 are the named factory user tables; anything else
  is the user's data.
- Toward a 3rd Wave program, group A (and B as a second part) map at this level:
  - wavetable slot to P slot;
  - WAVES-OSC and WAVES-SUB (0–127) to frame position (÷ 2);
  - VCF-CUTOFF and VCF-EMPHASIS to the filter;
  - envelope 1 to the filter envelope, with ENV 1 → VCF as its amount;
  - envelope 2 to the amp envelope, with ENV 2 → LOUDNESS as level;
  - envelope 3 (attack, decay, amount) to a pitch or frame-position modulation, as EO, ES, and SW
    say;
  - LFO delay, shape, and rate, with MO, MS, MW, MF, and ML as routings;
  - KF and KL as key tracking; VF and VL as velocity; TW, TF, TL, and TM as aftertouch;
  - DETU as sub-oscillator detune.
- SEMIT (per-voice detune, used by 188 of the 200 factory programs) has no 3rd Wave equivalent;
  a group B an octave or two up can become a part with a transposed oscillator, and the rest is
  reported as lost.
- The 3rd Wave's parameter set is far larger, and most of a program's values have no identified
  meaning yet (FORMATS.md section 3.4), so this mapping is a design of its own, for which the
  descriptions in section 3 are enough.
- Names in program dumps carry nothing (section 3); the factory names come from the manual's
  pp. 30–32 or from KnobKraft's fingerprint table.

**Validation for any writer:** every payload byte 0–127; name bytes 32–126; the checksum recomputed
on write and checked on read; message lengths exactly as section 2; version 0; bank 0–1; preset
0–99; waveNum in {0, 1, 32–127}; position 0–63. Refuse and say why rather than guess.

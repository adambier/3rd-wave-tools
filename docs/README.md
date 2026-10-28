# Documentation

Reference documents for the file and data formats this repository works with. Each states its
sources, marks inferences as inferences, and names the firmware, manual, or software version it
was written against. Corrections and test results are welcome (see
[CONTRIBUTING.md](../CONTRIBUTING.md)).

| Document | Covers | Written against | Status |
|---|---|---|---|
| [FORMATS.md](FORMATS.md) | Files in the Groove Synthesis 3rd Wave's formats: `.pro`, `.pgdata`, `.wt`, `.bin`; conversion of older programs; what the 3rd Wave does on import | 3rd Wave 8M and 24M, OS 2.0d; files from firmware 2022–2025 | Implemented by `PgdataFormats`; the authority for every claim about the 3rd Wave |
| [WAVETABLES.md](WAVETABLES.md) | Wavetable files of other synths and plug-ins (Serum-style WAV, Surge XT, WaveEdit, Tonverk, and more): frame sizes, metadata, interpolation flags, import rules | The manuals and source code named in the document | Implemented by `WavetableFormats`; destinations marked tested or untested |
| [BEHRINGER-WAVE.md](BEHRINGER-WAVE.md) | The Behringer WAVE's SysEx data: programs, sequences, global settings, wavetable uploads; what two factory dumps show; errata in the manual | *WAVE User Manual* V1.0 (firmware 1.0.11); factory dumps from firmware 1.0.7 and 1.0.11 | Reference only; not implemented here |

**License.** These documents are part of the repository and are covered by its MIT license
([LICENSE](../LICENSE)). Quote or reuse them with attribution.

**Trademarks.** 3rd Wave and Groove Synthesis, WAVE and Behringer, PPG, and the other product
and company names in these documents belong to their owners. This project is not affiliated with
or endorsed by any of them; the names say which instruments and files the documents describe.

**Images.** The `.png` files in this folder are the README's screenshots.

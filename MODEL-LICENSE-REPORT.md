# Sekitiri local AI model licence report

**Audit date:** 2026-08-14  
**Scope:** Current and planned local AI components for the macOS Sekitiri app.  
**Conclusion type:** Source review, not legal advice or a legal clearance.

## Executive conclusion

The current source tree directly depends on FluidAudio and currently calls its
Parakeet TDT v2 path. `Package.resolved` pins FluidAudio `0.15.5` at commit
`19600a485baa4998812e4654b70d2bab8f2c9949`; `ParakeetEngine.swift` calls
`AsrModels.downloadAndLoad(version: .v2)`. The app source does not currently
contain WhisperKit, Nemotron, Sortformer, or Pyannote code.

Several components have published terms that expressly allow commercial use,
but the converted CoreML repositories are separate distributions from their
upstream weights. They must be audited and pinned independently. In particular,
the Parakeet v3 CoreML and Sortformer CoreML pages contain licensing signals
that do not line up cleanly with the upstream model or FluidAudio documentation.
Those items should not be treated as cleared for redistribution until the
artifacts and notices are reconciled and legal review is complete.

## Current source inventory

| Component | Evidence in Sekitiri | Role | Current status |
| --- | --- | --- | --- |
| FluidAudio Swift SDK | `Package.swift`, `Package.resolved` | Native Apple/Swift audio AI runtime | Currently used |
| Parakeet TDT v2 CoreML | `ParakeetEngine.swift` and FluidAudio `.v2` loader | Current transcription model | Downloaded by FluidAudio; not bundled in this repo |
| Parakeet TDT v3 CoreML | Planned via FluidAudio | Multilingual final transcription | Planned |
| Nemotron 3.5 multilingual streaming CoreML | Planned via FluidAudio | True live transcription | Planned |
| Sortformer CoreML | Planned via FluidAudio | Streaming diarization | Planned |
| Pyannote/WeSpeaker CoreML | FluidAudio catalogue; planned fallback/offline diarization | Offline or enrolled-speaker diarization | Planned; not in Sekitiri source |
| WhisperKit + Whisper CoreML | Planned alternative final transcription backend | Higher-accuracy/multilingual final pass | Not in Sekitiri source |

### Added in the quantized local-summary experiment

| Component | Evidence in Sekitiri | Role | Status |
| --- | --- | --- | --- |
| MLX Swift LM | `Package.swift` and `Sources/Core/MeetingNotesService.swift` | In-process quantized LLM runtime | Added; pinned in `Package.resolved` |
| Qwen3 4B 4-bit MLX | `mlx-community/Qwen3-4B-4bit` configuration | Optional local meeting summarizer | Downloaded on first selection; not bundled |
| Gemma 3n E2B 4-bit MLX | `mlx-community/gemma-3n-E2B-it-lm-4bit` configuration | Optional lightweight local meeting summarizer | Downloaded on first selection; not bundled |

The MLX community repositories are model conversions rather than the upstream
model releases. Preserve the exact model revision and review its attached
terms before redistributing downloaded weights. Sekitiri loads only one
quantized summary model per request and does not send transcript content to a
remote inference endpoint.

Sources: [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm),
[Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B),
[Gemma model documentation](https://ai.google.dev/gemma).

## Component-by-component findings

### 1. FluidAudio SDK — Apache-2.0

The FluidAudio repository identifies its SDK licence as Apache License 2.0 and
the pinned checkout contains an Apache `LICENSE` file. Apache 2.0 permits use,
modification, distribution, and commercial distribution subject to its notice,
licence, modification-marking, patent, and warranty provisions. The SDK licence
does **not** automatically determine the licence of model weights downloaded at
runtime.

FluidAudio’s own catalogue says its model assets are converted/optimised from
upstream models and lists separate diarization and ASR model repositories. Treat
each downloaded model repository as a separate licensed work.

**Distribution action:** Include FluidAudio’s Apache licence and required
copyright/NOTICE material in Sekitiri’s third-party notices. Preserve the
version/commit used for each release.

Sources: [FluidAudio repository](https://github.com/FluidInference/FluidAudio),
[FluidAudio licence](https://github.com/FluidInference/FluidAudio/blob/main/LICENSE),
[FluidAudio model catalogue](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md),
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).

### 2. FluidAudio’s pinned dependencies — mixed permissive licences

The pinned FluidAudio checkout contains separate notices for at least:

- `vbx-LICENSE.md` — Apache-2.0.
- `fastcluster-LICENSE.md` — BSD-style terms requiring copyright, conditions,
  and disclaimer notices in source/binary redistribution.

These notices must travel with any binary/app distribution that includes the
corresponding code. The checkout and model downloads should be re-scanned at
every release; the SDK README and a source checkout are not a substitute for a
release-time dependency manifest.

### 3. Parakeet TDT v2 — upstream CC BY 4.0; Fluid CoreML page says CC BY 4.0

NVIDIA’s `nvidia/parakeet-tdt-0.6b-v2` model card says the model is governed by
CC BY 4.0 and describes it as ready for commercial/non-commercial use. The
FluidInference CoreML conversion also identifies itself as CC BY 4.0.

CC BY 4.0 allows commercial sharing and adaptation, but requires appropriate
credit, a licence link, an indication of changes, retention of supplied notices,
and no implication of endorsement. It also does not grant trademark, privacy,
publicity, or other rights that may exist outside copyright.

**Assessment:** Published terms support commercial use with attribution, but
ship the upstream and converted-asset notices together and pin the exact CoreML
revision. This is a model-asset conclusion, not a warranty that training-data
or downstream rights are cleared for every use case.

Sources: [NVIDIA Parakeet v2 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2),
[FluidInference Parakeet v2 CoreML card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml),
[CC BY 4.0 legal code](https://creativecommons.org/licenses/by/4.0/legalcode.en).

### 4. Parakeet TDT v3 — upstream CC BY 4.0; converted page is inconsistent

NVIDIA’s `nvidia/parakeet-tdt-0.6b-v3` card identifies CC BY 4.0 as the governing
terms and says the model is ready for commercial/non-commercial use. The
FluidInference v3 CoreML repository currently has `license: cc-by-4.0` metadata,
but its model-card body says “Apache 2.0”. The upstream model tree points back to
NVIDIA’s CC BY model.

**Assessment:** Do not label or redistribute the v3 CoreML asset as Apache-2.0
without written clarification from the asset publisher or a legal determination.
The conservative release position is to preserve CC BY attribution and the
upstream model terms, while recording the CoreML page inconsistency as a blocker.

Sources: [NVIDIA Parakeet v3 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
[FluidInference Parakeet v3 CoreML card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml),
[CC BY 4.0 legal code](https://creativecommons.org/licenses/by/4.0/legalcode.en).

### 5. Nemotron 3.5 multilingual streaming — OpenMDW-1.1

NVIDIA’s `nvidia/nemotron-3.5-asr-streaming-0.6b` card identifies OpenMDW-1.1
and says the model is ready for commercial use. OpenMDW-1.1 grants permission
to deal in the Model Materials without restriction, subject to retaining a copy
of the agreement and applicable origin/copyright notices. The licence has a
patent/copyright-litigation termination clause, an as-is warranty disclaimer,
and assigns the user responsibility for clearing other rights and obtaining
necessary consents.

The FluidInference multilingual CoreML card states that it is a derivative of
that base model and distributed under the same OpenMDW-1.1 terms, with
commercial use and redistribution permitted. The repository history records a
prior provenance/licence correction, so Sekitiri must pin the corrected commit
and verify the exact downloaded files rather than relying only on a floating
`main` branch.

**Assessment:** The published terms support commercial bundling when the exact
base and converted files match the stated provenance and required notices are
retained. Because the conversion repository has had contradictory metadata in
its history, obtain legal/maintainer confirmation before shipping the model
weights in a paid product.

Sources: [NVIDIA Nemotron card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b),
[FluidInference Nemotron CoreML card](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML),
[OpenMDW-1.1 licence](https://openmdw.ai/license/1-1/),
[provenance/licence correction commit](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/commit/1a41b75758b0337ff67db7d5408280aaaf23074e).

### 6. Sortformer diarization — NVIDIA Open Model License upstream; CoreML metadata conflict

NVIDIA’s `diar_streaming_sortformer_4spk-v2.1` card states that use is governed
by the NVIDIA Open Model License Agreement. The agreement grants a royalty-free
licence to use, make, sell, offer for sale, distribute, and import the model,
but conditions redistribution on giving recipients the agreement and including
the required NVIDIA notice. It also includes AI-ethics/trustworthy-AI,
trademark, export/trade, warranty, liability, and termination provisions.

FluidAudio’s documentation describes Sortformer as NVIDIA Open Model licensed.
However, the FluidInference CoreML repository frontmatter currently says
CC BY 4.0 while identifying NVIDIA’s Sortformer as its original model.

**Assessment:** This is a legal-review blocker. The CoreML conversion may have
additional attribution terms, but a CC BY label cannot by itself be assumed to
replace the upstream NVIDIA terms. Do not ship the Sortformer CoreML weights
until the publisher confirms the governing licence stack in writing. If using
the NVIDIA upstream terms, include the exact NVIDIA agreement and required
notice in the app’s third-party licences.

Sources: [NVIDIA Sortformer card](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1),
[NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/),
[FluidAudio Sortformer documentation](https://github.com/FluidInference/FluidAudio/blob/main/README.md),
[FluidInference Sortformer CoreML card](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml).

### 7. Pyannote and WeSpeaker — code and weights are separate

The `pyannote/pyannote-audio` toolkit is MIT-licensed. That licence applies to
the software repository, not automatically to every pretrained pipeline or
checkpoint.

Relevant model terms currently visible from the model cards:

- `pyannote/speaker-diarization-3.1`: MIT metadata and a gated Hugging Face
  access agreement requiring acceptance of user conditions and token access.
- `pyannote/speaker-diarization-community-1`: CC BY 4.0 and gated access
  conditions requiring acceptance and contact information.
- `pyannote/segmentation-3.0`: MIT metadata and gated access conditions.
- `pyannote/wespeaker-voxceleb-resnet34-LM`: CC BY 4.0 metadata; its card says
  the underlying WeSpeaker pretrained model follows the corresponding dataset
  licence. WeSpeaker’s toolkit repository is Apache-2.0, but that does not
  establish the licence of its pretrained weights. The card points to VoxCeleb
  CC BY terms for the cited model.

FluidAudio’s `speaker-diarization-coreml` page is a converted bundle based on
`community-1` and labels the bundle CC BY 4.0. The bundle contains segmentation,
embedding, PLDA, and clustering artefacts, so each included source and notice
must be retained when redistributing it.

**Assessment:** The software licences are permissive, but model gates,
dataset-derived weight terms, attribution, and the converted bundle’s exact
contents require an asset manifest. Do not infer “MIT” for the entire pipeline
from `pyannote.audio`’s GitHub licence.

Sources: [pyannote.audio](https://github.com/pyannote/pyannote-audio),
[pyannote 3.1 card](https://huggingface.co/pyannote/speaker-diarization-3.1),
[pyannote community-1 card](https://huggingface.co/pyannote/speaker-diarization-community-1),
[pyannote segmentation card](https://huggingface.co/pyannote/segmentation-3.0),
[pyannote WeSpeaker card](https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM),
[WeSpeaker repository](https://github.com/wenet-e2e/wespeaker),
[FluidInference diarization CoreML card](https://huggingface.co/FluidInference/speaker-diarization-coreml).

### 8. WhisperKit and Whisper — permissive SDK/model core, verify converted assets

Argmax’s open-source Swift SDK is MIT-licensed and says it includes third-party
notices. OpenAI’s Whisper repository states that its code and model weights are
MIT-licensed; the `openai/whisper-large-v3-turbo` model card also identifies MIT.
MIT permits commercial use, modification, distribution, sublicensing, and sale
subject to retaining the copyright and licence notice.

WhisperKit’s CoreML model repository is a distribution of converted model
artifacts and its visible card does not provide the same single explicit licence
statement as the OpenAI upstream card. For a paid Sekitiri build, pin the exact
Argmax model revision, retain Argmax notices, retain OpenAI Whisper notices, and
verify any model-specific files before bundling them. Do not assume every
third-party Whisper derivative or quantisation has MIT terms merely because
OpenAI Whisper does.

**Assessment:** The upstream Whisper and Argmax SDK terms are permissive for
commercial software, but the exact WhisperKit CoreML artifact still needs a
release-time licence/notice check.

Sources: [Argmax open-source SDK](https://github.com/argmaxinc/argmax-oss-swift),
[OpenAI Whisper repository](https://github.com/openai/whisper),
[OpenAI Whisper licence](https://github.com/openai/whisper/blob/main/LICENSE),
[OpenAI Whisper large-v3-turbo card](https://huggingface.co/openai/whisper-large-v3-turbo),
[Argmax WhisperKit CoreML repository](https://huggingface.co/argmaxinc/whisperkit-coreml).

## Required release controls

Before shipping or selling a Sekitiri build that downloads or bundles local
models:

1. Pin every SDK, model repository, commit/revision, and file checksum. Do not
   use floating `main` model content in a release.
2. Generate a `MODEL-LICENSES.md`/third-party-notices inventory containing the
   exact artifact, upstream base, licence URL and text, attribution, notices,
   source revision, and whether the model is bundled or downloaded.
3. Include Apache, MIT, CC BY, OpenMDW, NVIDIA Open Model, and dependency
   notices in the app’s acknowledgements or a shipped notices directory as
   required by each licence. For CC BY assets, include credit, licence link,
   change indication, and disclaimer notice. For NVIDIA Open Model assets,
   include the agreement and the exact required NVIDIA notice.
4. Resolve the Parakeet v3 CoreML and Sortformer CoreML licence discrepancies
   in writing before distribution. Resolve the Nemotron provenance against a
   pinned commit as well.
5. Keep model licences distinct from privacy/consent duties. Recording other
   people, speaker embeddings, calendar attendee names, and model outputs may
   require separate notices, permissions, retention controls, and jurisdiction-
   specific review.
6. Re-run the inventory whenever FluidAudio, a model revision, a conversion,
   or a transitive dependency changes.

## Items requiring legal review

- Parakeet TDT v3 CoreML: CC BY metadata versus Apache-2.0 model-card text.
- Sortformer CoreML: CC BY metadata versus NVIDIA Open Model terms referenced
  by the upstream model and FluidAudio docs.
- Nemotron multilingual CoreML: current card states OpenMDW-1.1, but its history
  records an earlier provenance/licence contradiction; pin and verify.
- Pyannote/WeSpeaker converted bundles: model/data terms, gated conditions, and
  dataset-derived weights must be reviewed as a bundle.
- WhisperKit converted/quantised artifacts: verify the exact model revision and
  shipped notices rather than relying only on OpenAI Whisper’s MIT licence.
- Any third-party training-data, dataset, voice, privacy, publicity, export,
  or biometric/speaker-identification rights not granted by the software/model
  licence.

## Sources and method

This report used the Sekitiri source tree and pinned FluidAudio checkout, then
checked the upstream project/model cards and licence texts linked above. The
attached Apache 2.0 text was treated as the standard Apache licence reference;
it does not override an artifact’s own model-specific terms. No source code was
modified for this audit.

## Implementation follow-up (2026-08-14)

The app now includes optional runtime support for both requested model paths:

- Parakeet TDT v3 is selectable as the default multilingual final-pass engine;
  Parakeet v2 remains available as an English-focused fallback.
- Sortformer is selectable for completed recordings and labels the mixed
  system-audio track with anonymous stable speaker slots. It does not infer
  names from voices.
- On Macs with 8 GB or less of physical memory, the lighter palettized
  Sortformer weights are selected to keep ASR and diarization from competing
  for memory.
- The exact runtime model revision still needs to be pinned and the two
  conversion-repository licence discrepancies still need written clarification
  before bundling those model files into a paid release. See
  `THIRD_PARTY_NOTICES.md` for the release inventory.

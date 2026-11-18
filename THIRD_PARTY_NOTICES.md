# Sekitiri third-party notices

## quill

Sekitiri started from quill by Humanitas Labs, released under the MIT
License. Parts of the audio capture and transcription code still derive from
it, and its copyright notice is kept in `LICENSE`:
https://github.com/humanitas-labs/quill

## Fonts

IBM Plex Sans (Copyright IBM Corp.) and Newsreader (Copyright The Newsreader
Project Authors) are bundled under the SIL Open Font License 1.1. The full
license texts ship next to the font files in `Sources/Assets/Fonts/`.

## Models and SDKs

Sekitiri can download and run local speech and summarisation models through the
FluidAudio and MLX Swift SDKs. Model assets are separate from the SDKs and may
carry separate terms.

## FluidAudio

FluidAudio is distributed under the Apache License 2.0. The full license is
available in the FluidAudio package and at:
https://github.com/FluidInference/FluidAudio/blob/main/LICENSE

Sekitiri currently resolves FluidAudio from the revision recorded in
`Package.resolved`.

## Parakeet speech recognition (TDT 0.6B v2/v3, Ultra, CTC 110M)

The NVIDIA Parakeet model cards identify the model weights as CC BY 4.0.
Sekitiri uses FluidInference's CoreML conversions: TDT 0.6B v2 or v3 or
Parakeet Ultra for transcription, and the CTC 110M model for custom
vocabulary. The applicable attribution is:

Copyright NVIDIA Corporation. Models: NVIDIA Parakeet TDT 0.6B, Parakeet TDT-CTC 110M.
Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
Source: https://huggingface.co/nvidia/parakeet-tdt_ctc-110m
License: https://creativecommons.org/licenses/by/4.0/

Parakeet Ultra is a post-trained Parakeet v3 by moondream, also CC BY 4.0:
https://huggingface.co/moondream/parakeet-ultra
CoreML conversion: https://huggingface.co/FluidInference/parakeet-ultra-coreml

The CoreML conversions are independently distributed artifacts. Keep the
upstream attribution, license link, and an indication of conversion or other
changes when redistributing model files.

## Silero voice activity detection

Transcription windows are planned with Silero VAD, MIT License, via
FluidInference's CoreML conversion:
https://github.com/snakers4/silero-vad
https://huggingface.co/FluidInference/silero-vad-coreml

## Sortformer speaker diarization

Sekitiri can download FluidInference's CoreML conversion of NVIDIA Sortformer
for anonymous speaker-turn labels. The upstream NVIDIA model terms and the
CoreML repository metadata must both be reviewed for the exact revision used.
The NVIDIA redistribution notice is retained here for release review:

Licensed by NVIDIA Corporation under the NVIDIA Open Model Agreement.

Source model: https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
CoreML conversion: https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml

Before distributing Sortformer model files in a paid build, reconcile any
license mismatch between the upstream model and the conversion repository and
pin the confirmed revision.

## MLX Swift local summarisation runtime

Sekitiri uses MLX Swift LM with the Hugging Face Swift downloader/tokenizer
packages to run optional quantized summary models in-process. These are local
inference dependencies; downloading weights on first use does not send meeting
content for inference.

- MLX Swift LM: MIT — https://github.com/ml-explore/mlx-swift-lm
- swift-huggingface: Apache-2.0 — https://github.com/huggingface/swift-huggingface
- swift-transformers: Apache-2.0 — https://github.com/huggingface/swift-transformers

## Qwen3.5 2B and 0.8B 4-bit

Sekitiri may download the pre-quantized MLX conversions
`mlx-community/Qwen3.5-2B-4bit` or `mlx-community/Qwen3.5-0.8B-4bit` when
the user selects a Qwen summary model. Qwen3.5 is released under Apache-2.0;
retain the model-card attribution and license link for the exact revision:

https://huggingface.co/Qwen/Qwen3.5-2B-Base

## Libraries built into the app

The released app contains compiled code from these packages, at the versions
pinned in `Package.resolved`. Their full license and NOTICE texts, including
the code they vendor (MLX, mlx-c, metal-cpp, fmt and nlohmann/json inside
mlx-swift), ship inside the app as `Contents/Resources/Acknowledgements.txt`.

| Package | License |
|---|---|
| [EventSource](https://github.com/mattt/EventSource) | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | MIT |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | Apache-2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache-2.0 |
| [swift-numerics](https://github.com/apple/swift-numerics) | Apache-2.0 |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | Apache-2.0 |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 |
| [yyjson](https://github.com/ibireme/yyjson) | MIT |

## Important

This notice file is an engineering inventory, not legal advice. Model files
downloaded at runtime remain subject to the terms attached to the exact model
revision. Do not infer a person's identity from an anonymous speaker slot.

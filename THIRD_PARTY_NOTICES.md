# Sekitiri third-party notices

Sekitiri can download and run local speech and summarisation models through the
FluidAudio and MLX Swift SDKs. Model assets are separate from the SDKs and may
carry separate terms.

## FluidAudio

FluidAudio is distributed under the Apache License 2.0. The full license is
available in the FluidAudio package and at:
https://github.com/FluidInference/FluidAudio/blob/main/LICENSE

Sekitiri currently resolves FluidAudio from the revision recorded in
`Package.resolved`.

## Parakeet TDT 0.6B v2/v3

The NVIDIA Parakeet model cards identify the model weights as CC BY 4.0.
Sekitiri uses the FluidInference CoreML conversions when the user selects
Parakeet v2 or v3. The applicable model attribution is:

Copyright NVIDIA Corporation. Model: NVIDIA Parakeet TDT 0.6B.
Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
License: https://creativecommons.org/licenses/by/4.0/

The CoreML conversion is an independently distributed artifact. Keep the
upstream attribution, license link, and an indication of conversion or other
changes when redistributing model files.

## Nemotron 3.5 multilingual streaming

Sekitiri uses FluidAudio's Nemotron streaming adapter for live partial
transcription. The model is distributed under OpenMDW-1.1. Retain the full
OpenMDW-1.1 license and NVIDIA origin notices when redistributing model
materials:

https://openmdw.ai/license/1-1/
https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML

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

## Qwen3 4B 4-bit

Sekitiri may download the pre-quantized MLX conversion
`mlx-community/Qwen3-4B-4bit` when the user selects Qwen3. The upstream Qwen3
model is released under Apache-2.0; retain the model-card attribution and
license link for the exact revision used:

https://huggingface.co/Qwen/Qwen3-4B

## Gemma 3n E2B 4-bit

Sekitiri may download the pre-quantized MLX conversion
`mlx-community/gemma-3n-E2B-it-lm-4bit` when the user selects Gemma. Gemma
models are subject to Google’s Gemma Terms of Use and Responsible AI Toolkit
terms; retain the model-card attribution and exact-revision terms:

https://ai.google.dev/gemma/docs/core/model_card_3n
https://ai.google.dev/gemma/terms

## Important

This notice file is an engineering inventory, not legal advice. Model files
downloaded at runtime remain subject to the terms attached to the exact model
revision. Do not infer a person's identity from an anonymous speaker slot.

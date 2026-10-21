# Sekitiri — Build Guide

Sekitiri is a native macOS meeting recorder and note-taking app. Recording,
transcription, and summaries run in-process. Audio recognition uses local
Parakeet models through FluidAudio; Parakeet v3 is the multilingual default.
The same checkpointed transcription work runs during recording and after Stop.

The notes selector offers **Source notes · lightweight** (the default for a
fresh installation), Apple's on-device Foundation Model and Qwen3.5 2B 4-bit
through MLX. Existing explicit engine choices are preserved. Source notes use
bounded English/French source rules and exact transcript quotations; no summary
language model, tokenizer or model download is needed. This is extractive
note-taking: implicit commitments and unfamiliar phrasing may need review.
Qwen is downloaded explicitly in Settings; Summarise never downloads weights.
The evaluated Qwen3.5 0.8B candidate failed factual checks and is not in the UI.
Mistral/API summaries are not implemented. Meeting inference remains local.

This file is for **any agent (or human) who needs to build or modify this app.**

---

## Repo layout

| Path | What it is |
|---|---|
| `~/Projects/quillnotes-app` | **App source root** (this repo). SwiftUI mac app; recording + transcription engine runs **in-process** (no separate quill daemon/icon). |
| `Tools/build_app.sh` | Portable release build/packaging script. Derives the checkout root, stages/signs/verifies the app, defaults to `.local-validation/Sekitiri.app`. |
| `Sources/Audio/` | Microphone and system capture, segmented recording, playback. |
| `Sources/Transcription/` | Bounded audio reads, Parakeet inference, durable checkpoints, transcript integrity, serial coordination. |
| `Sources/Core/MeetingNotesService.swift` | Native summary generation, vault indexing, transcript copying, and deletion. No CLI is required to write notes. |
| `Sources/Core/SourceSelectionSummary.swift` | Sentence labeling, bounded model classification into six source-ID arrays, literal source records, conservative owner/deadline extraction. |
| `Sources/Core/StructuredSummaryPipeline.swift` | Source/quote validation, correction reconciliation and deterministic section assembly. |
| `Sources/Core/SummaryDocument.swift` / `SummaryPersistence.swift` | Versioned canonical `summary.json`, Markdown compatibility export, explicit source references, serialized action updates and completion reconciliation. |
| `Sources/Core/LocalSummaryRuntime.swift` | Exclusive MLX generation lease, model loading/release, explicit downloads and cache controls. |
| `Tests/SekitiriAppTests/` | Capture, windowing, checkpoint, integrity, and summary regression tests. |
| `Tools/evaluate_transcription.py` | Offline comparison of exported transcripts with reference text. |
| `~/Meetings` | Default Markdown notes vault and `.index.json`; native app services write it. Configurable in `~/.config/meeting-notes/config.json`. |
| `~/Recordings` | Default capture root: per-session audio, metadata, checkpoints, canonical transcript, and completion record. Configurable in `~/.config/quill/config.json`. |
| `BuildSupport/default.metallib` | MLX shader library required by the packaging helper for local Qwen inference. |

---

## Build the full app (recommended)

From this checkout:

```bash
Tools/build_app.sh
```

This builds the release executable with SwiftPM, derives the product path for
this Mac, assembles `.local-validation/Sekitiri.app`, preserves the source
privacy descriptions and assets, includes SwiftPM dependency resource bundles
and MLX shaders, and ad-hoc signs/verifies the result. Defaults are app version
**1.2.0** and build **2026.10.21**. Signing or verification errors fail the build.

To choose another staging destination or package an already verified release:

```bash
Tools/build_app.sh /path/to/staging/Sekitiri.app
Tools/build_app.sh --skip-build
```

`--skip-build` does not compile; use it only after a successful release build of
the current source. Packaging uses a temporary sibling directory and replaces a
previous staging output only after verification. It refuses an output under
`/Applications` or `~/Applications`; installation remains a separate reviewed
step. The old `~/bin/reassemble-quillnotes.sh` helper is no longer the canonical
packager. Build time depends on dependency caches and hardware; allow the
command to finish rather than treating an output timeout as a compiler error.

Package resources live under `Contents/Resources`, as required for strict
macOS app signing. The current SwiftPM-generated Hub fallback accessor expects
an app-root resource bundle, which macOS strict signing rejects. Supported Qwen
snapshots supply their own complete tokenizer configuration and do not need
that generic fallback. Adding arbitrary/incomplete model snapshots requires a
proper resource-lookup fix in the dependency or an Xcode-produced accessor;
do not rely on a developer checkout's `.build` fallback. Both staged Metal
shader copies are signed before the enclosing executable/app.

For development from the source root:

```bash
swift build
swift test
python3 Tools/evaluate_transcription.py --self-test
```

`swift test` checks processing mechanics with synthetic fixtures. It does not
establish recognition accuracy for English/French accents or end-to-end latency.

### Install to /Applications

First quit Sekitiri and verify the staged bundle. Preserve the prior installed
copy until the replacement passes verification. For an authorized installation,
copy the complete `.local-validation/Sekitiri.app` bundle into `/Applications`,
then run:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Sekitiri.app
```

The build script does not stop the app, modify recordings/settings, or install
anything. Ad-hoc signing is appropriate for local builds; distribution to other
Macs requires the appropriate Developer ID signing/notarization workflow.

### Re-zip the distributable

Keep the verified bundle intact, including its signature and resource bundles:

```bash
ditto -c -k --sequesterRsrc --keepParent .local-validation/Sekitiri.app .local-validation/Sekitiri.zip
```

---

## Golden rules (do not break)

1. **Preserve the capture and notes formats.** Capture folders hold the
   canonical transcript. `MeetingNotesService` copies verified text and writes
   summaries and `.index.json` in the notes vault. The native UI also saves
   participant notes and action-item completion; there is no CLI-only writer.
2. **One app, one icon** — recording runs in-process. Do not reintroduce a
   separate quill daemon/process/icon.
3. **Ad-hoc codesign packaged local builds after copying binaries.** A signature
   from before a binary or bundle modification is no longer valid.
4. **Always** `codesign --force --sign -` after copying a binary into a bundle.
5. **Dark, clean, native desktop UI** (per `Figma-BRIEF.md`). No web-app chrome.
6. **Keep transcription bounded and resumable.** Closed audio segments feed one
   local ASR engine. Completed windows are saved in `transcription-cache/` and
   reused after Stop. Do not restore a separate disposable live model followed
   by a full second transcription pass.
7. **Completion is a verified commit.** `transcript.json` alone is insufficient.
   Save readable Markdown and canonical JSON before the matching
   `transcript.complete.json` record. Capture issues and failed/missing tracks
   remain visible; incomplete text cannot trigger notes or transcription's
   completion hook. With transcription disabled, the configured hook retains
   its existing raw-recording behavior.
8. **Do not promise accuracy, RAM use, or Stop-to-ready time from unit tests.**
   Measure these on representative audio and hardware. Speaker identification
   is excluded from the authoritative transcript's critical path.

---

## Current processing and memory architecture

1. **Capture and transcription:** microphone and system audio are saved to
   disk. One Parakeet engine processes bounded segments and checkpoints results
   during recording; Stop finishes unprocessed work. Parakeet v3 is the default
   for mixed English/French. Optional speaker identification runs separately.
2. **Local note generation:** `SourceSelectionSummary` labels transcript
   sentences. Bounded English/French rules preserve explicit commitments,
   decisions and uncertainty as literal source quotations, with conservative
   owner/deadline extraction. **Source notes · lightweight** skips model loading
   and generation entirely, adding a small deterministic set of context quotes.
   Apple and Qwen optionally classify sentence IDs to supplement context; the
   models cannot rewrite source text or delete commitments. When a later
   correction may affect an earlier decision/task, conservative chronology,
   topic and owner checks move that earlier item into review notes with both
   source and correction links. This does not claim certain supersession;
   explicit later replacements remain active. There are no production
   model-ledger deletion passes. Ambiguities or failed model context generation
   produce a clearly labeled source-based draft. Source rules can miss implicit
   commitments, unfamiliar wording or classification nuance; review linked
   passages and recordings before treating notes as definitive.
3. **Presentation and persistence:** `summary.json` is authoritative. SwiftUI
   renders its records; `summary.md` is a readable compatibility export with
   metadata. Legacy Markdown imports do not acquire inferred provenance or
   inferred owner/deadline fields. Regeneration preserves matching completed
   actions. Serialized read-modify-write operations prevent stale task views
   from overwriting new summaries. A source-input change during generation
   rejects the result and preserves the previous summary.
4. **Resource handoff:** the app blocks summaries while recording or
   transcribing, and cancels/waits for active summarization before recording
   starts. The MLX runtime holds one model lease across an entire generation;
   switching between Qwen sizes cannot load a second active summarizer. The
   runtime limits its reusable MLX cache to 64 MiB, uses quantized bounded KV
   caches, and releases weights/cache immediately after generation on Macs
   with 8 GB RAM or less (30-second retention on larger machines). Thermal or
   memory pressure and recording startup also request model release.

Approximate download sizes (about 1.75 GB for 2B and 652 MB for 0.8B) are **not
RAM measurements**. Peak memory also includes KV cache, inference buffers,
SwiftUI, audio handling and any separate system model services. Do not add
independent ASR and summary measurements as though the engines always overlap.
Benchmark process footprint and MLX allocator counters separately, record
post-unload memory, and include hardware/input/model-cache conditions. The
0.8B evaluation candidate failed factual checks and is excluded from the UI.
Any future smaller model must pass the same checks before being offered.

The source-selection contract takes precedence over old free-form prompt
preferences. Tone currently controls the overview selection. Prompt preferences
remain stored for compatibility and can be read in Settings; the interface does
not offer edits that the current classification pipeline would ignore.

---

## UI spec
Design in progress: `~/Projects/quillnotes-app/Figma-BRIEF.md`.

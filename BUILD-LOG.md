# Sekitiri build log

**Build date:** 2026-08-14 22:56 (Europe/Paris)
**Source:** `/Users/babatopeaiku/Projects/quillnotes-app`
**Product:** Sekitiri native macOS app

## Delivered

- Added in-app playback for completed meetings.
  - Play, pause, stop, seek, elapsed/duration display.
  - Plays available microphone and system-audio tracks together.
  - Missing, empty, or unreadable tracks produce an intentional recovery message.
  - Playback work stays off the SwiftUI main actor.
- Added a true streaming transcription bridge.
  - Microphone PCM is copied from the recorder callback into an async queue.
  - FluidAudio multilingual Nemotron streaming uses the 1120 ms tier.
  - The saved-file transcription pass remains authoritative after recording stops.
  - Live model loading/download failures do not prevent recording or final retry.
- Added the new-user settings inventory in `NEW-USER-SETTINGS.md`.
- Added the model and dependency licensing audit in `MODEL-LICENSE-REPORT.md`.

## Verification

Commands run:

```text
swift build -c release
Build complete

~/bin/reassemble-quillnotes.sh
Built unified /Users/babatopeaiku/Desktop/Sekitiri.app

codesign --verify --deep --strict --verbose=2 /Users/babatopeaiku/Desktop/Sekitiri.app
valid on disk
satisfies its Designated Requirement

open /Users/babatopeaiku/Desktop/Sekitiri.app
Runtime smoke test: process launched successfully
```

Packaged executable:

```text
/Users/babatopeaiku/Desktop/Sekitiri.app/Contents/MacOS/Sekitiri
Mach-O 64-bit executable arm64
Signature: ad-hoc
Bundle identifier: local.sekitiri
```

## Known warning

Swift emits the existing `AudioInputDevice.swift` warning about forming an
`UnsafeMutableRawPointer` to a `CFString` while reading Core Audio device names.
It does not fail the build, but should be cleaned up in a follow-up hardening
pass.

## Release caveat

The licensing audit identifies unresolved terms conflicts for the FluidInference
Parakeet v3 and Sortformer CoreML repositories, and requires pinning/review of
the Nemotron converted assets. The report is intentionally conservative:

`MODEL-LICENSE-REPORT.md`

The current release does not bundle model weights; FluidAudio downloads them at
runtime. Before commercial redistribution, retain the exact model notices and
resolve the report's listed blockers.

## Current output

The verified build is on the Desktop at:

`/Users/babatopeaiku/Desktop/Sekitiri.app`

It was launched for the smoke test but was not copied into `/Applications` by
this build run.

## Model integration follow-up — 2026-08-14

- Added Parakeet TDT v3 as the default multilingual final transcription engine.
- Kept Parakeet TDT v2 available as the English-focused fallback.
- Added an in-app Local transcription selector and an anonymous speaker-label
  toggle.
- Added Sortformer diarization for the completed mixed system-audio track. It
  maps recognized spans to stable `Speaker 0`, `Speaker 1`, etc. labels and
  falls back to `them` if diarization cannot load or process the audio.
- Added a memory guard that chooses palettized Sortformer weights on Macs with
  8 GB or less of physical memory.
- Added `THIRD_PARTY_NOTICES.md` and updated `MODEL-LICENSE-REPORT.md`.

Verification for this follow-up:

```text
swift build -c release
Build complete (existing AudioInputDevice.swift Core Audio pointer warning only)
```

## Quantized local summary models — 2026-08-24

- Added MLX Swift LM, Hugging Face Swift, and Swift Transformers dependencies.
- Added selectable local summary engines:
  - Apple Foundation Model (`afm`) remains the no-download default.
  - Qwen3 4B 4-bit (`qwen3-4b`) for a stronger compact local model.
  - Gemma 3n E2B 4-bit (`gemma3n-e2b`) as the lighter Gemma comparison.
- Qwen and Gemma weights download only when selected for the first summary and
  remain local afterward; transcript content is never sent to an inference API.
- The selected engine is persisted and recorded in summary frontmatter so
  meetings can be compared later.
- Quantized models load within the summary request and are not retained as a
  second resident model. Long transcripts use the existing evidence-extraction
  and consolidation pipeline; Qwen reasoning traces are suppressed and
  stripped defensively.
- Updated `THIRD_PARTY_NOTICES.md` and `MODEL-LICENSE-REPORT.md` with runtime
  and model attribution requirements.

Dependency resolution:

```text
FluidAudio 0.15.5
mlx-swift-lm 3.31.4
mlx-swift 0.31.6
swift-huggingface 0.9.0
swift-transformers 1.3.3
```

Validation:

```text
swift build -c release
Build complete (existing FluidAudio package resource warning only)

Qwen3 4B 4-bit smoke test
PASS — local model loaded and generated a faithful summary on Apple Silicon.

Gemma 3n E2B 4-bit smoke test
ATTEMPTED — the download was stopped by the machine's low remaining disk
space before inference; no Gemma weights remain cached.

MLX Metal runtime
PASS — generated default.metallib was bundled at
Contents/MacOS/Resources/default.metallib.

Installed bundle
PASS — /Applications/Sekitiri.app, 57M, arm64, local.sekitiri, 1.1.0.
codesign --verify --deep --strict --verbose=2: valid on disk.
Runtime smoke test: launched /Applications/Sekitiri.app successfully.
```

Model weights are intentionally not bundled. Qwen and Gemma download only
when selected for the first local summary; the downloaded cache can be removed
to reclaim disk space.

## Clean install — 2026-08-17

- Rebuilt the current source with `reassemble-quillnotes.sh`.
- Replaced `/Applications/Sekitiri.app` with the fresh build.
- Replaced the Desktop app with the same build.
- Verified both app binaries are byte-identical and use bundle identifier
  `local.sekitiri`.
- Confirmed the source project and `~/Meetings` vault remain present.

## Granola-style detection follow-up — 2026-08-14 (historical, superseded)

- Browser-only meeting URLs remained a confirmation hint in this historical
  implementation; the later consent-first revision removed auto-start entirely.
- Calendar-backed meetings were once eligible for automatic recording, but that
  behavior is superseded and no longer exists.
- Both microphone and system-audio recorders now emit only a boolean activity
  signal; raw audio remains in the recording pipeline.
- The historical auto-end experiment used calendar end time plus silence; it is
  superseded by explicit prompts and the disabled-by-default safety timeout.
- Detection prompts now explain whether Sekitiri found a calendar-backed
  meeting or only a possible browser call.

Verification:

```text
swift build -c release
Build complete (existing AudioInputDevice.swift Core Audio pointer warning only)
```

## Active recording status control — 2026-08-19

- Added a persistent `Recording active` button to the desktop sidebar and
  compact navigation bar.
- The button appears while recording starts or remains active and returns the
  user to the live recording screen without changing capture state.
- Rebuilt and installed the updated bundle at `/Applications/Sekitiri.app`.
- Removed the temporary Desktop build so the installed app remains the only
  current app bundle.

Verification:

```text
swift build -c release
CFBundleIdentifier: local.sekitiri
```

## Transcription language selector — 2026-08-19

- Added a persisted language selector under Settings → Local transcription.
- Added Auto-detect, Multilingual, English, French, Spanish, German, Italian,
  and Portuguese modes.
- Live Nemotron streaming now receives the selected language prompt and uses
  the cached language-specific or full multilingual model variant.
- Final Parakeet v3 transcription now receives the selected language hint when
  FluidAudio supports it; Parakeet v2 continues to ignore language hints.
- The selected mode applies to the next recording and does not interrupt an
  active transcription session.
- Rebuilt and installed the updated bundle at `/Applications/Sekitiri.app`.

Verification:

```text
swift build -c release
Build complete (existing AudioInputDevice.swift Core Audio pointer warning only)
CFBundleIdentifier: local.sekitiri
```

The build verifies compilation and linkage. The first completed recording using
each new engine will download its model into FluidAudio's local cache; a live
model download test was not forced during the build because it is large and
requires a real recording/audio fixture.

## Local-only summaries and recording safety — 2026-08-24

- Removed LiteLLM, Ollama, remote model catalogue, Keychain API-key handling,
  OpenAI-compatible network summary requests, and all remote fallback paths.
- Removed the obsolete LiteLLM App Transport Security exception from
  `reassemble-quillnotes.sh`.
- The only summary engine is now Apple's on-device Foundation Model (`afm`).
  The UI presents it as a fixed local model rather than a remote-capable model
  selector.
- Improved summary preparation:
  - removes transcript file metadata and normalises whitespace;
  - preserves speaker labels and timestamps as evidence;
  - splits long transcripts at line boundaries before the model context fills;
  - performs local evidence extraction per segment, then a final local synthesis;
  - uses stricter prompts for decisions, owners, due dates, key points, risks,
    open questions, and the one-line takeaway;
  - treats transcript text as untrusted evidence and forbids invented facts.
- Replaced the previous silence-based/calendar auto-stop path. Sekitiri now:
  - writes an atomic `active.json` heartbeat while recording;
  - recovers interrupted sessions at launch without deleting their audio;
  - prompts when a calendar event ends or a previously detected call disappears;
  - reminds at 60 and 90 minutes without stopping;
  - supports an explicit 2/3/4-hour safety timeout, disabled by default;
  - adds ⌥⌘R as a stop-only keyboard shortcut and keeps a stop action in the
    menu bar;
  - removes the loopback `/start` recording command; `/stop` remains available
    as a local emergency control.
- Added Microsoft Teams desktop detection for `com.microsoft.teams2` and
  `com.microsoft.teams` where macOS Accessibility permission allows it. The
  detector reads only visible Teams window titles and remains prompt-only.
- Kept Parakeet v3 multilingual as the recommended final transcription engine.
  The live Nemotron model and optional Sortformer remain separate local
  processes/models, so they can still affect peak memory. Quantized Qwen3 and
  Gemma summary models are now selectable local options.
- Fixed live-stream cancellation cleanup so the Nemotron backend is released
  even when a recording is paused or stopped before the stream naturally ends.

Verification:

```text
swift build -c release
Build complete! (existing AudioInputDevice.swift Core Audio pointer warning only)

/Users/babatopeaiku/bin/reassemble-quillnotes.sh /private/tmp/Sekitiri-build.app
Built unified /private/tmp/Sekitiri-build.app

Installed: /Applications/Sekitiri.app
codesign --verify --deep --strict --verbose=2 /Applications/Sekitiri.app
valid on disk
satisfies its Designated Requirement

Bundle identifier: local.sekitiri
Version: 1.1.0
Executable: arm64
Bundle size: 57M (MLX runtime and Metal shader library included; model weights
remain in the local Hugging Face cache)
Runtime smoke test: launched /Applications/Sekitiri.app successfully
```

Remaining limitations:

- Apple Foundation Model summaries require Apple Intelligence and a supported
  macOS/Apple Silicon configuration; this build does not silently send text to
  a cloud fallback when it is unavailable.
- Teams desktop does not expose a stable public call-state API. Detection is a
  best-effort Accessibility/window-title signal and can require the user to
  grant Accessibility permission. A missed signal never starts or stops audio.
- A live recording that loses power or is force-killed can only be recovered if
  the underlying CAF files were finalized sufficiently for AVFoundation to read
  them; the session directory and metadata are preserved for inspection.
- The existing Core Audio `CFString` pointer warning remains non-fatal.

## Consent-first recording and deletion controls — 2026-08-24

- Removed calendar auto-start recording completely and force-disabled the
  legacy persisted preference from older builds. Calendar and browser signals
  can remind or prompt, but cannot begin audio capture.
- Fixed the startup race where Stop could be pressed while recorder setup was
  still in flight: Stop now cancels setup, invalidates the pending start, and
  deletes its temporary capture folder if setup finishes late.
- Disabled Pause and microphone changes during setup so the controls cannot
  imply that capture has started before it has.
- Added a confirmed **Discard** action while starting or recording. It stops
  capture and deletes its partial audio and live transcript without creating a
  meeting record.
- Added completed-meeting deletion choices: **Delete audio** preserves the
  transcript, summary, notes and action items; **Delete meeting** removes the
  raw session and the matching local vault entry.

Verification:

```text
swift build -c release
Build complete! (existing FluidAudio package resource warning only)
```

## Meeting detection follow-up — 2026-08-14

- Kept detection inside the Sekitiri process; no extension or second app was
  added.
- The app now stays resident after its window closes, preserving menu-bar
  reminders and meeting detection.
- Calendar changes trigger an immediate refresh, with a 10-second fallback
  poll for browser state.
- Browser meeting IDs are normalized to avoid duplicate prompts caused by
  changing query parameters.
- Browser URLs are filtered for meeting-shaped paths to reduce false positives
  from simply opening a provider home page.
- Calendar and browser signals are fused: matching events supply the real
  meeting title, attendees, schedule, and URL; an unrelated active calendar
  event no longer hides a detected browser call.
- A dismissed call can prompt again after the call disappears and later
  returns.

Verification:

```text
swift build -c release
Build complete (existing AudioInputDevice.swift Core Audio pointer warning only)
```

## Fast, reliable local summaries — 2026-08-29

- Removed LiteLLM/external summary choices from the active product path and
  reduced the visible local catalogue to:
  - Apple Foundation Model (`afm`) as the zero-download default when available;
  - Qwen3.5 2B 4-bit (`mlx-community/Qwen3.5-2B-4bit`) as the only downloadable
    summary model.
- Migrated saved Gemma 3n E2B and Qwen3 4B selections to Apple when available,
  otherwise to Qwen3.5 in the explicit `notDownloaded` state.
- Added explicit Qwen states and controls: Not downloaded, Downloading with
  progress, Ready, Loading, and Failed, plus Download, Cancel, Retry, and
  confirmed Remove actions. Summarise never initiates a download.
- Enforced 3.5 GB free space before download (model snapshot is approximately
  1.75 GB, with room reserved for temporary files).
- Kept the Qwen container warm for five minutes after use. It unloads before
  recording/final transcription and under macOS warning/critical memory
  pressure.
- Added visible/cancellable summary stages: preparing transcript, loading
  model, generating, bounded structure repair, and saving.
- Replaced character routing for Qwen with exact tokenizer routing:
  - one deterministic generation for input up to 24,000 model tokens;
  - bounded 18,000-token evidence chunks only above that limit;
  - no consolidation pass unless extracted evidence itself exceeds 24,000
    tokens;
  - one structure repair at most, and only when required headings are missing
    or out of order.
- Qwen generation now uses non-thinking prompts, temperature 0, 8-bit KV
  caching, tone caps of 500/650/900 output tokens, and an input-sized KV window
  (2,048 minimum, 32,768 maximum) to reduce memory pressure on 8 GB Macs.
- Strengthened the v2 default prompts to audit every commitment, owner, and
  date before writing Action Items. User-edited per-tone prompts remain
  untouched and can be reset explicitly to the v2 default.
- Added high-confidence cross-track transcript deduplication. It removes only
  near-identical lines from different speakers/tracks within two seconds and
  preserves distinct turns, timestamps, and attribution.
- Summary frontmatter now records model ID, prompt version, pipeline version,
  duration in milliseconds, input-token count, and generation pass count.
- Added three synthetic local benchmark fixtures (short, noisy diarized, and
  hour-span) with expected decisions, owners, dates, actions, risks, and
  unsupported-claim checklists. No meeting is collected for training and no
  LoRA trainer was added.
- Removed the obsolete local Gemma 3n and Qwen3 4B caches during final cleanup.
  The benchmark-only Qwen3.5 cache was also removed after verification, so the
  installed app remains zero-weight by default and Qwen uses the explicit
  Download control.

Verification:

```text
swift test -c release
7 deterministic baseline tests passed (0 failures)

Qwen3.5 opt-in inference benchmark, MacBook Air M1 / 8 GB:
- short sanitized fixture: required headings and expected Paris/Leon/date/legal
  facts passed after prompt tuning (about 17 seconds including warm transition)
- existing 61 KB transcript, warm model: 262.257 seconds, one generation pass
- required <90 second target: FAILED

/Users/babatopeaiku/bin/reassemble-quillnotes.sh /Applications/Sekitiri.app
Built unified /Applications/Sekitiri.app

codesign --verify --deep --strict --verbose=2 /Applications/Sekitiri.app
valid on disk; satisfies its Designated Requirement

Installed bundle: 58M
Executable: arm64
MLX default.metallib: present in Contents/MacOS/Resources
```

Remaining limitations:

- Qwen3.5 2B meets the memory/quality direction but does not meet the 90-second
  one-pass target for this noisy 61 KB transcript on an 8 GB M1 Mac. The app
  now reports stages and supports cancellation, but this model/runtime/hardware
  combination should not be described as fast for long meetings.
- The live benchmark verified headings, expected short-fixture facts, warm
  reuse, and one-pass routing. Download cancellation and forced load-failure UI
  paths are implemented with actionable messages but were not subjected to
  destructive network/filesystem fault injection in this minimal test run.
- Apple Foundation Model remains the smoothest default when Apple Intelligence
  is available. On unsupported Macs, Qwen requires an explicit download and at
  least 3.5 GB free.
- Actual LoRA fine-tuning remains intentionally deferred until approved local
  transcript/ideal-summary pairs and benchmark evidence justify it.

## Summary failure fix — 2026-08-30

The installed build was exercised before this fix and reproduced both reported
failures: Qwen returned a summary that was rejected after the literal-heading
repair check, while Apple Foundation Models failed with “Exceeded model context
window size” on the same long meeting. The repair is local to the summary
pipeline and does not add a model or a cloud dependency.

- Apple summary requests now budget against the Foundation Models context size.
  On SDKs exposing the tokenizer API, Sekitiri uses the model's actual token
  count; older macOS 26 SDKs use a conservative local estimate. Instructions,
  source wrapper, transcript, and reserved output space are counted together.
- Apple long transcripts now use bounded speaker-line chunks for evidence, then
  reduce evidence only when the final synthesis would exceed the context
  window. This replaces the unsafe 14k-character assumption and gives an
  actionable error for an individually oversized line.
- Qwen and Apple summaries now canonicalise common Markdown drift (for example
  `Overview`, `Outcomes`, `Next steps`, and `Questions & Risks`) before checking
  the six required sections. The single repair prompt is compact and no longer
  repeats the full user prompt.
- Prompt defaults are now version 3 and explicitly preserve distinct languages,
  speakers, and statements while auditing commitments, owners, and dates.
- Added deterministic tests for heading canonicalisation and preservation of
  distinct bilingual evidence.

Verification:

```text
swift build -c release
Build complete (existing FluidAudio resource warning and AudioInputDevice.swift
CFString pointer warning only)

swift test -c release --filter SummaryPipelineTests
9 tests passed, 0 failures; the Qwen inference benchmark remained gated and did
not download model weights.

/Users/babatopeaiku/bin/reassemble-quillnotes.sh /Applications/Sekitiri.app
Built unified /Applications/Sekitiri.app

codesign --verify --deep --strict --verbose=2 /Applications/Sekitiri.app
valid on disk; satisfies its Designated Requirement

Installed bundle: 58M
Executable: arm64
Bundle identifier: local.sekitiri
MLX default.metallib: present
open /Applications/Sekitiri.app
Launch command completed; final UI inspection was unavailable because macOS
was locked and Computer Use could not unlock it automatically.
```

Remaining limitations:

- The prior warm 61 KB Qwen benchmark remains the honest performance baseline:
  262.257 seconds on an 8 GB M1 Mac. This fix addresses correctness, context
  failures, and unnecessary repair work; it does not change Qwen's underlying
  generation speed.
- A live post-install summary run could not be repeated while the Mac was
  locked. The new deterministic tests cover the repaired preprocessing and
  output-validation paths; the existing Qwen benchmark remains available via
  `SEKITIRI_RUN_MODEL_BENCHMARK=1`.

## Final local summary verification — 2026-08-31

The live failure was reproduced with the installed app. The saved legacy
prompt requested `Key Takeaway`/`Open Questions`, which conflicted with the
current six-section contract; Qwen also stopped mid-bullet at the compact
Concise output limit. A clean restart was required after installation because
the first UI run was served by an older process.

- User-edited prompts remain stored unchanged, but inference now treats their
  formatting and length instructions as style guidance and applies the
  parser-owned canonical headings (prompt version 5, pipeline version 6).
- Added a deterministic final formatter after generation/repair. It preserves
  supported model facts, removes obviously unfinished trailing bullets, bounds
  noisy Key Points/Open Questions sections, and converts inline bullet-shaped
  Summary output into prose. It does not invent missing facts.
- Final live test through the installed `/Applications/Sekitiri.app` on the
  existing 6,395-token Team Weekly transcript: Qwen3.5 2B 4-bit completed in
  50.844 seconds, with complete required headings and no summary error. Saved
  metadata records `summary_prompt_version: 5`,
  `summary_pipeline_version: 6`, and `summary_pass_count: 2` (one generation
  plus one bounded formatting repair).

Verification:

```text
swift test -c release --filter SummaryPipelineTests
12 tests passed, 0 failures

/Users/babatopeaiku/bin/reassemble-quillnotes.sh /Applications/Sekitiri.app
Built unified /Applications/Sekitiri.app

codesign --verify --deep --strict --verbose=2 /Applications/Sekitiri.app
valid on disk; satisfies its Designated Requirement

Installed bundle: 58M
Executable: arm64
```

Remaining limitations:

- The result is now reliable and bounded, but Qwen3.5 2B can still mis-hear or
  over-compress facts when the transcript itself is noisy. The current live
  run required a repair pass; it did not meet the original one-pass target.
- Apple Foundation Models use the new token-budgeted path, but availability
  and context size remain controlled by macOS. Qwen remains the only explicit
  downloadable fallback and is never downloaded by the Summarise button.

## Eight-gigabyte stability and evidence-first summaries — 2026-10-02

This build makes durable recording the highest-priority workload when Sekitiri
is used beside Zoom, Teams, or a browser.

- Replaced the unbounded live-ASR stream with a newest-four-chunk buffer. If
  live recognition falls behind, stale partial audio is dropped while the
  authoritative recording continues writing to disk.
- Removed per-audio-buffer Swift tasks and the obsolete 24-second snapshot
  buffer. Audio now enters one persistent streaming consumer directly.
- Live ASR cleanup is awaited before final ASR can load. Final Parakeet is
  released before Sortformer loads, so those heavyweight models no longer
  coexist.
- Added a recording inference permit. Starting a new recording cancels and
  requeues older final-transcription work before Nemotron can load; queued work
  resumes after the recording ends.
- Memory pressure and serious thermal pressure now suspend live transcription,
  never recording. The UI explains that the complete transcript will be
  generated after the meeting.
- Qwen summary weights unload immediately after use on an 8 GB Mac and after
  30 seconds on larger Macs. Summary downloads and generation are blocked
  during recording.
- System-audio capture is now best effort. A permission, aggregate-device, or
  route failure preserves microphone recording and reports a degraded state.
- Audio writer failures are latched instead of retried on every callback.
- Completed-session metadata is written atomically. `active.json` is retained
  if metadata finalisation fails so launch recovery can rebuild the session.
- Activity detection now checks its one-second reporting interval before
  scanning samples, avoiding needless callback work.
- Every Qwen summary now runs through a high-confidence evidence pass. Chunks
  split at speaker-line boundaries, the KV cache is capped at 16K tokens, and
  the extraction contract distinguishes commitments from suggestions,
  questions, and possibilities while preserving negation.
- Added deterministic resource tests for bounded live audio and summary-model
  retention.

Verification:

```text
swift test
14 tests passed, 0 failures

swift build -c release
Build complete (existing FluidAudio resource warning, AudioInputDevice CFString
pointer warning, and non-fatal Swift module-cache debug-info warnings only)

/Users/babatopeaiku/bin/reassemble-quillnotes.sh /private/tmp/Sekitiri.app
Built unified /private/tmp/Sekitiri.app

codesign --verify --deep --strict /Applications/Sekitiri.app
valid

Installed process:
/Applications/Sekitiri.app/Contents/MacOS/Sekitiri
```

Not completed in this build:

- A two-hour Zoom/Teams stress run and fault-injection test still require an
  actual live meeting environment.
- Canonical `summary.json` evidence storage and stable action-item IDs remain
  the next summary-pipeline phase. This build improves evidence extraction but
  keeps `summary.md` as the persistence contract for compatibility.
- Phonon-2 was not bundled. It remains a candidate for an optional English
  post-call benchmark after the recording lifecycle is stress-tested.

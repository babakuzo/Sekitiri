# Sekitiri — New-user settings inventory

Status: requirements inventory only. This document does not change the SwiftUI implementation.

## Scope

Sekitiri is a lightweight, local-first macOS meeting recorder for a user who wants to start a meeting quickly, see a live transcript, review a durable local recording, and generate useful notes without having to understand audio permissions, model files, or API infrastructure first.

This inventory is grounded in the existing SwiftUI app and the stated product goal. It covers:

- the first-run screens a new user needs;
- the later Settings screens and controls those choices belong in;
- defaults, permission copy, failure states, and recovery paths;
- the boundaries between local recording, local transcription, and local summarisation.

This is a repository-grounded requirements pass, not a public complaint scan. No external user-research signal was available or assumed. Observed implementation facts are marked as **Current**; proposed product decisions are marked as **Proposed**.

## What exists today

The current app already has most of the underlying concepts, but presents them as a single Settings page rather than as a guided setup:

- `SettingsView.swift` exposes consent-first recording safety, meeting reminders, browser and Teams detection, system audio, microphone selection, vault path, summary tone, per-tone prompts, and a local privacy banner.
- `Info.plist` declares microphone, system-audio, calendar, and Apple Events usage descriptions.
- `CalendarService.swift` requests full calendar access, reads event titles and attendee names, and inspects the active tab URL in Chrome/Chromium/Edge/Safari for Meet, Zoom, Teams, and Webex links.
- `RecordingSession.swift` stores separate microphone and system-audio tracks, meeting metadata, title overrides, and additional notes. A system-audio failure is designed not to discard the microphone recording.
- `TranscriptionCoordinator.swift` resumes unfinished transcription jobs at launch, keeps a retryable queue, writes `transcribe.log`, and releases the ASR engine when the queue drains.
- `ParakeetEngine.swift` is currently the only transcription engine and downloads/loads FluidAudio Parakeet TDT v2; this is separate from the summary-model selector.
- `MeetingNotesService.swift` uses only the Apple Foundation Model when available. No API key, external endpoint, or remote model catalogue is used.
- `Notify.swift` sends best-effort macOS notifications through `osascript`; there is no visible notification-permission/test screen yet.
- The status-bar menu provides start/stop/open/quit actions, but there is no user-facing global keyboard shortcut setting.

Important current distinction:

> Recording, transcription, and summarisation are three different capabilities with different data flows. They should not be presented as one generic “model” setting.

## First-run flow

The first run should be short and interruptible. A user should be able to finish setup in under two minutes, skip optional integrations, and still record a local meeting immediately.

### Screen 1 — Welcome and privacy choice

**Purpose:** establish trust before requesting permissions.

**Primary copy:**

> Sekitiri keeps recordings, transcripts, notes, and summaries on this Mac. It does not send meeting text to external summarisation services.

**Show:**

- “Local by default” summary.
- What is saved locally: microphone audio, optional system audio, transcript, additional notes, summaries when using Apple Intelligence/local models.
- What can leave the Mac: nothing as part of recording, transcription, or summarisation.
- A consent reminder: the user is responsible for telling participants and obtaining consent before recording.
- Link/button to “View privacy details”.

**Controls:**

- `Continue`.
- `Set up later` (opens the app with recording available and marks setup incomplete).
- No remote-summary preference is required because external summary models are not supported.

**Later Settings:** `Privacy & data`.

### Screen 2 — Microphone and system-audio permissions

**Purpose:** make recording readiness explicit before the user clicks Start Recording.

Separate the two permissions because they fail independently.

#### Microphone

- Request microphone access.
- Show state: `Not requested`, `Allowed`, `Denied`, `No input device`, or `Device disconnected`.
- Show the detected default microphone and a `Choose microphone` control.
- Explain that the microphone track represents the user and is used for live/final transcription.
- Provide `Open System Settings` when denied.
- Provide `Test microphone` with a short level meter and a clear result.

#### System audio

- Explain that this captures the other side of a browser call or computer playback.
- Request/guide the macOS Screen & System Audio Recording permission separately.
- Show state: `Off`, `Allowed`, `Not available`, or `Disconnected`.
- Offer `Enable system audio` as an opt-in toggle. Keep it enabled by default only if the user explicitly chooses it during setup; never make a failed system-audio permission block microphone-only recording.
- Provide `Test system audio` and a recovery link to `System Settings → Privacy & Security → Screen & System Audio Recording`.
- Explain the macOS recording indicator.

**Current evidence:** system audio is optional in `RecordingSession`; a system-audio failure preserves the microphone recording. The recording screen already reports independent capture health.

**Later Settings:** `Recording → Audio capture`.

### Screen 3 — Calendar connection

**Purpose:** make meeting titles, times, attendees, reminders, and auto-start useful without making Calendar mandatory.

**Show:**

- `Connect Calendar` button requesting full access to calendar events.
- What is read: event title, start/end time, calendar source, meeting URL, and attendee display names.
- What is not written: Sekitiri does not create or modify calendar events.
- Example benefit: “Your calendar title and attendees can be attached to the recording.”
- State after grant: connected calendar count/source and `Refresh calendar`.

**Controls:**

- `Use calendar titles for recordings` — on by default after connection.
- `Show upcoming meetings on Dashboard` — on by default.
- `Remind me before meetings` — on by default, with reminder timing control (recommended default: 5 minutes).
- `Start recording automatically` — off by default; require a second confirmation because this captures audio without a click at meeting start.

**Denial state:**

- Keep manual recording fully available.
- Dashboard shows an intentional empty schedule state: “Calendar isn’t connected. You can still start a free recording.”
- Offer `Connect Calendar` again from Dashboard and Settings.

**Later Settings:** `Integrations → Calendar & reminders`.

### Screen 4 — Meeting detection in browsers

**Purpose:** explain what “detect a meeting” means and avoid a surprising automation permission.

**Default:** off until the user opts in during setup. This is more understandable than silently inspecting the active browser tab.

**Show:**

- Supported browsers currently implemented: Chrome, Chromium, Edge, and Safari.
- Supported URL families: Google Meet, Zoom, Microsoft Teams, and Webex.
- Plain-language data boundary: “Sekitiri reads the active tab URL only to recognise a meeting link. It does not read page contents, messages, or participant lists.”
- Why Apple Events access is needed.

**Controls:**

- `Detect active browser meeting tabs`.
- `Prompt me to record when a meeting is detected` — on by default when detection is enabled.
- `Open supported browser` / `Test detection`.

**States:**

- `Ready` — browser access granted and a supported browser is frontmost.
- `Needs permission` — show `Open System Settings` and the relevant Automation/Apple Events recovery copy.
- `No supported meeting tab` — not an error; show the last check time.
- `Meeting detected` — show app confirmation with title/platform and “Start Recording”; require consent reminder in the confirmation.

**Current evidence:** `CalendarService` uses `NSAppleScript` to read the active tab URL and has an Apple Events usage description. Firefox is not currently implemented and should not appear as supported until it is.

**Later Settings:** `Integrations → Browser detection`.

### Screen 5 — Transcription setup

**Purpose:** make local transcription work without exposing model complexity.

This screen must be separate from the summary model/API screen.

**Show:**

- `Live transcription` toggle — on by default if the selected live model is installed and supported.
- `Final transcription` toggle — on by default.
- Language selector: `Automatic` plus the languages supported by the installed model.
- Current backend and model name, with a simple label such as `Local · on this Mac`.
- Download size, installed size, available disk space, and download progress.
- `Download model`, `Pause`, `Retry`, and `Remove downloaded model` actions.
- “Live text is provisional; final transcription may improve it after you stop recording.”
- “Audio remains local for local transcription.”

**Recommended product presentation:**

- `Balanced` — lightweight streaming model for live text and a fast final pass.
- `Highest quality` — larger local final-pass model, loaded only when needed.
- `Language pack` — optional model/download for languages outside the default pack.

Do not ask a new user to choose between raw model identifiers on this screen. Put an `Advanced model details` disclosure below the simple choices.

**Current evidence and gap:** the code currently supports only Parakeet v2 through `ParakeetEngine` and the live path is a rolling snapshot transcription loop in `TranscriptionCoordinator`. There is no transcription-language selector or model-download UI yet. The planned streaming/final-pass architecture should preserve the same settings contract.

**Failure states:**

- No model installed: recording still starts; show `Recording safely — live transcription will begin after the model is ready`.
- Download failed: show the reason, `Retry`, and `Continue without transcription`.
- Model unavailable for selected language: keep the recording and offer another installed model/language.
- Memory pressure: unload the live model before loading the final model and offer the lightweight fallback.
- Transcription failed: keep audio, show `Retry transcription`, `Change model`, and `Reveal recording`.

**Later Settings:** `Transcription → Language & models`.

### Screen 6 — Local summaries

**Purpose:** explain that meeting summaries are generated on this Mac with the
system Apple Foundation Model, without an account, API key, or external model.

**Show:**

- `Apple Foundation Model — On-device`.
- Model availability and Apple Intelligence requirements.
- A short explanation that long transcripts are processed in local evidence
  segments before the final local synthesis.
- The selected summary tone and its editable instructions.
- A clear recovery state when the system model is unavailable; the transcript,
  recording, and notes remain available for later retry.

**Later Settings:** `Summaries → Local model & instructions`.

### Screen 7 — Vault and storage

**Purpose:** make it obvious where files live and prevent a first recording from disappearing into an unknown directory.

**Recommended defaults:**

- Notes vault: `~/Meetings`.
- Raw recordings: `~/Recordings`.

**Show:**

- separate paths for notes and raw recordings;
- storage used/free space;
- count of recordings waiting for transcription;
- `Open notes folder` and `Open recordings folder`;
- whether files are plain Markdown/audio and remain readable without Sekitiri;
- retention control: `Keep recordings`, `Delete recordings after successful transcript`, or `Ask me` (default: keep);
- `Move vault` / `Choose folder` with a validation step;
- migration warning before changing an existing location.

**Current evidence and implementation note:** the app uses `~/Recordings` as the default capture root through `Config`, while the native notes service defaults to `~/Meetings`. The current `SettingsView` path field is labelled “Local Notes Directory” and opens the folder, but the inventory should treat persistence/validation of that setting as a required product behavior, not assume the field alone changes the service configuration.

**Later Settings:** `Storage & vault`.

### Screen 8 — Notifications and consent reminders

**Purpose:** let users understand why Sekitiri may interrupt them and control reminder frequency.

**Controls:**

- `Meeting reminders` — on by default.
- Reminder timing: 1, 5, 10, or 15 minutes before start.
- `Meeting detected` prompts — on by default if browser detection is on.
- `Transcript ready` notification — on by default.
- `Transcription failed` notification — always on unless the user deliberately disables failure alerts.
- `Audio connection changed` alert — on by default while recording.
- `Test notification`.

**Copy requirement:** every recording prompt should remind the user to obtain participant consent. This is a product safeguard, not a substitute for local law or workplace policy.

**Current evidence:** notification delivery is best-effort through `osascript`; the app currently sends reminders within five minutes of a calendar event and sends detected-call/recording/failure messages. Add an explicit permission/status/test state so a user can tell whether notifications are actually working.

**Later Settings:** `Notifications & consent`.

### Screen 9 — Shortcuts and status-bar controls

**Purpose:** keep starting/stopping fast without adding another required setup step.

**Current controls:** status-bar menu actions for Start/Stop Recording, Open Sekitiri, and Quit.

**Settings inventory:**

- `Show Sekitiri in the menu bar` — on by default.
- `Start/stop recording shortcut` — proposed; unset by default to avoid conflicts.
- `Open app shortcut` — proposed; unset by default.
- `Confirm before stopping` — off by default, but recommended when recording is under 10 seconds.
- `Launch at login` — proposed, off by default.

**Later Settings:** `Shortcuts & launch`.

Do not expose the loopback recording-control server as a first-run setting. If retained for integrations, document it under `Advanced → Integrations` with a local-only/network-boundary explanation.

### Screen 10 — Diagnostics and recovery

**Purpose:** turn “it did not record” or “the transcript is missing” into a recoverable state rather than a mystery.

**Health checklist:**

- microphone permission and selected device;
- live input level;
- system-audio permission and connection;
- calendar access;
- browser automation access;
- notes vault writable;
- recordings folder writable and sufficient disk space;
- transcription model installed and compatible;
- summary model/API connection;
- notifications enabled;
- last successful recording/transcription/summary timestamps.

**Actions:**

- `Run diagnostics`.
- `Copy diagnostic report` with secrets, transcript text, and audio excluded by default.
- `Open logs`.
- `Retry transcription`.
- `Retry summary`.
- `Reveal recording files`.
- `Open System Settings` for the relevant permission.
- `Reset setup choices` without deleting meetings or recordings.
- `Export a support bundle` only after an explicit confirmation.

**Current evidence:** unfinished transcription jobs are rescanned at launch; failed jobs write `transcribe.log`; the recording screen has retry-save/retry-transcription/reveal-recording paths. These recovery actions should become discoverable in the UI.

**Later Settings:** `Diagnostics & recovery`.

## Proposed Settings information architecture

The current single-page Settings view should eventually be reorganised into these groups. Keep the first-run flow focused; expose the full inventory only after setup.

1. **Getting started**
   - setup completion status;
   - rerun setup;
   - current recording readiness summary.

2. **Recording**
   - microphone and device test;
   - system audio;
   - consent-first stop reminders and safety timeout;
   - title source and calendar metadata;
   - consent confirmation behavior.

3. **Transcription**
   - live/final transcription;
   - language;
   - model profiles and downloads;
   - model cache size;
   - memory fallback;
   - retry behavior.

4. **Summaries**
   - local Apple Foundation Model availability;
   - Concise, Detailed, and Executive Brief prompts;
   - one-line dashboard summary requirement;
   - local retry and context-window behavior.

5. **Integrations**
   - Calendar;
   - Browser detection;
   - future calendar/browser providers.

6. **Storage & privacy**
   - notes vault;
   - raw recordings;
   - retention and deletion;
   - local-only data-flow explanation;
   - export/import.

7. **Notifications & shortcuts**
   - reminders;
   - transcript/failure alerts;
   - menu bar;
   - keyboard shortcuts;
   - launch at login.

8. **Diagnostics**
   - health checks;
   - logs;
   - recovery and support bundle;
   - app/model versions;
   - license acknowledgements.

## First-run defaults

| Setting | Recommended default | Why |
|---|---|---|
| Local recording | On | The primary product promise. |
| Microphone | Ask, then select default input | Recording cannot be trusted without a known input route. |
| System audio | Ask separately; opt in | It needs a distinct macOS permission and is not required for mic-only capture. |
| Live transcription | On when model is installed | Immediate feedback is central to the recording experience. |
| Final transcription | On | Produces the durable transcript after stop. |
| Language | Automatic | Avoids forcing model jargon; allow an explicit override later. |
| Calendar | Not connected until user grants | Calendar is useful but not required for manual recording. |
| Calendar reminders | On after calendar connection | The user explicitly asked for reminders. |
| Automatic recording | Off | It captures audio without a direct click and needs deliberate consent. |
| Browser detection | Off until opt-in | It requires active-tab automation access and can feel surveillant without context. |
| Summary model | Local Apple Intelligence when available | Keeps text local and requires no API key. |
| External summarisation | Not supported | Keeps meeting text on this Mac. |
| Summary tone | Concise | Best default for a lightweight review surface. |
| Raw recordings | Keep | Enables retry, playback, re-transcription, and recovery. |
| Notes vault | `~/Meetings` | Matches the existing canonical vault convention. |
| Recordings folder | `~/Recordings` | Matches the existing capture-root convention. |
| Notifications | On for reminders, ready, and failures | Makes background processing visible. |
| Menu bar item | On | Enables quick start/stop. |

## States every screen must design

Every permission/integration/model row needs more than a binary toggle. The minimum state set is:

- not configured;
- requesting permission;
- connected/ready;
- unavailable on this macOS version or hardware;
- denied;
- disconnected;
- degraded but still recording;
- processing;
- failed with a specific recovery action.

For recording specifically, the user must always be able to distinguish:

- `Ready`;
- `Starting recorder`;
- `Recording in progress`;
- `Recording paused`;
- `Recording safely, transcription unavailable`;
- `Recording complete — improving transcript`;
- `Transcript ready`;
- `Transcription failed — recording preserved`.

## New-user acceptance checklist

- A user can finish setup with only microphone access and record a local meeting.
- Denying Calendar, browser detection, system audio, or notifications does not block local recording.
- The app explains every permission before requesting it and offers a direct recovery action after denial.
- The user can see the selected microphone and test it before recording.
- System-audio failure is visibly degraded, not silently treated as a successful two-sided capture.
- The user can see where audio, transcripts, notes, and summaries are stored.
- Local summary-model availability and the retry path are visible at the summary action.
- Model downloads show size, progress, cancellation, retry, and removal behavior.
- A recording is playable and re-transcribable even when model loading or summarisation fails.
- Additional notes remain visible and are never silently discarded on save failure.
- A new user can rerun setup without deleting meetings, recordings, prompts, or model caches.
- Diagnostics can be copied without exposing raw audio or private transcript content.

## Follow-up product decisions

These choices should be resolved before implementing the onboarding screens:

1. Is system audio opt-in during setup, or enabled by default after an explicit explanation?
2. Which languages and local transcription backends are supported in the first release, and what are their exact download sizes and licenses?
3. Does “final transcription” replace provisional live text automatically, or ask before replacing user-edited text?
4. Should the notes vault and raw recording directory be independently configurable, and does moving them migrate existing files?
5. Which notification API should replace or wrap the current best-effort `osascript` path so permission status is inspectable?
6. Which global shortcuts are safe defaults, if any?
7. What is the retention policy for raw audio, and can a user delete audio while retaining transcript/summary files?
8. Which browser support is promised publicly? Current code supports Chrome/Chromium/Edge/Safari, not Firefox.
9. Which model-license acknowledgements must ship in-app for bundled FluidAudio/NVIDIA/third-party assets?

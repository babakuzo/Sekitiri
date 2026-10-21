# Sekitiri — Figma Design Brief (macOS Desktop App)

Build screens for a native macOS desktop app (SwiftUI/AppKit, single window, dark mode).
Hand this brief + the reference screens to Figma AI ("Make design" / "Build wireframes").

---

## 1. Product in one line

A private, on-device meeting recorder + note-taker. It records mic + system audio, transcribes locally, writes Markdown notes to a local vault, and summarizes them with a selectable AI model.

## 2. Design language

- **Dark theme** (near-black `#111214` background, elevated panels `#1B1D21`).
- **Single accent** — a calm blue/violet (e.g. `#5B8CFF`). Use it sparingly for the active selection, the record button, and the active model.
- **Two-column productivity layout** (like Notes / Notion / Linear). Thin (1px) borders `#2A2D33`.
- **Typography:** System font (SF Pro). Titles `Semibold 16`, body `13`, captions/meta `11` in a muted gray (`#8A8F98`). Timestamps/transcripts in monospaced font.
- **Spacing:** 12px base grid. Rounded corners 8px on cards/buttons, 6px on small pills.
- **Native feel** — no web-chrome, no giant hero, no gradients. Subtle, dense, fast.
- Window default ~960 × 680. Collapsible left sidebar (~240px).

## 3. Screens to produce

### Screen A — Main window (default, "Record / Live" state)
Layout (left → right):
1. **Sidebar (240px)**
   - Top: app name **"Sekitiri"** + a small status dot (idle = gray, recording = red, pulsing).
   - Nav: **Record**, **Meetings**, **Settings** (2–3 items, compact list).
   - Bottom of sidebar: current **active model** as a small card (see Screen C) with a "Change" affordance.
2. **Main panel — Header**
   - Big **Record button** (circular or pill) + elapsed timer (monospaced) + live status line ("Listening…", "Ready").
   - Right of header: a **model selector** (the "toggle models" control — see Model Control below).
3. **Main panel — Body**
   - **Live transcript** scroll view: speaker-attributed lines (`[You]`, `[Speaker 1]`) with faint timestamps on the left margin, latest line highlighted.
   - This is "record + watch live" view.

### Screen B — Meetings list + detail
1. **List** (center column): newest first. Each row = meeting **title/date**, a small **engine badge** (e.g. `llama3.2`, `afm`, `gpt-4o-mini`), **duration**, and a check mark if summarized.
2. **Detail** (right column, on selection):
   - Tabbed content: **Summary** | **Raw Transcript**.
   - Summary tab renders the Markdown note: highlighted sections (**Key Takeaway**, **Decisions**, **Action Items** as checkboxes, **Key Points**, **Open Questions**, **Summary**).
   - Raw Transcript tab = monospaced, speaker-tagged, scrollable.
   - Toolbar above detail: **Re-summarize** button + the **model selector** + a small spinner while running.

### Screen C — Model selector ("toggle between models")
This is the key control you must design clearly. Two viable presentations — pick one and be consistent:

**Option 1 — Dropdown/popover (recommended, compact):**
- A button showing the **active model name** + a chevron.
- On click: a popover listing all available models in groups:
  - **Local (on-device)** — Apple (`afm`), Ollama models *(e.g. Llama 3.2)*
  - **Remote (LiteLLM gateway)** — DeepSeek / GPT-4o mini / Claude Haiku / Gemini Flash / Kimi / GLM / Smart etc.
- Each row: model name, a tiny "provider" tag (`Local` / `Remote` / `Ollama`), and the **active model has a check** on the left.
- Footer note: "Remote models send text to your private gateway."

**Option 2 — Toggle chips:**
- A horizontal row of model chips; the active one is filled with the accent color. Clicking switches.
- Less scalable if many models — use only if the list stays short.

> Important: **the model selector must appear in BOTH the Record view header (Screen A) and the Meeting detail toolbar (Screen B)**, so the user can pick the summarizer anywhere. Show the current engine name clearly at all times.

### Screen D — Settings
- **Recording:** auto-record toggle (tie to calendar), default microphone, system-audio on/off.
- **Summarization:** default model (reuse Model selector from Screen C), AFM fallback toggle.
- **Vault / storage:** path to `~/Meetings`, storage used, "Open vault in Obsidian" button.
- **Model manager:** full list of available models w/ add/remove (local + remote), test-connection button.
- **Privacy:** plain-English explanation that audio stays on-device and only text is sent when you choose a remote model.

## 4. Model control — must-haves (call these out to Figma)

1. **Always visible active model** (name + Local/Remote tag).
2. One-click change via the selector above.
3. Clear **Local vs Remote** grouping with a privacy note on remote.
4. A visual "selected" state (check or filled chip).
5. Reusable component — same control in header + detail toolbar.

## 5. Copy / labels (use verbatim)

- Record states: **"Ready"**, **"● Recording…"**, **"Stopped — transcribing…"**
- Model groups: **"Local (on-device)"**, **"Remote (LiteLLM)"**, **"Ollama"**
- Detail tabs: **"Summary"**, **"Raw Transcript"**
- Actions: **"Start Recording"**, **"Stop Recording"**, **"Re-summarize"**, **"Change"**, **"Manage Models"**

## 6. Notes for Figma

- Dark mode only for now (no light variant needed).
- Keep components reusable (Model Selector, Meeting Row, Engine Badge, Tab Bar).
- Native macOS window chrome (traffic lights top-left) is assumed — design the *content* inside.
- This is a **real, buildable** spec — we will implement these screens in SwiftUI, so prefer clean, minimal, standard components over decorative flourish.

## 7. Deliverable

Provide the screens as Figma frames (one per Screen A–D), with the Model Selector component defined once and reused across A and B. Annotate interactive states: hover, selected, dropdown-open, recording-active.

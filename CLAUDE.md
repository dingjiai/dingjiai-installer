# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Scope
- Scope: this repository root `D:\顶级AI\项目\npm包`.
- This file is the authoritative project guide for this repo.
- If a durable product, architecture, naming, or distribution decision changes, update this file in the same change.
- `README.md` is for end users. `notes/*.md` are supporting design notes. This file records durable working rules.
- When doing any work in this repository, follow this `CLAUDE.md` as a mandatory operating contract.
- If this document conflicts with a user request, observed project state, or other guidance, stop and ask the user before acting.

## Project document index
- `README.md` — end-user entry, current public command, visible capability status, and usage guidance.
- `notes/architecture/整体架构.md` — current high-level architecture discussion and cross-platform direction.
- `notes/architecture/启动阶段（一次性）.md` — Windows startup-stage source of truth: bootstrap, payload, handoff, state, and startup hardening.
- `notes/windows-architecture.md` — Windows installer implementation notes: layered model, flow/checkpoint layout, and current checkpoint contracts.
- `notes/claude-cli-baseline.md` — confirmed Claude CLI path baseline, dependency assumptions, and placeholder trust fields.
- `notes/tool-inventory.md` — broader helper-tool inventory and selected package identities.
- `notes/mas-analysis/deep-research-report.md` — MAS mechanism reference material for clean-room architecture study.
- `docs/` — GitHub Pages publishing root for runnable installer assets only; not a design-document location.
- `docs/installer/windows/check-startup.ps1` — required self-check after Windows startup payload, manifest, or contract changes.

## Project positioning
- This repository is an open-source, beginner-friendly installer and launcher.
- Target users include beginners and non-programmers, not only developers.
- Keep the product general-purpose under the `dingjiai` umbrella; Claude is one supported workflow, not the whole product identity.
- Current architecture discussions may use Claude CLI as the concrete example, but durable design decisions must remain reusable for future agents.

## Original intent and product motivation
- The core promise is near-zero-touch setup: copy one command, run it, answer only necessary guided Chinese prompts, and end with a usable Claude CLI environment.
- Prefer the shortest viable default baseline before expanding the bundle.
- Do not invent extra default tools, skills, settings, API keys, URLs, or user-specific values unless the user explicitly confirms them.
- User-facing installation flow should be Chinese-first, simple, direct, and non-technical.

## MAS-inspired product direction
- Learn from MAS principles: low-friction entry, copy-paste bootstrap commands, menu-driven interaction, simple wording, auditable scripts, and stable process handoff.
- MAS is a mechanism and UX reference, not a code source; keep implementation clean-room and MIT-compatible.
- Detailed MAS mapping, retry budgets, timeout tables, and hardening rationale belong in `notes/architecture/启动阶段（一次性）.md` and `notes/mas-analysis/deep-research-report.md`, not here.

## Primary product goals
- Minimize first-run friction.
- Make the first step obvious.
- Keep the install flow auditable.
- Keep the dependency chain explicit: detect, explain, install, verify.
- Preserve room for future support of agents beyond Claude.

## Non-goals
- Do not optimize first for advanced developers.
- Do not make `npx` the primary v1 entry path.
- Do not bind the architecture, naming, or repo identity to Claude alone.
- Do not depend on the main site runtime for installer delivery.
- Do not hide important machine changes behind silent behavior.

## Platform and distribution strategy
- v1 presents two top-level platform entry points only: Windows and macOS/Linux.
- Windows is the first implementation target.
- Installer delivery uses the dedicated install subdomain `get.dingjiai.com` and static GitHub Pages assets under `docs/`.
- Keep the public Windows bootstrap shape stable unless the user explicitly changes it:

```powershell
irm https://get.dingjiai.com/win.ps1 | iex
```

## Product UX rules
- The Windows user journey is: choose platform, copy one command, start from any supported shell, relaunch into dedicated administrator `cmd.exe`, see numbered menu, choose a task, get a clear result and next step.
- Menus should stay numbered, obvious, fixed, and beginner-friendly.
- The current Windows top-level menu is `1` 安装 Claude 和依赖, `2` 更新 Claude 和依赖, `3` 卸载 Claude 和依赖, `0` 退出.
- User-facing text should be simple, direct, non-technical, and Chinese-first.
- Do not ask users to opt into each confirmed baseline tool one by one; ship the default best-practice path directly.
- If a feature is placeholder-only, say so plainly.

## Architecture rules
- Keep the Windows architecture layered: remote bootstrap, relaunch controller, dedicated administrator `cmd.exe` main UI host, menu orchestrator, task/checkpoint executors, state/logs.
- The original shell is only the bootstrap host; all later Windows menu interaction and install work should stay inside the dedicated administrator `cmd.exe` window.
- The bootstrap should do only enough work to validate startup, retrieve verified payload files, and hand off to the dedicated main UI.
- Keep `handoffAccepted` semantically minimal: it means the administrator `cmd.exe` entered the verified local payload entry and accepted control of the main menu flow.
- Startup hard gates currently require Windows build 17763+ and PowerShell 5.1+.
- Startup failures should use the unified shape: reason, suggested next action, and local log path when available.
- Menu code controls flow only; dependency logic belongs in flow/checkpoint helpers.
- Windows menu flows live under `docs/installer/windows/payload/flows/windows/`; shared Windows helpers live under `docs/installer/windows/payload/lib/windows/`; task shims under `tasks/*.cmd` must stay thin.
- Core dependency checkpoints use the same model: discovery, allowance/decision, action, new-shell validation, optional component configuration, and final re-validation.
- Each component must settle its own PATH, active version, scope, and health state before the next component begins.
- For core dependency tools, prefer one project-approved best-practice path with minimal branching and project-defined trust checks.
- The current install order is: `winget`, App Installer download staging, Git, Claude, default enhancement layer, Claude product configuration, final validation.

## Admin and safety rules
- If a task changes machine-wide state, make that obvious to the user.
- Do not make hidden, surprising, or hard-to-reverse system changes.
- Do not split the user across multiple long-lived interactive shells after the dedicated main UI is open.

## Open-source and auditability rules
- Treat this repo as public open-source from the start.
- Keep scripts readable enough for public review.
- Avoid unnecessary indirection, magic behavior, and private-only assumptions.
- Do not hardcode secrets, personal paths, or private infrastructure into committed files.
- Keep the repository structure and published assets MIT-compatible.

## Tool usage rules
- When reading non-PDF files with the Read tool, never pass the pages parameter; pages is only for PDFs, and an empty pages value causes tool errors.

## Script and implementation style
- Prefer simple, top-to-bottom, auditable scripts.
- Do not over-abstract early; three explicit lines are better than a premature framework.
- Keep bootstrap scripts small and stable.
- Preserve honest placeholders rather than fake implementation.
- Build incrementally, but harden each completed layer before moving on.

## Naming rules
- Keep the primary identity general-purpose under `dingjiai`.
- Do not rename the whole project around Claude.
- Future support for other agents should fit naturally without renaming the repo.

## Current repository interpretation
- The old local shell prototype is not the current baseline.
- Current architecture source documents are indexed in Project document index above.
- `docs/` is the GitHub Pages publishing root for runnable installer assets; design Markdown belongs under `notes/`.
- Windows menu business skeletons live under `docs/installer/windows/payload/flows/windows/`, with shared helpers under `docs/installer/windows/payload/lib/windows/`.
- The current implemented business samples are `winget`, Git, and App Installer download-only staging; all are sample/report-only or download-only contracts, not full install logic.

## Current stage rule
- The repository is in a Windows startup and checkpoint-sample hardening stage.
- The first-stage implementation baseline is the MAS-inspired `manifest + payload + administrator cmd.exe handoff` startup path described in `notes/architecture/启动阶段（一次性）.md`.
- `winget` and Git checkpoints currently perform discovery/diagnosis/decision output only and must not install, repair, modify PATH, edit registry, or write user configuration.
- The App Installer download checkpoint is download-only staging: it defaults to planned/no-download, confines downloads/results to the user-local installer root, bounds retry/timeout inputs, cleans or invalidates hash-mismatched partial files, and must not execute, install, unpack, edit PATH, edit registry, or write user configuration.
- Claude, enhancement, update, and uninstall checkpoint actions remain placeholders.
- Run `docs/installer/windows/check-startup.ps1` after changing Windows startup payload files, `manifest.json`, runtime gates, helper contracts, or failure-output contracts.

## Claude CLI baseline documentation rule
- `notes/claude-cli-baseline.md` tracks the confirmed must-install baseline for the Claude CLI path.
- For now, follow Anthropic's official native Windows requirements for the shortest Claude CLI path.
- Git for Windows is part of the current native Windows baseline.
- Node.js is not part of the official native installer baseline; it is only required for the npm install method.
- Current default enhancement layer: `gh`, `rg`, Python, `pip`, Playwright, `jq`, `bat`, `7z`.
- Current optional enhancement layer: `duf`, `doggo`, `btop4win`, `pandoc`.
- Add extra required baseline items only after explicit user confirmation.

## Documentation maintenance rules
- When the product positioning changes, update this file.
- Any project fact, rule, decision, constraint, or direction explicitly confirmed by the user should be written into this file if it is durable.
- For every future architecture, product, workflow, naming, distribution, or implementation-strategy decision, update the relevant project documentation immediately without waiting for the user to remind you.
- When a discussion is currently being developed in `notes/architecture/`, write the newly agreed decision into the matching topic document in that directory as part of the same turn or same change.
- If no matching topic document exists yet under `notes/architecture/`, create or propose the appropriate document before continuing the design thread.
- Treat user-confirmed decisions as the source of truth for future maintenance unless the user later changes them.
- Keep documented project reality aligned with the current agreed reality.
- If the user confirms something and the docs are now out of sync, update the docs rather than leaving the mismatch for later.
- When the user-facing entry command, menu structure, hosting layout, or core workflow changes, update `README.md`.
- `CLAUDE.md` is a working contract and project document index, not a history or design archive; keep it focused on durable rules, current source-of-truth pointers, and guidance that changes how agents should work in this repository.
- Put implementation details, historical reasoning, rejected alternatives, long file lists, retry tables, and phase-by-phase discussion into `notes/*.md` instead of expanding this file.
- When adding, moving, or retiring a core project document, update the Project document index in this file in the same change.
- When deeper rationale is needed, record it in `notes/*.md`, but keep only the short durable rule in this file.
- Keep `docs/` free of design Markdown; use it only for publishable installer assets such as bootstrap scripts, manifests, payloads, and self-checks.
- When the broader helper-tool list or the current local tool status snapshot changes, update `notes/tool-inventory.md`.
- For tracked helper tools, record the exact package identity in `notes/tool-inventory.md` and do not substitute similarly named packages without explicit user confirmation.
- Once a default tool is selected for a capability, remove unchosen alternatives from `notes/tool-inventory.md` instead of keeping them as pending reminders.
- If `README.md`, notes, architecture discussion documents, and implementation drift apart, this file should be used to reconcile direction.

## Decision filter for future changes
Before making a structural change, ask whether it:
1. lowers the barrier for non-technical users
2. preserves the general-purpose agent-installer positioning
3. keeps distribution easy to copy, run, and inspect
4. avoids unnecessary admin requirements
5. stays compatible with open-source public maintenance
6. keeps room for Windows-first reality and later cross-platform growth

If a change fails most of these checks, do not make it by default.

# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Scope
- Scope: this repository root `D:\顶级AI\项目\npm包`.
- This file is the authoritative project guide for this repo.
- If a durable product, architecture, naming, or distribution decision changes, update this file in the same change.
- `README.md` is for end users. `notes/*.md` are supporting design notes. This file records durable working rules.
- When doing any work in this repository, follow this `CLAUDE.md` as a mandatory operating contract.
- If this document conflicts with a user request, observed project state, or other guidance, stop and ask the user before acting.

## Project positioning
- This repository is an open-source, beginner-friendly installer and launcher.
- The target audience is beginners and non-programmers, not just developers.
- The product should help users install Claude CLI, other agents, prerequisites, and commonly needed tools.
- The project must stay general-purpose. Do not position it as a Claude-only product.
- Claude can be a task or module inside the product, but not the entire product identity.
- Current architecture discussions may use Claude CLI as the concrete example, but durable design decisions should remain reusable for future agents.

## Original intent and product motivation
- The core promise is near-zero-touch setup.
- After copying and running one command, the user should mostly just wait rather than make technical decisions.
- The installer should prepare a complete usable Claude CLI environment, not only install the CLI binary.
- The default finished state should include prerequisites, Claude CLI, common tools, common capabilities, and selected high-value skills or configuration.
- Baseline best-practice components should be installed by default without asking the user for per-tool confirmation.
- This baseline can include tools and capabilities such as `gr`, browser capability, and other components that are part of the agreed standard experience.
- The installation mode should default to full automatic setup rather than semi-automatic or minimal setup.
- During setup, the installer should collect only necessary user-specific information through a guided Chinese dialog.
- URL and API key should be entered by the user rather than hardcoded or guessed.
- After the user enters them, the installer should write these values into the `env` section of `settings.json` automatically.
- Recommended defaults should be written directly into `claude.json` or `settings.json` when appropriate.
- User-facing installation flow should be Chinese-first.
- The target outcome is that a beginner can finish setup in about 5 minutes and then directly use `claude` inside their own project.
- Success is defined as "Claude ready" rather than merely "installer finished".
- For early architecture and documentation, define the default install baseline by the shortest viable path first.
- If a component is not yet confirmed as part of the default baseline, leave it blank for now rather than inventing a larger bundle too early.
- Example: `git` is clearly part of the baseline; some skills can remain unspecified until later iterations.

## MAS-inspired product direction
- Architecture and UX should learn from `massgravel/Microsoft-Activation-Scripts`.
- Borrow the successful principles, not the branding or code:
  - extremely low-friction entry
  - copy-paste-friendly bootstrap commands
  - menu-driven interaction after launch
  - simple wording for non-technical users
  - obvious, inspectable script flow
  - strong open-source readability and shareability
- Windows startup-stage compatibility handling should follow MAS-inspired mechanisms as the default reference model: normalize the host first, converge to the correct process shape, elevate through a controlled handoff, use explicit re-entry markers, and avoid inventing alternate startup mechanisms unless MAS's approach is clearly incompatible with this project's installer purpose.
- The startup-stage direction is now settled: continue by decomposing MAS's mature mechanisms and mapping them onto this project's `payload + administrator cmd.exe main window` architecture rather than designing a separate startup system.
- Startup-stage design should now be closed around MAS alignment rather than expanded with new mechanisms: use field ownership matrices, an explicit startup state machine, fixed retry/timeout/budget tables, and a MAS hardening checklist to keep the flow straight-line, deterministic, and auditable.
- Startup-stage retry and timeout values are v1 initial constants, not open-ended ranges: host normalization 1, bitness convergence 1, PowerShell runtime health retry 0, workspace creation retry 1, manifest download retry 2, payload file download retry 2, payload repair rebuild 1, hash mismatch retry 0, UAC handoff attempt 1, workspace preparation 10s, manifest request timeout 15s, payload file request timeout 30s, `handoffAccepted` wait 30s, and total startup budget 180s. These values may be tuned after large-scale post-launch testing.
- Keep `handoffAccepted` semantically minimal: it only means the new administrator `cmd.exe` has entered the verified local payload entry and accepted control of the main menu flow.
- MAS startup hardening for this project should cover environment baseline convergence, PowerShell runtime health gates, terminal compatibility policy, system architecture matrix, and entry landing-shape hardening.
- Windows startup hard gates currently require Windows build 17763+ and PowerShell 5.1+ before workspace, manifest, payload, or handoff work continues.
- Startup failures should use the unified user-facing failure shape: reason, suggested next action, and local log path when available.
- MAS is a mechanism and product-flow reference, not a code source. Keep the implementation clean-room and MIT-compatible; do not copy or derive GPL-3.0 MAS code.
- When choosing between a technically elegant flow and a simpler beginner-friendly flow, prefer the beginner-friendly flow unless the user says otherwise.

## Primary product goals
- Minimize first-run friction.
- Make the first step obvious.
- Keep the install flow auditable.
- Keep the dependency chain explicit: detect, explain, install, verify.
- Make the repo understandable to a stranger browsing the public source.
- Preserve room for future support of agents beyond Claude.

## Non-goals
- Do not optimize first for advanced developers.
- Do not make `npx` the primary v1 entry path.
- Do not bind the architecture, naming, or repo identity to Claude alone.
- Do not depend on the main site runtime for installer delivery.
- Do not hide important machine changes behind silent behavior.

## Platform and distribution strategy
- v1 should present two top-level platform entry points only:
  - Windows
  - macOS / Linux
- Windows is the first implementation target.
- PowerShell is the primary Windows implementation environment.
- Remote installer delivery should use the dedicated install subdomain `get.dingjiai.com`.
- Installer hosting should stay independent from the main tutorial or marketing site.
- Static bootstrap and payload files should be compatible with GitHub Pages hosting under `docs/`.
- The current public Windows bootstrap shape is:

```powershell
irm https://get.dingjiai.com/win.ps1 | iex
```

## Product UX rules
- The ideal user journey is:
  1. choose platform
  2. copy one command
  3. start from any supported shell entry
  4. automatically relaunch into the dedicated Windows main UI window
  5. see a numbered menu
  6. choose a task
  7. get a clear result and next step
- Menus should stay numbered and obvious.
- The administrator `cmd.exe` main UI should use a MAS-inspired fixed-size, centered panel style: stable title, clear separators, simple numbered choices, and constrained keyboard input.
- For Windows, the real main UI should not depend on whichever shell the user happened to use first.
- Windows Terminal, PowerShell 5.1, PowerShell 7, and other entry shells are just bootstrap hosts.
- The actual Windows installer UI and all later install interactions should run inside a newly opened dedicated administrator `cmd.exe` window.
- The default Windows path should not keep the user inside the original entry shell for the real menu and install flow.
- The bootstrap stage should do only the minimum work needed to hand off into that dedicated Windows main UI window.
- The top-level menu is shown after that handoff completes.
- The current v1 top-level menu is:
  - `1` 安装 Claude 和依赖
  - `2` 更新 Claude 和依赖
  - `3` 卸载 Claude 和依赖
  - `0` 退出
- Back, return, and exit behavior should be explicit.
- After a task completes, returning to the main menu is the default unless there is a good reason not to.
- User-facing text should be simple, direct, and non-technical.
- User-facing installation flow should default to Chinese.
- The default path should minimize questions and decisions.
- Do not ask the user to opt into each baseline recommended tool one by one when it is part of the agreed default experience.
- For beginner-first flows, do not over-explain why each best-practice tool is included; ship the default best-practice path directly.
- For core dependency tools, prefer one best-practice path with minimal branching.
- Core dependency handling should use project-defined trust checks such as minimum allowed version, official identity fields, and active command resolution rather than open-ended source analysis.
- If an existing tool instance does not meet the trusted standard, the installer should automatically converge to the project-approved version and make that version the active one for later steps.
- Keeping an old version is acceptable if it does not remain the active version for the installer path.
- If a feature is placeholder-only, say so plainly. Never imply unfinished flows are real.

## Architecture rules
- Keep the Windows architecture layered.
- Preferred layers:
  1. remote bootstrap
  2. relaunch controller
  3. dedicated Windows main UI host
  4. menu orchestrator
  5. task executors
  6. state and logs
- The remote bootstrap should stay thin.
- Heavy logic should live in local payloads, not the one-line bootstrap entry.
- For Windows, prefer one stable interaction host: a newly opened dedicated administrator `cmd.exe` window.
- The entry shell should not be treated as the durable UI host for the real Windows install flow.
- The bootstrap should perform only the minimum checks needed to open and hand off into that dedicated administrator `cmd.exe` window.
- Once the dedicated Windows main UI window is open, all later menu interaction, dependency handling, downloads, installs, updates, uninstalls, and validation should stay inside that window.
- Prefer capability-based detection over edition-based branching.
- Check real conditions such as admin rights, 64-bit process, PowerShell version, network reachability, filesystem write access, PATH update feasibility, and dependency presence.
- The menu layer should control flow only, not contain heavy installation logic.
- Core dependency checkpoints should use a consistent structure: discovery, allowance, action, new-shell validation, component configuration if needed, and final re-validation.
- Each core dependency checkpoint should finish its own PATH, active-version, scope, and health-state收尾 before the next component begins.
- Component-level optional configuration belongs to that component's own checkpoint, not to the later Claude product configuration stage.
- The current install path should treat `winget` as the default base installer capability and clear that checkpoint before Git and later tools.
- If `winget` is missing or unhealthy, the installer should resolve the `winget` checkpoint before any later install checkpoint continues.
- The current intended install order for `1` 安装 Claude 和依赖 is:
  - `winget` checkpoint
  - Git checkpoint
  - Claude checkpoint
  - default enhancement layer checkpoints
  - Claude product configuration
  - final end-to-end validation
- Core install actions should currently prefer one `winget`-based path for Git, Claude, and the default enhancement tools unless the user later confirms a different unique solution.
- Git should currently use the project placeholder trust fields in `notes/claude-cli-baseline.md` until evidence-backed values replace them.
- Git discovery should currently keep all planned fields as required inputs before any simplification.
- Git install and upgrade actions should currently assume one best-practice path through `winget` package `Git.Git`.
- Concrete work should be split into task-like executors such as doctor, dependency installs, repair, and uninstall.
- Task executors should be idempotent whenever practical.

## Admin and safety rules
- For Windows, the agreed default is now to relaunch the real main UI into a dedicated administrator `cmd.exe` window rather than staying in the original non-admin shell.
- Do not split the user across multiple long-lived interactive shells once the dedicated main UI window is open.
- If a task changes machine-wide state, that should be obvious to the user.
- Do not make hidden, surprising, or hard-to-reverse system changes.

## Open-source and auditability rules
- Treat this repo as public open-source from the start.
- Keep scripts readable enough that users can inspect what they run.
- Avoid unnecessary indirection, magic behavior, or over-engineering.
- Favor explicit flow over clever abstractions.
- Do not introduce private-only assumptions into the main architecture.
- Do not hardcode secrets, personal paths, or private infrastructure into committed files.
- MIT licensing should remain compatible with repository structure and published assets.

## Tool usage rules
- When reading non-PDF files with the Read tool, never pass the pages parameter; pages is only for PDFs, and an empty pages value causes tool errors.

## Script and implementation style
- Prefer simple, top-to-bottom, auditable scripts.
- Do not over-abstract early.
- Three explicit lines are better than a premature framework.
- Keep bootstrap scripts small and stable.
- Keep shared definitions simple when they help multiple entry points.
- Prefer stable behavior over clever shortcuts.
- When the repo is still in prototype mode, preserve honest placeholders rather than fake implementation.
- Build this project incrementally, but each completed layer or module must be hardened before moving on. Do not rely on later rewrites to fix known weakness in already-written framework code.

## Naming rules
- The primary project identity should stay general-purpose.
- Do not rename the whole project around Claude.
- `dingjiai` is the umbrella identity; Claude is one supported workflow inside it.
- Future support for other agents should fit naturally without renaming the repo.

## Current repository interpretation
- The previous local shell prototype files have been removed and should not be treated as the current implementation baseline.
- `docs/新版架构讨论/整体架构.md` — current architecture discussion source for the rebuild.
- `docs/新版架构讨论/启动阶段（一次性）.md` — current startup-stage implementation source for the Windows rebuild.
- `docs/MAS分析报告/deep-research-report.md` — MAS analysis source material for clean-room mechanism study.
- `notes/windows-architecture.md` — supporting Windows architecture notes that must stay aligned with the new startup architecture.
- `notes/claude-cli-baseline.md` — tracks the official and confirmed must-install baseline for the Claude CLI path.
- `notes/tool-inventory.md` — tracks the broader tool inventory and the current local installed/not-installed snapshot.

## Current stage rule
- This repository is currently in a Windows startup rebuild stage after the old shell prototype cleanup.
- The current first-stage implementation baseline is the MAS-inspired `manifest + payload + administrator cmd.exe handoff` startup path described in `docs/新版架构讨论/启动阶段（一次性）.md`.
- The intended flow includes a real first-stage startup detection pass before entering the menu.
- That startup detection flow is still being stabilized and should not yet be treated as production-ready.
- The old menu option `1` winget/Git milestone implementation has been removed with the prototype files and should not be described as currently wired.
- Menu options `1`, `2`, and `3` currently exist in the administrator `cmd.exe` menu loop and route into split placeholder task executor scripts only; their real install, update, and uninstall actions are not wired yet.
- Do not describe unfinished flows as production-ready.
- Before wiring later install logic, keep architecture and user journey decisions aligned with this file and `docs/新版架构讨论/`.
- Do not add extra `settings.json` defaults beyond the currently confirmed items yet.
- The immediate goal is to rebuild the startup framework and publish the first working Windows version before expanding the bundle.
- Run `docs/installer/windows/check-startup.ps1` after changing Windows startup payload files, `manifest.json`, runtime gates, or failure-output contracts to catch hash drift and startup contract regressions.

## Claude CLI baseline documentation rule
- `notes/claude-cli-baseline.md` tracks the confirmed must-install baseline for the Claude CLI path.
- For now, the Claude CLI shortest path should follow Anthropic's official requirements rather than a project-expanded bundle.
- Add extra required items only after the user explicitly confirms them.
- For the current native Windows shortest path, Git for Windows is part of the official minimum baseline.
- Node.js is not part of the official minimum baseline for the recommended native installer path; it is only required for the npm install method.
- The current project-level default enhancement layer is:
  - `gh`
  - `rg`
  - Python
  - `pip`
  - Playwright
  - `jq`
  - `bat`
  - `7z`
- The current optional enhancement layer is:
  - `duf`
  - `doggo`
  - `btop4win`
  - `pandoc`
- This note should grow iteratively as more required baseline items are confirmed.

## Documentation maintenance rules
- When the product positioning changes, update this file.
- Any project fact, rule, decision, constraint, or direction explicitly confirmed by the user should be written into this file if it is durable.
- For every future architecture, product, workflow, naming, distribution, or implementation-strategy decision, update the relevant project documentation immediately without waiting for the user to remind you.
- When a discussion is currently being developed in `docs/新版架构讨论/`, write the newly agreed decision into the matching topic document in that directory as part of the same turn or same change.
- If no matching topic document exists yet under `docs/新版架构讨论/`, create or propose the appropriate document before continuing the design thread.
- Treat user-confirmed decisions as the source of truth for future maintenance unless the user later changes them.
- Keep documented project reality aligned with the current agreed reality.
- If the user confirms something and the docs are now out of sync, update the docs rather than leaving the mismatch for later.
- When the user-facing entry command, menu structure, hosting layout, or core workflow changes, update `README.md`.
- When deeper rationale is needed, record it in `notes/*.md`, but keep the durable rule in this file.
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

# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Scope
- Scope: this repository root `D:\顶级AI\项目\npm包`.
- This file is the authoritative project guide for this repo.
- If a durable product, architecture, naming, or distribution decision changes, update this file in the same change.
- `README.md` is for end users. `notes/*.md` are supporting design notes. This file records durable working rules.

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
  3. run initial basic environment detection
  4. see a numbered menu
  5. choose a task
  6. get a clear result and next step
- Menus should stay numbered and obvious.
- Before showing the top-level menu, the installer should first perform a basic environment check and decide whether relaunch is needed.
- This first stage is for understanding the current environment and preparing the next stage, not for rejecting imperfect environments by default.
- The first stage should print short Chinese-first line-by-line results before entering the top-level menu.
- The first stage should at minimum identify Windows environment, PowerShell version, process/OS bitness, privilege mode, user-scope write access, and basic network reachability.
- The first stage should produce a current-run environment profile that later task executors can reuse.
- The top-level menu is shown after that initial check completes.
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
  3. capability detector
  4. menu orchestrator
  5. task executors
  6. state and logs
- The remote bootstrap should stay thin.
- Heavy logic should live in local payloads, not the one-line bootstrap entry.
- Relaunch only when needed. Do not open a new terminal by default unless a constraint requires it.
- The startup detection phase should live in the local launcher before the menu, not in the thin bootstrap.
- Prefer capability-based detection over edition-based branching.
- Check real conditions such as admin rights, 64-bit process, PowerShell version, network reachability, filesystem write access, PATH update feasibility, and dependency presence.
- For the first startup stage, prefer result styles such as ready, auto-adapt, defer, and info instead of treating imperfect environments as default blockers.
- The menu layer should control flow only, not contain heavy installation logic.
- Core dependency checkpoints should use a consistent structure: discovery, allowance, action, new-shell validation, component configuration if needed, and final re-validation.
- Each core dependency checkpoint should finish its own PATH, active-version, scope, and health-state收尾 before the next component begins.
- Component-level optional configuration belongs to that component's own checkpoint, not to the later Claude product configuration stage.
- Concrete work should be split into task-like executors such as doctor, dependency installs, repair, and uninstall.
- Task executors should be idempotent whenever practical.

## Admin and safety rules
- Default to non-admin execution.
- Ask for elevation only when the selected task truly needs it.
- Do not request admin up front just because a later path might need it.
- Prefer user-scope installation when it provides a good user experience.
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

## Script and implementation style
- Prefer simple, top-to-bottom, auditable scripts.
- Do not over-abstract early.
- Three explicit lines are better than a premature framework.
- Keep bootstrap scripts small and stable.
- Keep shared definitions simple when they help multiple entry points.
- Prefer stable behavior over clever shortcuts.
- When the repo is still in prototype mode, preserve honest placeholders rather than fake implementation.

## Naming rules
- The primary project identity should stay general-purpose.
- Do not rename the whole project around Claude.
- `dingjiai` is the umbrella identity; Claude is one supported workflow inside it.
- Future support for other agents should fit naturally without renaming the repo.

## Current repository interpretation
- `win.ps1` — local Windows launcher
- `bootstrap/win.ps1` — local bootstrap-source version
- `docs/win.ps1` — published Windows bootstrap entry
- `docs/installer/windows/win.ps1` — published Windows launcher payload
- `docs/installer/windows/menu.txt` — published Windows menu payload
- `unix.sh` — local macOS/Linux launcher
- `menu.txt` — shared local menu definition
- `notes/windows-architecture.md` — supporting Windows architecture notes
- `notes/claude-cli-baseline.md` — tracks the official and confirmed must-install baseline for the Claude CLI path
- `notes/tool-inventory.md` — tracks the broader tool inventory and the current local installed/not-installed snapshot

## Current stage rule
- This repository is currently a shell prototype.
- The intended flow includes a real first-stage startup detection pass before entering the placeholder menu.
- That startup detection flow is still being stabilized and should not yet be treated as production-ready.
- Placeholder menu actions are still acceptable at this stage.
- Do not describe placeholder flows as production-ready.
- Before wiring real install logic, keep architecture and user journey decisions aligned with this file.
- Do not add extra `settings.json` defaults beyond the currently confirmed items yet.
- The immediate goal is to get the framework running and publish the first version before expanding the bundle.

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
- Treat user-confirmed decisions as the source of truth for future maintenance unless the user later changes them.
- Keep documented project reality aligned with the current agreed reality.
- If the user confirms something and the docs are now out of sync, update the docs rather than leaving the mismatch for later.
- When the user-facing entry command, menu structure, hosting layout, or core workflow changes, update `README.md`.
- When deeper rationale is needed, record it in `notes/*.md`, but keep the durable rule in this file.
- When the broader helper-tool list or the current local tool status snapshot changes, update `notes/tool-inventory.md`.
- For tracked helper tools, record the exact package identity in `notes/tool-inventory.md` and do not substitute similarly named packages without explicit user confirmation.
- Once a default tool is selected for a capability, remove unchosen alternatives from `notes/tool-inventory.md` instead of keeping them as pending reminders.
- If `README.md`, notes, and implementation drift apart, this file should be used to reconcile direction.

## Decision filter for future changes
Before making a structural change, ask whether it:
1. lowers the barrier for non-technical users
2. preserves the general-purpose agent-installer positioning
3. keeps distribution easy to copy, run, and inspect
4. avoids unnecessary admin requirements
5. stays compatible with open-source public maintenance
6. keeps room for Windows-first reality and later cross-platform growth

If a change fails most of these checks, do not make it by default.

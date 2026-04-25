# Windows installer architecture notes

This file records supporting architecture decisions for the Windows-first installer. The current rebuild source of truth is the newer architecture discussion under `notes/architecture/`, especially `notes/architecture/启动阶段（一次性）.md`.

## Project positioning

The project is a beginner-friendly installer for:

- prerequisites
- Claude CLI
- other agents

It should not be Claude-specific in naming or long-term architecture.

## Distribution strategy

Windows is the first target platform.

Public Windows entry:

```powershell
irm https://get.dingjiai.com/win.ps1 | iex
```

Hosting strategy:

- do not use the main site routes on `dingjiai.com`
- use a dedicated install subdomain: `get.dingjiai.com`
- host static bootstrap and payload files through GitHub Pages
- keep installer delivery independent from the main tutorial website and its server health

Current minimal v1 startup and placeholder business layout:

- `docs/win.ps1` — thin public Windows bootstrap entry
- `docs/installer/windows/manifest.json` — startup payload manifest
- `docs/installer/windows/payload/main.cmd` — administrator `cmd.exe` menu orchestrator
- `docs/installer/windows/payload/flows/windows/*/entry.cmd` — placeholder flow entries for install, update, and uninstall
- `docs/installer/windows/payload/flows/windows/*/checkpoints/*.cmd` — placeholder checkpoint slots for component work
- `docs/installer/windows/payload/lib/windows/*.cmd` — thin shared helper placeholders
- `docs/installer/windows/payload/tasks/*.cmd` — compatibility shims that forward to flow entries
- keep `docs/CNAME` for the dedicated install subdomain when GitHub Pages is configured
- keep design Markdown under `notes/`; `docs/` should stay a publishing root for runnable assets
- do not reuse the removed old prototype payload layout as the current baseline

## Layered Windows architecture

The Windows installer should be split into layers.

### 1. Remote bootstrap

The remote bootstrap is the thin entry downloaded by `irm ... | iex`.

Responsibilities:

- start in the user's current PowerShell session
- perform only the minimum bootstrap checks
- download or refresh local payload files
- relaunch into the dedicated Windows main UI host

The bootstrap should stay small and focused.
It is not the long-lived UI host.

### 2. Relaunch controller

For Windows, the installer should deliberately switch away from the original shell and into one stable interaction host.

The agreed Windows-first model is now:

- user may start from Windows Terminal, Windows PowerShell 5.1, PowerShell 7, or another supported shell
- the original shell is only the bootstrap host
- the real installer UI should always relaunch into a newly opened dedicated administrator `cmd.exe` window

Principle:

- prefer one stable dedicated main UI host over trying to preserve the original shell

### 3. Dedicated Windows main UI host

The dedicated Windows main UI host should be an administrator `cmd.exe` window.

Responsibilities:

- own the real numbered menu
- host all later user interaction
- run dependency checks and install tasks
- keep the user in one stable Windows console environment for the rest of the session

This is the MAS-inspired Windows interaction model now chosen for the project.

### 4. Menu orchestrator

The menu layer should control flow only.
It is entered only after the dedicated administrator `cmd.exe` window is open.

It should:

- show numbered options
- route the user into tasks
- return to the main menu after tasks finish
- support clear back/exit behavior

It should not contain heavy implementation logic.

### 5. Task executors

Concrete work should be split into task units such as:

- doctor
- install-node
- install-git
- install-claude
- install-agents
- repair-path
- uninstall

These tasks should be as idempotent as possible.

Running them multiple times should not corrupt the machine state.

For core dependencies, each component should follow one consistent checkpoint model:

1. discovery
2. allowance
3. action
4. new-shell validation
5. component configuration if needed
6. final new-shell re-validation

A component is not complete until its own PATH, active version, scope, and health state are fully settled.

Current intended checkpoint order for `安装 Claude 和依赖` is:

1. `winget` checkpoint
2. Git checkpoint
3. Claude checkpoint
4. default enhancement layer checkpoints
5. Claude product configuration
6. final end-to-end validation

`winget` is currently treated as the base installer capability for the whole install path.
If `winget` is missing or unhealthy, that checkpoint should be resolved before Git or Claude work begins.
The current first-stage implementation baseline is the startup handoff path: thin public bootstrap, local workspace, manifest-defined payload retrieval, staging-based payload verification, startup state recording, and administrator `cmd.exe` handoff with `handoffAccepted`. Dependency checkpoints should be rewired only after this startup path stays stable.

### 6. State and logs

Installer state should live in a user-local directory such as:

```text
%LOCALAPPDATA%\dingjiai-installer
```

Suggested contents:

- downloaded payload files
- local launcher files
- version metadata
- diagnostics results
- runtime logs

## Admin strategy

The agreed Windows-first strategy is now:

- start from any supported shell
- switch into a dedicated administrator `cmd.exe` window for the real installer UI
- keep all later interaction and install work inside that window

### Bootstrap host expectations

The original entry shell may be:

- Windows Terminal
- Windows PowerShell 5.1
- PowerShell 7
- other supported Windows shells later

The project should not depend on that original shell remaining the durable UI host.

### Dedicated main UI expectations

The dedicated administrator `cmd.exe` window should be treated as:

- the stable interaction host
- the place where the real menu appears
- the place where later install/download/validation work runs

User-facing principle:

- do not leave the user split across multiple long-lived interactive shells
- once the dedicated administrator `cmd.exe` window is open, keep the rest of the Windows flow there

## Dependency-chain focus

Unlike generic system scripts, this project is primarily a dependency installer.

For core dependency tools, the default path should prefer one best-practice solution with minimal branching.
The installer should not rely on open-ended source analysis for these tools.
Instead, it should compare the current tool state against project-defined trust checks such as:

- minimum allowed version
- official identity fields
- active command resolution in a new shell

If the current tool does not meet that trusted standard, the installer should automatically converge to the project-approved version and make it the active version for later steps.
Keeping an older or alternate version is acceptable only if it does not remain the active version for the installer path.

For current framework work:

- `winget` repair should first try the shortest source recovery path and escalate to reinstall if the checkpoint is still unhealthy.
- `winget` install and reinstall should share one App Installer payload path once that payload is connected.
- current App Installer payload metadata is intentionally minimal and should only track package name, identity, and version.
- Git discovery should currently keep all planned fields as required inputs.
- Git allowance should currently reduce to `skip`, `repair`, `upgrade`, `install`, or `reinstall` based on trusted identity, minimum version, and active command resolution.
- Git install and upgrade should currently assume the single `winget` package path through `Git.Git`.

The main Windows dependency chain is expected to include:

- `winget` as the base installer capability
- Git
- Claude CLI
- project default enhancement tools later

This means the most important architecture questions are now:

- how the bootstrap hands off into the dedicated administrator `cmd.exe` window
- how the menu and tasks are organized inside that window
- how dependency checkpoints remain explicit and auditable inside one stable Windows console host
- how to keep user-mode installation working for most users

## Placeholder-state rule

For the current rebuild stage of the project:

- the previous Windows launcher prototype has been removed
- the administrator `cmd.exe` payload now has a real numbered menu loop skeleton
- menu actions now route to placeholder flow entries, but are not currently wired to real install/update/uninstall logic
- real installation logic is not currently wired
- the next code milestone should rebuild startup first, before dependency checkpoints

Current planned actions remain:

- install Claude and dependencies
- update Claude and dependencies
- uninstall Claude and dependencies

## Current repository interpretation

At the current rebuild stage:

- the previous local Windows launcher and published prototype payload files have been removed
- `notes/architecture/整体架构.md` is the current architecture discussion source
- `notes/architecture/启动阶段（一次性）.md` is the current startup-stage implementation source
- the new `docs/` publishing layout should be defined by the manifest and payload implementation, not by the removed prototype files
- design Markdown has moved out of `docs/` and into `notes/`; `docs/` should stay focused on publishable installer assets

## Next architecture topics

Before implementing real installation logic, the next useful design discussions are:

1. bootstrap, manifest, and payload file layout
2. administrator `cmd.exe` handoff implementation
3. startup state and log retention policy
4. dependency installation priority and fallback strategy
5. update flow shape and scope
6. recovery and resume behavior after partial failure

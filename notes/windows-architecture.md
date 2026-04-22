# Windows installer architecture notes

This file records the current architecture decisions for the Windows-first installer.

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

Current GitHub Pages publishing layout:

- `docs/CNAME`
- `docs/win.ps1`
- `docs/installer/windows/win.ps1`
- `docs/installer/windows/menu.txt`

## Layered Windows architecture

The Windows installer should be split into layers.

### 1. Remote bootstrap

The remote bootstrap is the thin entry downloaded by `irm ... | iex`.

Responsibilities:

- start in the user's current PowerShell session
- detect environment facts
- decide whether a controlled relaunch is needed
- download or refresh local payload files
- start the local launcher

The bootstrap should stay small and focused.

### 2. Relaunch controller

The installer should not always open a new terminal window.

Instead, it should relaunch only when needed, for example:

- elevation is required
- a 64-bit PowerShell process is required
- the current shell is unsuitable for stable interaction
- a controlled execution environment is needed

Principle:

- relaunch on demand, not by default

### 3. Capability detector

The installer should prefer capability-based detection over edition-based branching.

Do not primarily branch on labels like:

- Windows 10 vs 11
- Home vs Pro vs Enterprise
- LTSC vs non-LTSC

Instead, detect real capabilities and constraints:

- admin rights
- 64-bit OS and 64-bit process
- PowerShell version
- Windows build
- interactive terminal availability
- network/TLS reachability
- filesystem write access
- PATH update feasibility
- presence of Node.js
- presence of Git
- presence of npm
- presence of Claude CLI

For the first startup stage, prioritize basic environment identification that helps the next stage choose how to proceed.
Do not treat every imperfect condition as a blocker by default.
The current implemented startup stage focuses on Windows environment, PowerShell, process bitness, privilege mode, user-scope write access, and basic network reachability before entering the menu.

### 4. Menu orchestrator

The menu layer should control flow only.
It is entered after the initial capability detection and any needed relaunch are complete.
The first startup stage should produce a simple environment profile that later task executors can reuse inside the same run.

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

The agreed strategy is:

- default to non-admin execution
- elevate only when a chosen task truly requires it

### Never require admin

These should stay non-admin whenever possible:

- environment detection
- downloading payload files
- reading machine information
- user-scope installation
- checking Node/Git/npm/Claude presence
- updating user-level PATH

### Admin optional

These may optionally use admin depending on the mode:

- machine-wide dependency installation
- system-wide PATH updates
- all-users installation mode

### Admin required

These should be treated as elevated operations:

- writing to `HKLM`
- writing to `Program Files`
- machine-level environment variable updates
- machine-wide installers that require elevation

User-facing principle:

- do not ask for admin up front
- ask only when the selected task needs it
- clearly label menu items with permission expectations when useful

## Dependency-chain focus

Unlike generic system scripts, this project is primarily a dependency installer.

The main Windows dependency chain is expected to include:

- Git
- Node.js
- npm
- Claude CLI
- optional agent packages later

This means the most important architecture questions are not edition detection but:

- how to detect missing dependencies
- how to install them reliably
- how to recover when one step fails
- how to keep user-mode installation working for most users

## Placeholder-state rule

For the current stage of the project:

- the Windows launcher remains placeholder-based
- menu actions should show placeholder text only
- real installation logic is not yet wired in

Current placeholder actions are:

- install Claude and dependencies
- update Claude and dependencies
- uninstall Claude and dependencies

## Current repository interpretation

At the time of writing:

- `win.ps1` is the local Windows launcher
- `bootstrap/win.ps1` is the local bootstrap-source version
- `docs/win.ps1` is the published GitHub Pages bootstrap entry
- `docs/installer/windows/win.ps1` is the published Windows launcher payload
- `docs/installer/windows/menu.txt` is the published Windows menu payload

## Next architecture topics

Before implementing real installation logic, the next useful design discussions are:

1. dependency installation priority and fallback strategy
2. update flow shape and scope
3. relaunch conditions for controlled PowerShell sessions
4. recovery and resume behavior after partial failure

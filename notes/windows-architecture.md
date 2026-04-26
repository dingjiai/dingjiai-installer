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
- `docs/installer/windows/payload/flows/windows/*/checkpoints/*.cmd` — checkpoint slots for component work; most are still placeholders
- `docs/installer/windows/payload/flows/windows/install/checkpoints/10_winget.cmd` — first read-only `winget` checkpoint sample
- `docs/installer/windows/payload/flows/windows/install/checkpoints/15_app_installer_download.cmd` — first download-only App Installer staging sample
- `docs/installer/windows/payload/flows/windows/install/checkpoints/20_git.cmd` — first read-only Git checkpoint sample
- `docs/installer/windows/payload/lib/windows/*.cmd` — thin shared helper placeholders
- `docs/installer/windows/payload/lib/windows/winget.ps1` — first PowerShell business helper for `winget` discovery, diagnosis, and decision output
- `docs/installer/windows/payload/lib/windows/download.ps1` — PowerShell helper for download-only staging with explicit source and hash gates
- `docs/installer/windows/payload/lib/windows/git.ps1` — PowerShell business helper for Git discovery, placeholder trust diagnosis, and decision output
- `docs/installer/windows/payload/tasks/*.cmd` — compatibility shims that forward to flow entries
- keep `docs/CNAME` for the dedicated install subdomain when GitHub Pages is configured
- keep design Markdown under `notes/`; `docs/` should stay a publishing root for runnable assets
- do not reuse the removed old prototype payload layout as the current baseline

## Checkpoint v1 contract and flow gates

Current Windows checkpoint samples use a shared `checkpoint.v1` result envelope. Tool-specific details may live in their own child blocks, but the top-level shape should stay stable so later tools can reuse the same runner and self-checks.

Required top-level fields for checkpoint helpers:

- `contractVersion`: currently `checkpoint.v1`
- `component`
- `flow`
- `checkpoint`
- `mutationAllowed`
- `sampleMode`
- `actionMode`
- `outputMode`
- `testScenario`
- `exitCodeContract`
- a tool-specific discovery/state block such as `discovery`, `source`, or `download`
- `decision`

Required `decision` fields:

- `status`
- `decision`
- `reason`
- `nextAction`
- `exitCode`

Current exit code contract:

- `0`: checkpoint produced a valid report/decision and the flow may continue.
- `11`: checkpoint is explicitly not implemented.
- `20`: cmd bridge/helper file is missing.
- `60`: business/dependency condition blocks progress, such as download, hash failure, or a non-healthy report-only dependency checkpoint.
- `70`: helper/runtime/contract failure.

Flow entries should stay simple: call checkpoints in order and immediately return any non-zero `errorlevel`. Placeholder checkpoints must fail closed with `NOT_IMPLEMENTED` and `exit /b 11`; they must not return success or make a flow look complete.

`docs/installer/windows/payload/lib/windows/checkpoint_runner.cmd` is the shared CMD-to-PowerShell bridge for implemented checkpoint samples. It reads `DINGJIAI_CHECKPOINT_HELPER`, `DINGJIAI_CHECKPOINT_FLOW`, and `DINGJIAI_CHECKPOINT_NAME`, verifies the helper exists, invokes the helper with the fixed `-FlowName` and `-CheckpointName`, forwards remaining arguments unchanged, and propagates the helper exit code. The runner should stay thin; discovery, decision, download, install, repair, and validation logic belongs in the PowerShell checkpoint helper.

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
2. App Installer download-only staging checkpoint for the future `winget` install/reinstall path
3. Git checkpoint
4. Claude checkpoint
5. default enhancement layer checkpoints
6. Claude product configuration
7. final end-to-end validation

`winget` is currently treated as the base installer capability for the whole install path.
If `winget` is missing or unhealthy, that checkpoint should be resolved before Git or Claude work begins.
The first `winget` implementation is intentionally a read-only sample and the current checkpoint contract reference: `10_winget.cmd` only bridges into `lib/windows/winget.ps1`, and the helper only performs discovery, diagnosis, and decision output. It does not install, repair, reset/add/update sources, reconfigure PATH, edit registry, write user configuration, or otherwise mutate machine state. Its result shape is locked as `checkpoint.v1` with `mutationAllowed`, `sampleMode = discovery-diagnose-decision-only`, `actionMode = report-only`, `exitCodeContract`, structured `discovery`, `diagnosis`, `decision`, `action`, `validation`, and `audit` sections. Structured discovery records environment facts, command resolution, version probe, source probe, official-source trust facts, and read-only Appx deployment repair facts for future App Installer recovery. `winget source list` must confirm the official `winget` source URL `https://cdn.winget.microsoft.com/cache` before the checkpoint is considered healthy. Statuses are intentionally specific: `healthy`, `missing`, `appx_deployment_unavailable`, `command_broken`, `command_timeout`, `source_broken`, `source_timeout`, `source_missing`, `source_untrusted`, and `helper_failed`; decisions remain `skip`, `install`, `repair`, or `abort`. If `winget.exe` is missing, the helper uses read-only Appx deployment facts to distinguish a future App Installer repair path from a fail-closed `appx_deployment_unavailable` abort. Healthy reports return `0`; non-healthy dependency states return `60`; helper/runtime failures return `70`. Optional `-ResultPath` JSON output is confined under `%LOCALAPPDATA%\dingjiai-installer` (or the helper's local fallback root) and bad paths become `helper_failed` without writing outside that root. Deterministic `-TestScenario` inputs cover healthy, missing, version failure/timeout, source failure/timeout, missing source, untrusted source, and helper failure, and the helper self-validates scenario expectations before output through `Get-TestScenarioExpectation` and `Test-TestScenarioContract`. The CMD checkpoint bridge forwards helper arguments, so these contracts can be tested through the same bridge used by the install flow.
The first Git implementation is also intentionally a read-only sample: `20_git.cmd` only bridges into `lib/windows/git.ps1`, and the helper only performs discovery, placeholder trust diagnosis, and decision output. It does not install, repair, upgrade, reinstall, reconfigure PATH, edit registry, or mutate machine state yet. Current Git trust checks use the placeholder fields in `notes/claude-cli-baseline.md`; non-healthy Git states return `60` while the helper remains report-only: minimum version `2.40.0`, Git for Windows version marker `windows.`, trusted active path shapes, and package identity `Git.Git`. Its probe commands are timeout-bounded, stdout/stderr are read asynchronously, timeout state is reported, deterministic `-TestScenario` inputs cover healthy and broken paths, non-healthy dependency states return `60`, and `-OutputMode Json` plus optional `-ResultPath` provide the same machine-readable report shape as the `winget` sample.
The first download implementation is intentionally a download-only staging sample: `15_app_installer_download.cmd` bridges into `lib/windows/download.ps1` for the App Installer artifact and defaults to planned/no-download output. Real download requires explicit `-AllowDownload`, complete source metadata, HTTPS, an allowed host list, and an expected SHA-256; incomplete App Installer metadata remains `source_blocked` and must not start a download. The helper downloads only under `%LOCALAPPDATA%\dingjiai-installer\downloads\staging` through a `.part` file, verifies hash before promotion, and does not execute installers, unpack to system locations, edit PATH, edit registry, or write user configuration. Hash mismatches must delete the partial file or report cleanup failure, optional result files must stay under `%LOCALAPPDATA%\dingjiai-installer`, and retry/timeout inputs are bounded (`RetryCount` 0-5, `TimeoutSeconds` 5-120). Its exit code contract is: planned/downloaded success returns `0`; download boundary failures return `60`; helper/runtime failures return `70`.
The current first-stage implementation baseline is the startup handoff path: thin public bootstrap, local workspace, manifest-defined payload retrieval, staging-based payload verification, startup state recording, and administrator `cmd.exe` handoff with `handoffAccepted`. Dependency checkpoint actions should be wired only after their sample contracts stay stable.

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

- The current `winget` sample reports status and decision only; action decisions such as `install` or `repair` are not executed yet. It may inspect Appx deployment repair facts, but it does not download App Installer dependencies or call `Add-AppxPackage`. It is the current checkpoint contract reference: status/decision enums, structured discovery, deterministic scenarios, exit codes, result path containment, and report-only mutation boundaries are locked in the helper and covered by `docs/installer/windows/check-startup.ps1`.
- `winget` repair should first try the shortest source recovery path and escalate to reinstall if the checkpoint is still unhealthy.
- `winget` install and reinstall should share one App Installer payload path once that payload is connected.
- current App Installer payload metadata is intentionally minimal and should only track package name, identity, version, approved download host, and expected SHA-256 when real download is enabled.
- current download helper behavior is download-only staging: no `-AllowDownload` means planned/no-download output with incomplete metadata reported explicitly; explicit real download must have complete metadata, be HTTPS, host-allowlisted, hash-locked, confined under `%LOCALAPPDATA%\dingjiai-installer\downloads\staging`, staged as `.part`, and hash-verified before promotion. Hash mismatch cleanup, result path containment under `%LOCALAPPDATA%\dingjiai-installer`, and bounded retry/timeout inputs are part of the helper contract.
- Git discovery should currently keep all planned fields as required inputs.
- Git allowance should currently reduce to `skip`, `repair`, `upgrade`, `install`, or `reinstall` based on trusted identity, minimum version, and active command resolution.
- Git install and upgrade should currently assume the single `winget` package path through `Git.Git`.
- The current Git sample reports status and decision only; action decisions such as `install`, `repair`, `upgrade`, or `reinstall` are not executed yet. Its status, decision enums, and non-healthy exit code `60` gate are locked in the helper and validated before output.

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
- menu actions now route to flow entries; most checkpoints are placeholders
- the install flow has a read-only `winget` checkpoint sample for discovery, diagnosis, and decision output
- the install flow has a download-only App Installer staging sample that defaults to planned/no-download output
- real install/update/uninstall mutation logic is not currently wired
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

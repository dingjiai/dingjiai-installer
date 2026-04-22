# Claude CLI baseline notes

This file tracks the shortest-path required baseline for the Claude CLI installation path.

It is intentionally small for now. Add more required items later only after they are explicitly confirmed.

## Current rule

- For now, use Anthropic official requirements as the source of truth for the Claude CLI minimum baseline.
- Because this repository is currently Windows-first, define the baseline primarily around the native Windows path.
- Do not expand the must-install list just because a tool is commonly useful.
- Expand the list only after the project explicitly confirms that an item belongs in the default baseline.
- For core dependency tools, later implementation should define explicit minimum allowed versions and official identity fields before automating upgrade or convergence logic.

## Current official minimum baseline for native Windows

- Windows 10 1809+ or Windows Server 2019+
- x64 or ARM64 processor
- 4 GB+ RAM
- internet connection
- PowerShell or CMD shell
- supported Claude access:
  - Claude Pro, Max, Team, or Enterprise
  - Claude Console
  - or a supported cloud provider
- Git for Windows

## Current project-level default enhancement layer

These items are not part of Anthropic's official minimum baseline, but are currently confirmed as the project-level default enhancement layer for the Windows-first Claude path.

- `gh`
- `rg`
- Python
- `pip`
- Playwright
- `jq`
- `bat`
- `7z`

## Current optional enhancement layer

These items are useful, but are currently treated as optional enhancements rather than part of the project default install layer.

- `duf`
- `doggo`
- `btop4win`
- `pandoc`

## Not currently part of the official minimum baseline

- Node.js
  - Node.js 18+ is required only for the npm install method
  - Node.js is not required for the recommended native installer path
- additional skills
- extra helper tools beyond the official baseline

## Core dependency identity placeholders for framework work

The values in this section are temporary placeholders for framework development only.
They are not the final documented standards and must be replaced with evidence-backed values before shipping production logic.

### Git temporary placeholder identity fields

- TEMP_PLACEHOLDER_FOR_FRAMEWORK
- minimum allowed version: `2.40.0`
- official product name: `Git for Windows`
- official publisher / signer: `The Git Development Community`
- official package identity: `Git.Git`
- expected version string marker: `windows.`
- trusted path shapes:
  - `C:\Program Files\Git\cmd\git.exe`
  - `C:\Program Files\Git\bin\git.exe`
  - `C:\Program Files\Git\mingw64\bin\git.exe`
  - `C:\Users\<user>\AppData\Local\Programs\Git\cmd\git.exe`
  - `C:\Users\<user>\AppData\Local\Programs\Git\bin\git.exe`
  - `C:\Users\<user>\AppData\Local\Programs\Git\mingw64\bin\git.exe`
- current placeholder identity match rule:
  - `versionMarkerMatched = yes`
  - `pathShapeMatched = yes`
  - `productNameMatched = yes`
  - then treat `officialIdentityMatched`, `publisherMatched`, and `packageIdentityMatched` as matched for current framework work
- current discovery rule:
  - all planned Git discovery fields are currently required inputs
- current allowance buckets:
  - `skip`
  - `repair`
  - `upgrade`
  - `install`
  - `reinstall`
- current framework action path:
  - install through `winget install --id Git.Git`
  - upgrade through `winget upgrade` for the same package
  - keep older Git copies only if they do not remain the active installer-path version
- current implemented framework behavior:
  - collect all planned Git discovery fields in the launcher
  - treat `cmd`, `bin`, and `mingw64\\bin` Git executables under the documented Git for Windows roots as trusted path shapes for the current placeholder rules
  - use a new PowerShell shell check for active command path and version output before declaring the Git checkpoint healthy
  - reduce Git allowance to `skip`, `repair`, `upgrade`, `install`, or `reinstall` before action selection
  - build a concrete winget action plan before execution so `install`, `upgrade`, and `repair` can choose user or machine scope from the currently active Git path

## Broader tool inventory tracking

- `notes/tool-inventory.md` tracks the broader helper-tool list and the current local installed/not-installed snapshot.
- Inclusion in that note does not automatically make an item part of the official minimum baseline.

## Current official install path to mirror first

```powershell
irm https://claude.ai/install.ps1 | iex
```

## Iteration rule

- Keep the first baseline official-first and shortest-path.
- Add new must-install items only after explicit confirmation.
- Do not add extra `settings.json` content beyond the currently confirmed items yet.
- The immediate goal is to get the framework running and ship the first version before expanding the bundle.
- When the baseline grows, append new required items here instead of replacing the history in chat.

## Sources

- Claude Code docs — Advanced setup: https://code.claude.com/docs/en/setup.md
- Claude Code docs — Quickstart: https://code.claude.com/docs/en/quickstart.md

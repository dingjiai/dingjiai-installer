# dingjiai installer

A beginner-friendly, open-source installer and launcher for Claude CLI, future agents, prerequisites, and commonly needed tools.

This repository is currently being rebuilt from the old shell prototype into a MAS-inspired Windows startup architecture. The old local prototype scripts have been removed; the next implementation should follow the startup-stage documents under `notes/architecture/`.

## Target entry points

### Windows public bootstrap target

```powershell
irm https://get.dingjiai.com/win.ps1 | iex
```

The Windows entry should stay thin: it performs only the minimum bootstrap work, prepares or refreshes verified local payload files, then hands off into the dedicated administrator `cmd.exe` main UI window.

### macOS / Linux

macOS / Linux remains a planned top-level platform entry, but the current implementation target is Windows first.

## Windows interaction model

The agreed Windows-first interaction model is:

1. start from any supported shell entry
2. normalize the startup host only as needed
3. prepare a local workspace
4. fetch and verify manifest-defined payload files
5. relaunch into a dedicated administrator `cmd.exe` window
6. run the real installer UI, numbered menus, and all later install interactions inside that window

For Windows, the original PowerShell or terminal session is only the bootstrap host. The real menu-driven installer experience should not depend on whether the user started from Windows Terminal, Windows PowerShell 5.1, PowerShell 7, or another supported shell.

## Intended main menu

The intended main Windows menu remains:

- `1` 安装 Claude 和依赖
- `2` 更新 Claude 和依赖
- `3` 卸载 Claude 和依赖
- `0` 退出

The administrator `cmd.exe` payload now routes options `1`, `2`, and `3` into separate Windows flow entries under `payload/flows/windows/`. The install flow currently includes read-only `winget` and Git checkpoint samples plus a default no-download App Installer staging sample, while the remaining checkpoints are placeholders; real install, update, and uninstall actions are not wired yet.

## Claude path tool layering

The current Windows-first Claude path uses three layers.

### 1. Anthropic official minimum baseline

This layer follows Anthropic's official native Windows requirements first.

- Windows 10 1809+ or Windows Server 2019+
- x64 or ARM64 processor
- 4 GB+ RAM
- internet connection
- PowerShell or CMD shell
- supported Claude access
- Git for Windows

### 2. Project default enhancement layer

This layer is not part of Anthropic's official minimum baseline, but is currently treated as the default install set for the Windows-first Claude path and should be installed automatically by the default installer flow.

- `gh`
- `rg`
- Python
- `pip`
- Playwright
- `jq`
- `bat`
- `7z`

### 3. Optional enhancement layer

These tools are useful, but are currently optional rather than part of the default install set.

- `duf`
- `doggo`
- `btop4win`
- `pandoc`

For the durable baseline and package mapping, see:

- `notes/claude-cli-baseline.md`
- `notes/tool-inventory.md`

## Architecture notes

- `notes/architecture/整体架构.md` — current architecture discussion source
- `notes/architecture/启动阶段（一次性）.md` — current startup-stage implementation source
- `notes/windows-architecture.md` — supporting Windows architecture notes

Current implementation focus is to harden the Windows startup path and then add dependency checkpoints one at a time. The `winget` and Git checkpoints are currently read-only discovery/decision samples, and the App Installer download checkpoint is a download-only staging sample that defaults to planned/no-download mode; Claude, default enhancements, update, and uninstall actions are still placeholders.

## GitHub Pages publishing target

Static installer files should continue to be compatible with GitHub Pages hosting under `docs/`, with the dedicated install subdomain:

```text
get.dingjiai.com
```

Current minimal v1 startup and placeholder business layout:

- `docs/win.ps1` — thin public Windows bootstrap entry kept at the GitHub Pages root for the public command
- `docs/installer/windows/check-startup.ps1` — local Windows startup manifest and payload self-check
- `docs/installer/windows/manifest.json` — startup payload manifest
- `docs/installer/windows/payload/main.cmd` — administrator `cmd.exe` menu orchestrator
- `docs/installer/windows/payload/ui.ps1` — centered Chinese panel renderer for the administrator CMD UI
- `docs/installer/windows/payload/flows/windows/*/entry.cmd` — placeholder flow entries for install, update, and uninstall
- `docs/installer/windows/payload/flows/windows/*/checkpoints/*.cmd` — checkpoint slots for hardened dependency work; `10_winget.cmd` and `20_git.cmd` are read-only samples, and `15_app_installer_download.cmd` is a download-only staging sample
- `docs/installer/windows/payload/lib/windows/*.cmd` — thin placeholder shared helper slots
- `docs/installer/windows/payload/lib/windows/winget.ps1` — read-only `winget` discovery, diagnosis, and decision helper
- `docs/installer/windows/payload/lib/windows/git.ps1` — read-only Git discovery, placeholder trust diagnosis, and decision helper
- `docs/installer/windows/payload/lib/windows/download.ps1` — download-only staging helper that defaults to planned/no-download output
- `docs/installer/windows/payload/tasks/*.cmd` — compatibility shims that forward to the flow entries

`docs/` is the GitHub Pages publishing root for runnable installer assets. Architecture and design Markdown now live under `notes/`, not under `docs/`.

## Project status

This repository is in a rebuild stage.

Already decided:

- the project remains a general-purpose agent installer, not a Claude-only product
- Windows is the first implementation target
- the public Windows entry shape remains `irm https://get.dingjiai.com/win.ps1 | iex`
- the startup flow should be MAS-inspired but clean-room and MIT-compatible
- the real Windows UI should run in a dedicated administrator `cmd.exe` window
- `handoffAccepted` only means that the administrator `cmd.exe` payload entry accepted control of the main menu flow

Implemented in the current startup skeleton:

- new public Windows bootstrap file
- minimal manifest schema and payload file layout
- staging-based payload hash verification before promotion
- local startup state file
- administrator `cmd.exe` handoff attempt and 30s `handoffAccepted` wait
- administrator `cmd.exe` numbered menu loop skeleton with a fixed-size centered panel UI
- split placeholder Windows flow, checkpoint, and thin shared helper skeletons for install, update, and uninstall
- startup state JSON checks and startup JSONL log output
- Windows build 17763+ and PowerShell 5.1+ startup hard gates
- unified startup failure output with reason, suggestion, and log path

Not implemented yet after the prototype cleanup:

- real `winget`, Git, Claude, update, and uninstall checkpoint logic beyond the current report/download-only samples
- GitHub Pages configuration for serving `docs/`
- DNS setup for `get.dingjiai.com`
- macOS / Linux remote bootstrap endpoint

## License

MIT

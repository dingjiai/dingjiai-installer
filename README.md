# dingjiai installer

A beginner-friendly, open-source installer and launcher for Claude CLI, future agents, prerequisites, and commonly needed tools.

This repository is currently being rebuilt from the old shell prototype into a MAS-inspired Windows startup architecture. The old local prototype scripts have been removed; the next implementation should follow the startup-stage documents under `docs/新版架构讨论/`.

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

These menu action flows are not currently wired after the prototype cleanup. The administrator `cmd.exe` payload now has a real numbered menu loop, but options `1`, `2`, and `3` still show honest placeholders and return to the menu.

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

- `docs/新版架构讨论/整体架构.md` — current architecture discussion source
- `docs/新版架构讨论/启动阶段（一次性）.md` — current startup-stage implementation source
- `notes/windows-architecture.md` — supporting Windows architecture notes

Current implementation focus is to rebuild the Windows startup path first: thin public bootstrap, local workspace, manifest and payload verification, and administrator `cmd.exe` handoff. Dependency checkpoints such as `winget`, Git, Claude, and the default enhancement layer should come after that startup handoff is real.

## GitHub Pages publishing target

Static installer files should continue to be compatible with GitHub Pages hosting under `docs/`, with the dedicated install subdomain:

```text
get.dingjiai.com
```

Current minimal v1 startup layout:

- `docs/win.ps1` — thin public Windows bootstrap entry
- `docs/installer/windows/manifest.json` — startup payload manifest
- `docs/installer/windows/payload/main.cmd` — administrator `cmd.exe` menu orchestrator
- `docs/installer/windows/payload/tasks/*.cmd` — placeholder task executors for install, update, and uninstall

This layout is intentionally minimal and only covers the startup handoff skeleton. The old prototype payload file layout has been removed.

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
- administrator `cmd.exe` numbered menu loop skeleton
- split placeholder task executor scripts for install, update, and uninstall
- startup state JSON checks and startup JSONL log output

Not implemented yet after the prototype cleanup:

- real `winget`, Git, Claude, update, and uninstall flows
- GitHub Pages configuration for serving `docs/`
- DNS setup for `get.dingjiai.com`
- macOS / Linux remote bootstrap endpoint

## License

MIT

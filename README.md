# dingjiai installer shell

A minimal open-source installer shell prototype with two entry points.

## Entry points

### Windows PowerShell bootstrap target

```powershell
irm https://get.dingjiai.com/win.ps1 | iex
```

### Windows local bootstrap source

```powershell
./bootstrap/win.ps1 -SourceDir ./docs/installer/windows
```

### macOS / Linux local launcher

```bash
./unix.sh
```

Current payload base URL used by the Windows bootstrap:

```text
https://get.dingjiai.com/installer/windows
```

## Windows interaction model

The agreed Windows-first interaction model is now:

1. start from any supported shell entry
2. perform only the minimum bootstrap work in that original shell
3. relaunch into a dedicated administrator `cmd.exe` window
4. run the real installer UI, numbered menus, and all later install interactions inside that window

For Windows, the original PowerShell or terminal session is only the bootstrap host.
The real menu-driven installer experience should not depend on whether the user started from Windows Terminal, Windows PowerShell 5.1, PowerShell 7, or another supported shell.

## Current menu

The intended main Windows menu remains:

- `1` 安装 Claude 和依赖
- `2` 更新 Claude 和依赖
- `3` 卸载 Claude 和依赖
- `0` 退出

## Claude path tool layering

The current Windows-first Claude path uses three layers:

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

- `notes/windows-architecture.md` — current Windows-first installer architecture, hosting, relaunch model, and admin strategy

Current implementation focus is still to make the `winget` checkpoint and Git checkpoint real first, before wiring Claude and the default enhancement layer actions.

## GitHub Pages publishing layout

Published files should live under `docs/`:

- `docs/CNAME` — custom domain for Pages
- `docs/win.ps1` — Windows bootstrap entry
- `docs/installer/windows/win.ps1` — Windows launcher payload
- `docs/installer/windows/main.cmd` — Windows main menu host
- `docs/installer/windows/menu.txt` — Windows menu payload

## Project status

This repository is still a Windows-first shell prototype.

It already proves:
- two platform entry points can share one menu definition
- the Windows bootstrap can fetch or copy payload files before launching
- the installer distribution can live on a dedicated subdomain without touching the main site
- the Windows files can be hosted on GitHub Pages instead of your app server
- the structure is ready for real install logic later
- option `1` can now do real `winget` and Git discovery / allowance / action / validation work before stopping at the first milestone

Not implemented yet:
- the new dedicated administrator `cmd.exe` Windows main UI handoff
- real Claude checkpoint action flow
- real default enhancement layer action flow
- real update flow for option `2`
- real uninstall flow for option `3`
- persisted environment profile reuse across multiple runs
- GitHub Pages configuration for serving `docs/`
- DNS setup for `get.dingjiai.com`
- Unix remote bootstrap endpoint

## Files

- `win.ps1` — local Windows launcher and backend task entry
- `main.cmd` — local Windows main menu host
- `bootstrap/win.ps1` — local bootstrap source version
- `docs/win.ps1` — published Windows bootstrap entry
- `docs/installer/windows/win.ps1` — published Windows launcher payload
- `docs/installer/windows/main.cmd` — published Windows main menu host
- `docs/installer/windows/menu.txt` — published Windows menu payload
- `unix.sh` — macOS/Linux local launcher
- `menu.txt` — shared local menu definition

## License

MIT

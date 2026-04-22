# dingjiai installer shell

A minimal open-source installer shell prototype with two entry points.

## Entry points

### Windows PowerShell local launcher

```powershell
./win.ps1
```

### Windows remote bootstrap target

```powershell
irm https://get.dingjiai.com/win.ps1 | iex
```

Current payload base URL used by the bootstrap:

```text
https://get.dingjiai.com/installer/windows
```

### macOS / Linux local launcher

```bash
./unix.sh
```

Both local entry scripts load the same placeholder menu from `menu.txt`.

The installer now performs a real first-stage basic environment check before showing the placeholder top-level menu.
This first stage is used to understand the current environment and prepare the second stage, rather than block imperfect environments by default.

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

- `notes/windows-architecture.md` — current Windows-first installer architecture, hosting, and admin strategy

## GitHub Pages publishing layout

Published files should live under `docs/`:

- `docs/CNAME` — custom domain for Pages
- `docs/win.ps1` — Windows bootstrap entry
- `docs/installer/windows/win.ps1` — local Windows launcher payload
- `docs/installer/windows/menu.txt` — Windows menu payload

## Current menu

- `1` 安装 Claude 和依赖
- `2` 更新 Claude 和依赖
- `3` 卸载 Claude 和依赖
- `0` 退出

## Project status

This repository is the shell prototype only.

It already proves:
- two platform entry points can share one menu definition
- the basic menu loop works on PowerShell and Unix shell
- the Windows bootstrap can fetch or copy payload files before launching
- the installer distribution can live on a dedicated subdomain without touching the main site
- the Windows files can be hosted on GitHub Pages instead of your app server
- the structure is ready for real install logic later

Not implemented yet:
- real install Claude and dependencies flow
- real update Claude and dependencies flow
- real uninstall Claude and dependencies flow
- persisted environment profile reuse across multiple runs
- GitHub Pages configuration for serving `docs/`
- DNS setup for `get.dingjiai.com`
- Unix remote bootstrap endpoint

## Files

- `win.ps1` — local Windows launcher
- `bootstrap/win.ps1` — local bootstrap source version
- `docs/win.ps1` — published Windows bootstrap entry
- `docs/installer/windows/win.ps1` — published Windows launcher payload
- `docs/installer/windows/menu.txt` — published Windows menu payload
- `unix.sh` — macOS/Linux local launcher
- `menu.txt` — shared local menu definition

## License

MIT

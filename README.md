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

## GitHub Pages publishing layout

Published files should live under `docs/`:

- `docs/CNAME` — custom domain for Pages
- `docs/win.ps1` — Windows bootstrap entry
- `docs/installer/windows/win.ps1` — local Windows launcher payload
- `docs/installer/windows/menu.txt` — Windows menu payload

## Current menu

- `1` System check
- `2` Install Claude
- `3` Uninstall Claude
- `0` Exit

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
- real system checks
- real Claude install flow
- real Claude uninstall flow
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

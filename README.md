# dingjiai installer shell

A minimal open-source installer shell prototype with two entry points.

## Entry points

### Windows PowerShell

```powershell
./win.ps1
```

### macOS / Linux

```bash
./unix.sh
```

Both entry scripts load the same placeholder menu from `menu.txt`.

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
- the structure is ready for real install logic later

Not implemented yet:
- real system checks
- real Claude install flow
- real Claude uninstall flow
- remote `irm` / `curl` bootstrap endpoints

## Files

- `win.ps1` — Windows entry script
- `unix.sh` — macOS/Linux entry script
- `menu.txt` — shared menu definition

## License

MIT

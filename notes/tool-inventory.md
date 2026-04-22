# Tool inventory

This file tracks the broader helper-tool inventory around the Windows-first Claude CLI path.

It is separate from `notes/claude-cli-baseline.md`.
Inclusion here means the project wants to track the tool, not that it is automatically part of Anthropic's official minimum baseline.

## Layering rule

- Anthropic's official minimum baseline stays in `notes/claude-cli-baseline.md`.
- This file tracks the project enhancement layers on top of that baseline.
- The project default enhancement layer is what the current Windows-first default install path should install automatically.
- The optional enhancement layer is useful, but not required for the current default install path.
- For core dependency tools, exact trust fields used by installation logic should be defined in the baseline note first.
This inventory file should track package identities, enhancement layers, and local snapshots rather than become the source of truth for minimum allowed versions.

## Current tracked tools

### Project default enhancement layer

- `gh`
- `rg`
- Python
- `pip`
- Playwright
- `jq`
- `bat`
- `7z`

### Optional enhancement layer

- `duf`
- `doggo`
- `btop4win`
- `pandoc`

## Windows package identities to use

### Project default enhancement layer

- `gh`
  - winget: `GitHub.cli`
- `rg`
  - winget: `BurntSushi.ripgrep.MSVC`
- Python
  - winget: `Python.Python.3.13`
- `pip`
  - bundled with `Python.Python.3.13`
  - do not install a separate unrelated package for `pip`
- Playwright
  - npm: `playwright`
  - then run: `npx playwright install`
  - do not substitute with `playwright-core` for the default beginner path
- `jq`
  - winget: `jqlang.jq`
- `bat`
  - winget: `sharkdp.bat`
- `7z`
  - winget: `7zip.7zip`
  - do not substitute with `7zip.7zr` or `mcmilk.7zip-zstd`

### Optional enhancement layer

- `duf`
  - winget: `muesli.duf`
  - do not substitute with `sigoden.Dufs`
- `doggo`
  - winget: `MrKaran.Doggo`
- `btop4win`
  - winget: `aristocratos.btop4win`
  - do not substitute with `abdenasser.NeoHtop`
- `pandoc`
  - winget: `JohnMacFarlane.Pandoc`
  - do not substitute with `PandocGUI` or `Ombrelin.PandocGui`

## Current local snapshot

### Installed locally

#### Project default enhancement layer

- `gh`
- `rg`
- Python
- `pip`
- Playwright
- `jq`
- `bat`
- `7z`

#### Optional enhancement layer

- `duf`
- `doggo`
- `btop4win`
- `pandoc`

## Current notes

- `7z` was already present locally and required a PATH fix.
- Python and `pip` are now installed as real local executables instead of relying on the Microsoft Store alias.
- Playwright is now installed globally from npm and its browser payloads were downloaded into `C:\Users\bb\AppData\Local\ms-playwright`.
- In PowerShell, prefer `playwright.cmd` or `npx.cmd` because the `.ps1` shim can be blocked by execution policy.
- `doggo` is the selected DNS diagnostic tool for the current optional enhancement layer.
- `aristocratos.btop4win` is the selected process/resource monitor for the current optional enhancement layer and exposes `btop4win.exe` in this environment rather than a plain `btop` command.
- `pandoc` and `bat` are installed from their confirmed official packages.
- `rg` is installed from the confirmed ripgrep package. If an already-open shell still cannot resolve `rg`, reopen that shell so it reloads the updated PATH.

## Documentation rule

- Update this file when the tracked helper-tool list changes.
- Update this file when the current layer assignment changes.
- Update this file when the local installed/not-installed snapshot materially changes during setup work.
- Update this file when the exact package identity for a tracked tool is confirmed or revised.
- Once a default tool is selected for a capability, remove unchosen alternatives from this file instead of keeping them as reminders.
- Do not substitute similarly named packages unless the user explicitly confirms the change.
- Do not use this file to redefine the official Claude CLI minimum baseline; keep that in `notes/claude-cli-baseline.md`.

# Changelog

## v1.0.2 — Installer Reliability Hotfix

- Fixed duplicate detection of the same DDLC path when only drive-letter/path casing differed.
- Fixed Windows PowerShell 5.1 failure while writing `backup_manifest.json` (`Argument types do not match`).
- Added automatic DDLC path discovery.
- Added exact SUN-TEAM Studio v1.0 detection by SHA-256.
- Added compatible-Russian-localization detection.
- Added safe skip when Russian subtitles are already installed.
- Added conflict protection for other Ren'Py mods.
- Added backups outside `game/`.
- Added duplicate voice-hook cleanup.
- Added first-run Python / PyTorch / Silero setup.
- Added NVIDIA CUDA vs CPU PyTorch selection.
- Added independent Silero self-test.
- Added diagnostics.
- Added latest-backup restore utility.
- Voice behavior remains based on stable v0.5.2.3 Acting Lite / Natural Dashes.

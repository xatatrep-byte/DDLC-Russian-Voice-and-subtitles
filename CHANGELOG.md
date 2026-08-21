# Changelog

## v1.0.2 — Stable Installer Release

### Installer

- Automatic DDLC path discovery.
- Additional Steam Library detection.
- Case-insensitive path deduplication.
- Original DDLC / DDLC Plus safety check.
- Exact SUN-TEAM Studio v1.0 detection.
- Existing Russian localization preservation.
- Safe subtitle installation when no Russian localization is present.
- Conflict protection for other Ren'Py mods.
- Backups stored outside `game`.
- Duplicate `zz_ddlc_russian_voice.rpy` cleanup.
- Windows PowerShell 5.1 backup manifest fix.
- First-run Python / PyTorch / Silero setup.
- NVIDIA CUDA / CPU runtime selection.
- Independent Silero self-test.
- Diagnostics and latest-backup restore utility.

### Voice runtime

Stable baseline:

`v0.5.2.3 Acting Lite / Natural Dashes`

- Clause-level punctuation-aware prosody.
- Deterministic micro-pauses.
- Natural dash handling for all speakers.
- Internal-word hyphen protection.
- Fixed speaker mapping for all main characters.
- Qwen runtime removed.

### Repository

- Public source tree kept free of full DDLC assets.
- Binary SUN-TEAM translation payload kept out of Git history.
- Added public Release documentation.
- Added SUN-TEAM credits notice.
- Added `.gitignore`.
- Added GitHub bug-report template.

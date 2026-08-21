# Changelog

## v1.0.5 — Full SUN-TEAM Overlay

- Удалена логика частичной сборки русификатора из отдельных файлов.
- В Full release включён исходный `DDLC_1.0_PC.rar` целиком.
- Перед установкой проверяется SHA-256 полного RAR:
  `15f4ffe7bb5e91a81e21e2c30448c3070e1511278187347fd2d1b719a5c01837`.
- 7-Zip сначала тестирует архив, и только после этого начинается замена.
- `game`, `renpy`, `lib`, `characters` очищаются и восстанавливаются целиком из SUN-TEAM архива.
- После полного русского baseline устанавливается voice runtime.
- Voice runtime собран из проверенной цепочки:
  - v1.0.3 fresh-PC Python fix;
  - v1.0.4b `runtime-ready.flag` / no SAPI fallback;
  - v1.0.4c Latin nickname fix.

- README/release notes now explain that first-time installation may take around 10–15 minutes because Python/PyTorch/Silero/7-Zip can be installed automatically.

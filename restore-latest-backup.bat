@echo off
chcp 65001 >nul
title DDLC Russian Voice - Restore Latest Backup
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-latest-backup.ps1"
echo.
pause

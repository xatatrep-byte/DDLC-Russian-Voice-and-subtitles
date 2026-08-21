@echo off
chcp 65001 >nul
title DDLC Russian Voice - Diagnostic
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1"
echo.
pause

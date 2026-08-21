@echo off
chcp 65001 >nul
title DDLC Russian Voice - Safe Installer
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause

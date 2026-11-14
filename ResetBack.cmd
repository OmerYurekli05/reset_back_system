@echo off
rem reset_back_system launcher: double-click to open the interface.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ResetBack.ps1" %*

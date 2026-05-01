@echo off
cd /d C:\starruptureserver
del /f /q C:\starruptureserver\auto_shutdown_state.json 2>nul
start "" ".\StarRuptureServerEOS.exe" -Log -port=7777

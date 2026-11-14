@echo off
:: Abre o painel do TravaCalor (ele mesmo pede permissao de administrador).
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0painel.ps1"

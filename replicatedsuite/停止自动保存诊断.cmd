@echo off
setlocal
chcp 65001 >nul
if not exist "%~dp0tools\RS-Diagnostic-Exporter.exe" (
  echo 诊断导出程序缺失，请关闭自动接收器窗口以停止接收。
  pause
  exit /b 1
)
"%~dp0tools\RS-Diagnostic-Exporter.exe" --stop

@echo off
setlocal
chcp 65001 >nul
if not exist "%~dp0tools\RS-Diagnostic-Exporter.exe" (
  echo 诊断导出程序缺失，请重新解压完整插件包，保留 tools 文件夹。
  pause
  exit /b 1
)
"%~dp0tools\RS-Diagnostic-Exporter.exe" --game "%~dp0..\.."
if errorlevel 1 (
  echo 请先在游戏诊断页面点“导出文件”，稍后再运行本工具。
) else (
  explorer "%~dp0..\诊断报告"
)
pause

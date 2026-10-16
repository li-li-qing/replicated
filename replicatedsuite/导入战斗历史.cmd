@echo off
REM Replicated Suite · 从完整TXT准备战斗历史导入
REM 作者：Replicated
REM QQ群：1104129461
setlocal
chcp 65001 >nul
if not exist "%~dp0tools\RS-Diagnostic-Exporter.exe" (
  echo 文件工具缺失，请重新解压完整插件包并保留 tools 文件夹。
  pause
  exit /b 1
)
if "%~1"=="" (
  "%~dp0tools\RS-Diagnostic-Exporter.exe" --import-history
) else (
  "%~dp0tools\RS-Diagnostic-Exporter.exe" --import-history "%~1"
)
pause

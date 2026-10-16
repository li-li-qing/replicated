@echo off
REM Replicated Suite · 导出完整战斗历史TXT
REM 作者：Replicated
REM QQ群：1104129461
setlocal
chcp 65001 >nul
if not exist "%~dp0tools\RS-Diagnostic-Exporter.exe" (
  echo 文件工具缺失，请重新解压完整插件包并保留 tools 文件夹。
  pause
  exit /b 1
)
"%~dp0tools\RS-Diagnostic-Exporter.exe" --game "%~dp0..\.." --history
if errorlevel 1 (
  echo 请先在游戏个人历史页点“导出TXT”，稍后重试。
) else (
  explorer "%~dp0..\战斗历史"
)
pause

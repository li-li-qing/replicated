@echo off
setlocal
chcp 65001 >nul
if not exist "%~dp0tools\RS-Diagnostic-Exporter.exe" (
  echo 诊断导出程序缺失，请重新解压完整插件包，保留 tools 文件夹。
  pause
  exit /b 1
)
echo 请保留此窗口。游戏里点击“导出文件”后，完整 txt 会保存到 Addon\诊断报告。
echo 无需安装 Python 或 Codex。关闭此窗口即可停止接收。
"%~dp0tools\RS-Diagnostic-Exporter.exe" --game "%~dp0..\.." --watch
pause

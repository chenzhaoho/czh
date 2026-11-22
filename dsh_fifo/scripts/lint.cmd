@echo off
rem ===========================================================================
rem  scripts\lint.cmd : RTL lint (Verilator --lint-only)
rem  用法: scripts\lint.cmd
rem ===========================================================================
setlocal
python "%~dp0lint_rtl.py"
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%

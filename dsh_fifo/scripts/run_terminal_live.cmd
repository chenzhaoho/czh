@echo off
setlocal
if defined TERMINAL_PYTHON goto run_python
where py >nul 2>nul
if not errorlevel 1 goto run_py
set "TERMINAL_PYTHON=python"
:run_python
"%TERMINAL_PYTHON%" -u "%~dp0terminal_live.py" %*
goto finished
:run_py
py -3 -u "%~dp0terminal_live.py" %*
:finished
set "TERMINAL_EXIT=%errorlevel%"
if not "%TERMINAL_EXIT%"=="0" pause
exit /b %TERMINAL_EXIT%

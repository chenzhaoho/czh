@echo off
setlocal
if defined TERMINAL_PYTHON (
    "%TERMINAL_PYTHON%" "%~dp0verify_fifo_ip.py" %*
) else (
    where py >nul 2>nul
    if errorlevel 1 (
        python "%~dp0verify_fifo_ip.py" %*
    ) else (
        py -3 "%~dp0verify_fifo_ip.py" %*
    )
)
exit /b %ERRORLEVEL%

@echo off
rem ===========================================================================
rem  scripts\verify.cmd -- one-click auditable verification report
rem
rem  Usage:
rem    scripts\verify.cmd            full  (18 sims + lint + mutation, ~90 s)
rem    scripts\verify.cmd fast       skip lint and mutation (~60 s)
rem    scripts\verify.cmd nosim      re-summarise existing logs only (~2 s)
rem
rem  Output:
rem    doc\verify_report.html       open in a browser
rem    doc\verify_report_data.json  raw data
rem
rem  NOTE: keep this file pure ASCII. Chinese text inside a .cmd breaks cmd
rem        parsing on Chinese-locale Windows (verified the hard way).
rem ===========================================================================
setlocal
set "ROOT=%~dp0.."
set "MODE=%~1"

set "ARGS="
if /i "%MODE%"=="fast"  set "ARGS=--fast"
if /i "%MODE%"=="nosim" set "ARGS=--no-sim"

pushd "%ROOT%"
if defined TERMINAL_PYTHON goto :custom_py
where py >nul 2>nul
if errorlevel 1 goto :path_py
py -3 "%ROOT%\scripts\verify_all.py" %ARGS%
goto :result
:path_py
python "%ROOT%\scripts\verify_all.py" %ARGS%
goto :result
:custom_py
"%TERMINAL_PYTHON%" "%ROOT%\scripts\verify_all.py" %ARGS%
:result
set "RC=%ERRORLEVEL%"
popd

if not "%RC%"=="0" (
    echo [verify] ERROR: report generation failed with code %RC%
    exit /b %RC%
)

if exist "%ROOT%\doc\verify_report.html" (
    echo [verify] opening report in browser ...
    start "" "%ROOT%\doc\verify_report.html"
)
exit /b 0

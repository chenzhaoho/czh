@echo off
rem ===========================================================================
rem  scripts\run_sim.cmd -- entry point (pure ASCII: Chinese text in a .cmd
rem  breaks cmd parsing on Chinese Windows)
rem
rem  Usage:
rem    scripts\run_sim.cmd                            all testcases, 2-stage
rem    scripts\run_sim.cmd tc2 7                      testcase tc2, seed 7
rem    scripts\run_sim.cmd tc1 1 3                    testcase tc1, 3-stage sync
rem    scripts\run_sim.cmd tc1 1 2 dump               also dump VCD waveform
rem    scripts\run_sim.cmd tc2 1 2 noverify           reuse the compiled library
rem    scripts\run_sim.cmd tc2 1 2 verify 2000 5000   read-clock phase A/B (ps)
rem ===========================================================================
setlocal
set "TC=%~1"
set "SEED=%~2"
set "STG=%~3"
set "OPT=%~4"
set "PHA=%~5"
set "PHB=%~6"
if "%TC%"==""   set "TC=tcA"
if "%SEED%"=="" set "SEED=1"
if "%STG%"==""  set "STG=2"
if "%OPT%"==""  set "OPT=verify"
if "%PHA%"==""  set "PHA=0"
if "%PHB%"==""  set "PHB=0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_sim.ps1" -Test %TC% -Seed %SEED% -Stages %STG% -Mode %OPT% -PhaPs %PHA% -PhbPs %PHB%
exit /b %ERRORLEVEL%
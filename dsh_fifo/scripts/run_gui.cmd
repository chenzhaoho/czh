@echo off
rem ===========================================================================
rem  scripts\run_gui.cmd -- open ModelSim GUI with the design loaded and waves
rem
rem  Usage:
rem    scripts\run_gui.cmd               tc1, seed 1, 2-stage
rem    scripts\run_gui.cmd tc4 7 3       tc4, seed 7, 3-stage
rem    scripts\run_gui.cmd tc1 1 2 noacc tc1 without +acc (faster, fewer signals)
rem
rem  WHY THIS SCRIPT EXISTS
rem  ----------------------
rem  Typing  vsim -voptargs="+acc" work.tb_top +TEST=tc1 ...  by hand fails
rem  whenever the Transcript working directory is not  sim\msim_<n>stage :
rem  ModelSim cannot resolve the "work" library, shows an error dialog and
rem  (in starter edition GUI mode) exits after you dismiss it.
rem  This script always runs from the correct library directory, and it also
rem  creates the library by compiling first if it is missing.
rem
rem  Keep this file pure ASCII: Chinese text inside a .cmd breaks cmd parsing
rem  on Chinese Windows.
rem ===========================================================================
setlocal
set "TC=%~1"
set "SEED=%~2"
set "STG=%~3"
set "ACC=%~4"
if "%TC%"==""   set "TC=tc1"
if "%SEED%"=="" set "SEED=1"
if "%STG%"==""  set "STG=2"

set "ROOT=%~dp0.."
set "LIB=%ROOT%\sim\msim_%STG%stage"
set "MSIM=%MODELSIM_BIN%"
if not defined MSIM (
    for /f "delims=" %%V in ('where vsim.exe 2^>nul') do if not defined MSIM set "MSIM=%%~dpV"
)
if not defined MSIM set "MSIM=E:\modelsim_ase\win32aloem"
if not exist "%MSIM%\vsim.exe" (
    echo [run_gui] ERROR: Set MODELSIM_BIN to the directory containing vsim.exe.
    exit /b 2
)

rem ---- make sure the library exists and contains tb_top ----
if not exist "%LIB%\work" goto :compile
if not exist "%LIB%\work\_info" goto :compile
echo [run_gui] reusing library in sim\msim_%STG%stage
goto :launch

:compile
echo [run_gui] library missing, compiling first ...
call "%ROOT%\scripts\run_sim.cmd" %TC% %SEED% %STG% verify
if errorlevel 1 (
    echo [run_gui] ERROR: compile failed
    exit /b 3
)

:launch
pushd "%LIB%"
if /i "%ACC%"=="noacc" goto :launch_fast
echo [run_gui] launching ModelSim GUI  TEST=%TC%  SEED=%SEED%  STAGES=%STG%
start "ModelSim %TC%" "%MSIM%\vsim.exe" -gui -voptargs="+acc" work.tb_top +TEST=%TC% +SEED=%SEED% +STAGES=%STG% -do "add wave -r /tb_top/h/*; add wave -r /tb_top/h/u_dut/*; configure wave -namecolwidth 240; configure wave -signalnamewidth 1; run -all"
goto :done

:launch_fast
echo [run_gui] launching ModelSim GUI (no +acc)  TEST=%TC%  SEED=%SEED%  STAGES=%STG%
start "ModelSim %TC%" "%MSIM%\vsim.exe" -gui work.tb_top +TEST=%TC% +SEED=%SEED% +STAGES=%STG% -do "add wave -r /tb_top/h/*; run -all"
goto :done

:done
popd
echo [run_gui] ModelSim window should now be open.
echo [run_gui] If it still reports "cannot find work.tb_top", type in the
echo [run_gui] ModelSim Transcript:  pwd    then   vdir work    and send me
echo [run_gui] the output -- that tells us where the library ended up.
endlocal

@echo off
rem ===========================================================================
rem  scripts\regression.cmd -- full regression over both synchroniser variants
rem
rem  Runs tc1..tc9 for SYNC_STAGES = 2 and 3, writes one log per run into
rem  sim\logs\ and prints a PASS/FAIL line for each testcase.
rem
rem  NOTE: keep this file pure ASCII (Chinese text inside a .cmd breaks cmd
rem        parsing on Chinese Windows).
rem ===========================================================================
setlocal
set "HERE=%~dp0"
set "RESULTS=%HERE%..\sim\coverage\regression_summary.txt"
set "REGRESSION_FAILED=0"

if not exist "%HERE%..\sim\coverage" mkdir "%HERE%..\sim\coverage"
echo Dual Asynchronous FIFO - regression summary > "%RESULTS%"
echo. >> "%RESULTS%"

for %%S in (2 3) do (
  echo.
  echo ================= SYNC_STAGES=%%S =================
  echo SYNC_STAGES=%%S >> "%RESULTS%"
  for %%T in (tc1 tc2 tc3 tc4 tc5 tc6 tc7 tc8 tc9) do (
    call "%HERE%run_sim.cmd" %%T 1 %%S verify >nul 2>&1
    if errorlevel 1 (
      set "REGRESSION_FAILED=1"
      echo   %%T  FAIL
      echo   %%T  FAIL >> "%RESULTS%"
    ) else (
      echo   %%T  PASS
      echo   %%T  PASS >> "%RESULTS%"
    )
  )
)

echo.
echo Summary written to sim\coverage\regression_summary.txt
type "%RESULTS%"
endlocal & exit /b %REGRESSION_FAILED%

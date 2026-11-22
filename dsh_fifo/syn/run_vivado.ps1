# run_vivado.ps1 -- drive Vivado 2020.2 over three PPA configurations
#   1) dual_2stage   : dual-channel top, SYNC_STAGES=2 (default)
#   2) dual_3stage   : dual-channel top, SYNC_STAGES=3 (MTBF comparison)
#   3) single_fifo_a : single-channel fifo_a (PPA baseline)
#
# Implementation runs on thin wrappers (syn/syn_wrap_*.v) because the raw
# top level exposes ~1262 ports while xc7a35tcsg324 has only 210 user I/O.
# Reports land in  syn\vivado\<config>\  :
#   util_synth.rpt / util_route.rpt / timing_synth.rpt / timing_route.rpt / power.rpt
param(
    [ValidateSet("all", "dual_2stage", "dual_3stage", "single_fifo_a", "dual_rm1_pipe")]
    [string] $Config = "all"
)

$ErrorActionPreference = "Continue"
$VIVADO = $env:VIVADO_EXE
if (-not $VIVADO) {
    $found = Get-Command vivado.bat -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $VIVADO = $found.Source }
    else { $VIVADO = "E:\Vivado\2020.2\bin\vivado.bat" }
}
$SYNROOT = $PSScriptRoot
$TCL     = "$SYNROOT\run_vivado_syn.tcl"

if (-not (Test-Path -LiteralPath $VIVADO -PathType Leaf)) {
    Write-Host "Vivado not found. Set VIVADO_EXE to the full path of vivado.bat."
    exit 2
}
New-Item -ItemType Directory -Path (Join-Path $SYNROOT "vivado") -Force | Out-Null

$configs = @(
    @{ Name = "dual_2stage";   Top = "syn_wrap_dual";   PName = "";            PVal = "" },
    @{ Name = "dual_3stage";   Top = "syn_wrap_dual";   PName = "SYNC_STAGES"; PVal = "3" },
    @{ Name = "single_fifo_a"; Top = "syn_wrap_single"; PName = "";            PVal = "" },
    @{ Name = "dual_rm1_pipe"; Top = "syn_wrap_dual";   PName = "READ_MODE";    PVal = "1" }
)

$failed = $false
foreach ($cfg in $configs) {
    if ($Config -ne "all" -and $cfg.Name -ne $Config) { continue }
    $out = Join-Path $SYNROOT ("vivado\" + $cfg.Name)
    $log = Join-Path $SYNROOT ("vivado\" + $cfg.Name + "_run.log")
    Write-Host ""
    Write-Host ("=" * 72)
    Write-Host "CONFIG: $($cfg.Name)  top=$($cfg.Top)  param=$($cfg.PName)=$($cfg.PVal)"
    Write-Host ("=" * 72)

    $t0 = Get-Date
    $genericArgs = @()
    if ($cfg.PName) { $genericArgs = @($cfg.PName, $cfg.PVal) }
    & $VIVADO -mode batch -nojournal -nolog -source $TCL -tclargs $cfg.Top $out @genericArgs *>&1 |
        Tee-Object -FilePath $log | Select-String -Pattern "INFO: |FATAL|ERROR: \[|SYN_DONE" | ForEach-Object { $_.Line }
    $runExit = $LASTEXITCODE
    if ($runExit -ne 0 -or -not (Select-String -LiteralPath $log -SimpleMatch "SYN_DONE" -Quiet)) { $failed = $true }
    $dt = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
    Write-Host "elapsed: $dt min, exit=$LASTEXITCODE"
}

Write-Host ""
Write-Host "ALL CONFIGS DONE.  Reports under $SYNROOT\vivado\"
if ($failed) { exit 1 }
exit 0

<#
=============================================================================
 scripts/run_sim.ps1 -- 双异步 FIFO 系统 仿真运行脚本 (单一入口)

 用法 (推荐通过同目录 run_sim.cmd 调用, 以免受 PowerShell 执行策略限制):
   scripts\run_sim.cmd                            编译并运行全部用例(tcA, 2级)
   scripts\run_sim.cmd tc2 7                      用例 tc2, 随机种子 7
   scripts\run_sim.cmd tc1 1 3                    用例 tc1, 3 级同步器配置
   scripts\run_sim.cmd tc1 1 2 dump               同时转储 VCD 波形
   scripts\run_sim.cmd tc2 1 2 noverify           跳过重编译, 复用已有库
   scripts\run_sim.cmd tc2 1 2 verify 2000 5000   读时钟初始相位 A/B (ps)

 脚本职责:
   1) 把 rtl\ 与 tb\ 下的 UTF-8 源文件转换为 GBK 放到 build\gbk_<n>stage
      (ModelSim 在中文 Windows 上按 ANSI/GBK 解释源文件, 否则中文注释乱码)
   2) 用 vlog 编译到 sim\msim_<n>stage\work
   3) 用 vsim 运行, 日志以 UTF-8 写入 sim\logs\
   4) 打印 失败检查点数 / 功能覆盖率 / PASS-FAIL 结论
=============================================================================
#>
param(
    [string] $Test   = "tcA",
    [int]    $Seed   = 1,
    [int]    $Stages = 2,
    [string] $Mode   = "verify",   # verify | noverify | dump
    [int]    $PhaPs  = 0,
    [int]    $PhbPs  = 0
)

$ErrorActionPreference = "Stop"

# ---- 路径解析: 由脚本位置推导工程根目录, 与调用者当前目录无关 ----
# 兼容三种运行方式:  run_sim.cmd / powershell -File run_sim.ps1 / 在会话中执行脚本内容
# (最后一种情况下 $PSScriptRoot 与 $MyInvocation.MyCommand.Path 都可能为空,
#  此时回退到当前目录, 再从当前目录向上寻找工程标志文件 README.md + rtl 目录)
function Find-ProjectRoot {
    $cand = @()
    if ($PSScriptRoot)                                  { $cand += (Split-Path -Parent $PSScriptRoot) }
    if ($MyInvocation.MyCommand.Path)                   { $cand += (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) }
    if ($PSCommandPath)                                 { $cand += (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) }
    $cand += (Get-Location).Path
    $cand += (Split-Path -Parent (Get-Location).Path)
    foreach ($c in $cand) {
        if (-not $c) { continue }
        try { $c = (Resolve-Path -LiteralPath $c -ErrorAction Stop).Path } catch { continue }
        if ((Test-Path (Join-Path $c 'rtl')) -and (Test-Path (Join-Path $c 'tb'))) { return $c }
    }
    return $null
}

$Root = Find-ProjectRoot
if (-not $Root) {
    Write-Host "[run_sim] ERROR: cannot locate the project root."
    Write-Host "[run_sim] Run it from the project root directory, e.g.:"
    Write-Host "[run_sim]     scripts\run_sim.cmd tc1 1 2 verify"
    Write-Host "[run_sim] or  powershell -ExecutionPolicy Bypass -File .\scripts\run_sim.ps1 -Test tc1"
    exit 2
}
if ($env:MODELSIM_BIN) {
    $Msim = $env:MODELSIM_BIN
} else {
    $found = Get-Command vsim.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $Msim = Split-Path -Parent $found.Source }
    else { $Msim = "E:\modelsim_ase\win32aloem" }
}
foreach ($tool in @("vlib.exe", "vlog.exe", "vsim.exe")) {
    if (-not (Test-Path -LiteralPath (Join-Path $Msim $tool) -PathType Leaf)) {
        Write-Host "[run_sim] ERROR: $tool not found in $Msim. Set MODELSIM_BIN to the simulator's bin directory."
        exit 2
    }
}
$Msim = (Resolve-Path -LiteralPath $Msim).Path
Write-Host "[run_sim] root = $Root"

$Build   = Join-Path $Root "build\gbk_${Stages}stage"
$Lib     = Join-Path $Root "sim\msim_${Stages}stage"
$LogDir  = Join-Path $Root "sim\logs"
if ($env:DSH_FIFO_LOG_DIR) { $LogDir = [IO.Path]::GetFullPath($env:DSH_FIFO_LOG_DIR) }
$WaveDir = Join-Path $Root "sim\waves"
foreach ($d in @($Build, $Lib, $LogDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$SrcFiles = @(
    "rtl\common\gray_codec.v", "rtl\common\sync_2ff.v", "rtl\common\sync_gray_bus.v",
    "rtl\common\rst_sync.v",
    "rtl\fifo\async_fifo.v", "rtl\fifo\fifo_a.v", "rtl\fifo\fifo_b.v",
    "rtl\top\monitor.v", "rtl\top\dual_async_fifo_top.v",
    "tb\env\tb_pkg.sv", "tb\env\tb_harness.sv", "tb\env\tb_coverage.sv",
    "tb\tb_top.sv", "tb\tb_std_read.sv"
)
$Top = if ($Test -eq "std") { "tb_std_read" } else { "tb_top" }

# ---- 1) UTF-8 -> GBK ; 2) vlog ----
if ($Mode -ne "noverify") {
    Write-Host "[run_sim] converting UTF-8 sources to GBK in build\gbk_${Stages}stage ..."
    $gbk   = [System.Text.Encoding]::GetEncoding(936)
    $built = @()
    foreach ($f in $SrcFiles) {
        $srcAbs = Join-Path $Root $f
        $dstAbs = Join-Path $Build (Split-Path -Leaf $f)
        $txt = [System.IO.File]::ReadAllText($srcAbs, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($dstAbs, $txt, $gbk)
        $built += $dstAbs
    }
    Write-Host "[run_sim] converted $($built.Count) files"

    Write-Host "[run_sim] compiling (SYNC_STAGES=$Stages) ..."
    Push-Location $Lib
    if (Test-Path "work") { Remove-Item -Recurse -Force "work" }
    $vlibOut = & (Join-Path $Msim "vlib.exe") work 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[run_sim] ERROR: vlib work failed: $vlibOut"
        Pop-Location
        exit 4
    }
    $clog = Join-Path $LogDir "compile_${Stages}stage.log"
    $defs = @()
    if ($Stages -eq 3) { $defs = @("+define+DUT_SYNC_STAGES=3") }
    $vlogOut = & (Join-Path $Msim "vlog.exe") -sv -work work @defs @built 2>&1
    $rc = $LASTEXITCODE
    $vlogOut | Set-Content -Encoding UTF8 $clog
    Pop-Location
    if ($rc -ne 0) {
        Write-Host "[run_sim] ERROR: compile failed, see $clog"
        $vlogOut | Select-String -Pattern "Error" | Select-Object -First 8 | ForEach-Object { "    " + $_.Line }
        exit 4
    }
    Write-Host "[run_sim] compile OK"
} else {
    Write-Host "[run_sim] noverify: reusing the library in sim\msim_${Stages}stage"
}

# ---- 3) vsim ----
Write-Host "[run_sim] running TEST=$Test SEED=$Seed STAGES=$Stages ..."
$logFile = Join-Path $LogDir "run_${Test}_seed${Seed}_${Stages}stage.log"
$plist = @("+TEST=$Test", "+SEED=$Seed", "+STAGES=$Stages",
           "+PHA_PS=$PhaPs", "+PHB_PS=$PhbPs")
if ($Mode -eq "dump") { $plist += "+DUMP" }
Push-Location $Lib
if (Test-Path "waves") { Remove-Item -Recurse -Force "waves" }
New-Item -ItemType Directory -Force -Path "waves" | Out-Null
$simOut = & (Join-Path $Msim "vsim.exe") -c -quiet $Top -do "run -all; quit -f" @plist 2>&1
$simExit = $LASTEXITCODE
$simOut | Set-Content -Encoding UTF8 $logFile
Pop-Location

# ---- 4) 波形归档 ----
if ($Mode -eq "dump") {
    $vcd = Join-Path $Lib "waves\dual_async_fifo.vcd"
    if (Test-Path $vcd) {
        New-Item -ItemType Directory -Force -Path $WaveDir | Out-Null
        Move-Item -Force $vcd (Join-Path $WaveDir "dual_async_fifo_${Test}_seed${Seed}.vcd")
        Write-Host "[run_sim] waveform -> sim\waves\dual_async_fifo_${Test}_seed${Seed}.vcd"
    }
    Remove-Item -Recurse -Force (Join-Path $Lib "waves") -ErrorAction SilentlyContinue
}

# ---- 5) 结果摘要 ----
$txt   = $simOut -join "`n"
$nFail = ([regex]::Matches($txt, "\[FAIL\]")).Count
$pass  = ([regex]::Matches($txt, "\*\*\* PASS \*\*\*")).Count
$fail  = ([regex]::Matches($txt, "\*\*\* FAIL \*\*\*")).Count
$tmo   = ([regex]::Matches($txt, "\*\*\* TIMEOUT \*\*\*")).Count
$cov   = [regex]::Match($txt, "FUNCTIONAL COVERAGE = ([\d\.]+)%")
$bins  = [regex]::Match($txt, "\((\d+)/(\d+) bin\)")

Write-Host ""
Write-Host "[run_sim] TEST=$Test  SEED=$Seed  STAGES=$Stages"
Write-Host "[run_sim] failed checks    : $nFail"
if ($bins.Success) { Write-Host "[run_sim] coverage bins    : $($bins.Groups[1].Value)/$($bins.Groups[2].Value)" }
if ($cov.Success)  { Write-Host "[run_sim] functional cover.: $($cov.Groups[1].Value) percent" }
Write-Host "[run_sim] log -> $logFile"

if ($simExit -ne 0 -or $nFail -gt 0 -or $fail -gt 0 -or $tmo -gt 0) { Write-Host "[run_sim] RESULT: *** FAIL ***"; exit 1 }
elseif ($pass -gt 0)             { Write-Host "[run_sim] RESULT: *** PASS ***"; exit 0 }
else                             { Write-Host "[run_sim] RESULT: no result marker in log"; exit 1 }

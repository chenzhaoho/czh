# run_vivado_syn.tcl -- synthesis + implementation + area/timing reports
# usage: vivado -mode batch -source run_vivado_syn.tcl -tclargs <top> <outdir> <generic>
#
# IMPORTANT implementation notes (learned from earlier failed attempts):
#   1. pure-ASCII comments only: Vivado's Tcl reads this file as ANSI on a
#      Chinese-locale Windows; UTF-8 Chinese comments abort the parser.
#   2. NO line-continuation backslashes: use lappend instead (a CRLF read
#      breaks trailing-backslash continuation).
#   3. get_modules is NOT a Vivado command -- do not use it.
#   4. the raw top level has ~1262 ports (all debug counters exposed), far
#      beyond the 210 user I/O of xc7a35tcsg324, so place_design fails with
#      IO overutilization. Therefore implementation runs on a thin wrapper
#      (syn_wrap_dual / syn_wrap_single) that keeps only the real datapath
#      ports and sinks the debug bus into a keep-register.

set TOP     [lindex $argv 0]
set OUTDIR  [lindex $argv 1]
set PNAME   [lindex $argv 2]
set PVAL    [lindex $argv 3]
set ROOT [file dirname [file dirname [file normalize [info script]]]]

# generic override is passed as two separate argv entries because
# cmd/PowerShell strips "=VALUE" when forwarding "NAME=VALUE" to vivado.bat
set PNAME2 [lindex $argv 4]
set PVAL2  [lindex $argv 5]

# generic overrides: up to two name=value pairs, each passed as two argv
# entries because cmd/PowerShell strips "=VALUE" from a single token
set GENERIC ""
set GEN_ARGS [list]
if {$PNAME ne "" && $PVAL ne ""} {
    lappend GEN_ARGS -generic "$PNAME=$PVAL"
    set GENERIC "$PNAME=$PVAL"
}
if {$PNAME2 ne "" && $PVAL2 ne ""} {
    lappend GEN_ARGS -generic "$PNAME2=$PVAL2"
    append GENERIC " $PNAME2=$PVAL2"
}

if {$TOP eq ""} { puts "FATAL: missing top module"; exit 1 }
if {$OUTDIR eq ""} { puts "FATAL: missing outdir"; exit 1 }

set OUTDIR [string map {\\ /} $OUTDIR]
file mkdir $OUTDIR
cd $OUTDIR
puts "INFO: top=$TOP outdir=$OUTDIR generic='$GENERIC'"

# ---------------------------------------------------------------- sources
set RTL {}
foreach source {
    rtl/common/gray_codec.v rtl/common/sync_2ff.v rtl/common/sync_gray_bus.v
    rtl/common/rst_sync.v rtl/fifo/async_fifo.v rtl/fifo/fifo_a.v rtl/fifo/fifo_b.v
    rtl/top/monitor.v rtl/top/dual_async_fifo_top.v syn/syn_wrap_dual.v syn/syn_wrap_single.v
} {
    lappend RTL [file join $ROOT $source]
}
read_verilog {*}$RTL
puts "INFO: read_verilog done"

# ---------------------------------------------------------------- synthesis
if {[llength $GEN_ARGS] > 0} {
    puts "INFO: synth_design with $GEN_ARGS"
    set rc [catch {synth_design -top $TOP -part xc7a35tcsg324-1 {*}$GEN_ARGS -flatten_hierarchy rebuilt} msg]
} else {
    puts "INFO: synth_design with default parameters"
    set rc [catch {synth_design -top $TOP -part xc7a35tcsg324-1 -flatten_hierarchy rebuilt} msg]
}
if {$rc} {
    puts "FATAL: synth_design failed: $msg"
    exit 1
}
puts "INFO: synthesis OK"

# ---------------------------------------------------------------- clocks
if {$TOP eq "syn_wrap_single"} {
    create_clock -period 10.000 -name wr_clk [get_ports wr_clk]
    create_clock -period 6.000  -name rd_clk [get_ports rd_clk]
    create_clock -period 5.000  -name clk_mon [get_ports clk_mon]
    set_clock_groups -asynchronous -group {wr_clk} -group {rd_clk} -group {clk_mon}
} else {
    create_clock -period 10.000 -name wr_clk_a [get_ports wr_clk_a]
    create_clock -period 6.000  -name rd_clk_a [get_ports rd_clk_a]
    create_clock -period 14.000 -name wr_clk_b [get_ports wr_clk_b]
    create_clock -period 4.000  -name rd_clk_b [get_ports rd_clk_b]
    create_clock -period 5.000  -name clk_mon  [get_ports clk_mon]
    set_clock_groups -asynchronous -group {wr_clk_a} -group {rd_clk_a} -group {wr_clk_b} -group {rd_clk_b} -group {clk_mon}
}
set_false_path -from [get_ports rst_n_async]
# dbg_sig is the observation checksum that keeps the statistic logic alive for
# realistic area/timing. It is NOT a functional datapath, so exclude it from
# timing analysis to keep the reported slack meaningful.
# The sink register dbg_sig_r is the real endpoint (the port is a straight
# wiring of it), so exclude its D pins rather than the port.
set dbg_pins [get_pins -quiet -hierarchical -filter {NAME =~ *dbg_sig_r_reg*/D}]
if {[llength $dbg_pins] > 0} {
    set_false_path -to $dbg_pins
    puts "INFO: excluded [llength $dbg_pins] observation-sink pins from timing"
}

write_checkpoint -force post_synth.dcp
report_utilization -hierarchical -file util_synth.rpt
report_timing_summary -max_paths 10 -file timing_synth.rpt
puts "INFO: post-synth reports written"

# ---------------------------------------------------------------- implementation
set rc [catch {opt_design} msg]
if {$rc} { puts "FATAL: opt_design failed: $msg"; exit 1 }
set rc [catch {place_design} msg]
if {$rc} { puts "FATAL: place_design failed: $msg"; exit 1 }
set rc [catch {route_design} msg]
if {$rc} { puts "FATAL: route_design failed: $msg"; exit 1 }
puts "INFO: implementation OK"

write_checkpoint -force post_route.dcp
report_utilization -hierarchical -file util_route.rpt
report_timing_summary -max_paths 10 -path_type summary -file timing_route.rpt
report_clock_utilization -file clock_util.rpt
report_power -file power.rpt
puts "INFO: all reports written"

puts "SYN_DONE top=$TOP generic=$GENERIC outdir=$OUTDIR"

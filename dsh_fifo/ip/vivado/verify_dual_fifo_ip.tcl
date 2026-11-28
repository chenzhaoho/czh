# Usage: vivado -mode batch -source ip/vivado/verify_dual_fifo_ip.tcl -tclargs build/ip_repo build/ip_verify
if {$argc < 2 || $argc > 3} { error "Expected IP repository, results directory and optional default|compact|bram|bram_compact profile" }
set profiles {default compact bram bram_compact}
if {$argc == 3} {
    set selection [lindex $argv 2]
    if {$selection ni $profiles} { error "Unknown profile $selection" }
    set profiles [list $selection]
}
set repo [file normalize [lindex $argv 0]]
set base [file normalize [lindex $argv 1]]
set example [file join [file dirname [file normalize [info script]]] example]
source [file join [file dirname $example] audit_reports.tcl]
set results [file join $base run-[clock seconds]-[pid]]
file mkdir $results
set_param general.maxThreads 4

proc complete_run {run} {
    wait_on_run $run
    if {[get_property PROGRESS [get_runs $run]] ne "100%" || ![string match "*Complete*" [get_property STATUS [get_runs $run]]]} {
        error "$run failed: [get_property STATUS [get_runs $run]]"
    }
}

proc audit_pointers {folder aw stages {budget 10.0}} {
    set expected [expr {$aw+1}]
    set audit [open [file join $folder gray_paths.tsv] w]
    puts $audit "fifo\tpointer\tstages\tsource\tendpoint\trequirement_ns\tslack_ns\tstage_min_setup_ns"
    foreach fifo {u_ab u_ba} {
        foreach ptr {wr rd} {
            set source_re [format {(.*/)?%s/%s_gray_reg\[[0-9]+\]} $fifo $ptr]
            set dest_re [format {(.*/)?%s/u_sync_%s_ptr/sync_chain_reg\[0\]\[[0-9]+\]} $fifo $ptr]
            set chain_re [format {(.*/)?%s/u_sync_%s_ptr/sync_chain_reg\[[0-9]+\]\[[0-9]+\]} $fifo $ptr]
            set sources [get_cells -hier -regexp $source_re]
            set first [get_cells -hier -regexp $dest_re]
            set chain [get_cells -hier -regexp $chain_re -filter {ASYNC_REG == TRUE}]
            if {[llength $sources]!=$expected || [llength $first]!=$expected || [llength $chain]!=$stages*$expected} {
                error "Incomplete $fifo/$ptr: sources=[llength $sources] first=[llength $first] tagged stages=[llength $chain]"
            }
            foreach cell $first {
                set d [get_pins -of_objects $cell -filter {REF_PIN_NAME == D}]
                set paths [get_timing_paths -quiet -from $sources -to $d -max_paths 1]
                if {[llength $paths]!=1} { error "Unconstrained or cut Gray path to $d" }
                set path [lindex $paths 0]
                set src [get_property STARTPOINT_PIN $path]
                regexp {\[0\]\[(\d+)\]$} $cell -> bit
                if {![regexp {\[(\d+)\]/C$} $src -> source_bit] || $source_bit!=$bit} {
                    error "Gray bit changed index: $src -> $d"
                }
                set bound [get_property REQUIREMENT $path]
                set slack [get_property SLACK $path]
                if {![string match "*MaxDelay*datapath_only*" [get_property EXCEPTION $path]] ||
                    abs($bound-$budget)>0.001 || $slack<0} {
                    error "Missing or failing $budget ns datapath-only constraint to $d"
                }
                set stage_slacks {}
                set prev $cell
                for {set index 1} {$index<$stages} {incr index} {
                    set next [get_cells [string map [list "\[0\]\[$bit\]" "\[$index\]\[$bit\]"] [get_property NAME $cell]]]
                    set step [get_timing_paths -quiet -from $prev -to [get_pins -of_objects $next -filter {REF_PIN_NAME == D}]]
                    if {[llength $step]!=1 || [get_property STARTPOINT_CLOCK $step] ne [get_property ENDPOINT_CLOCK $step] ||
                        [get_property EXCEPTION $step] ne "" || [get_property SLACK $step]<0} {
                        error "Missing same-clock timing between synchronization stages: $prev -> $next"
                    }
                    lappend stage_slacks [get_property SLACK $step]
                    set prev $next
                }
                puts $audit "$fifo\t$ptr\t$stages\t$src\t$d\t$bound\t$slack\t[lindex [lsort -real $stage_slacks] 0]"
            }
        }
    }
    close $audit
}

# Re-time the routed compact fixture under a faster and a slower setting of
# the same input. Clear the original limits so a missing constraint fails.
proc audit_clock_modes {folder xdc aw stages read_mode} {
    file mkdir $folder
    reset_timing
    create_clock -name clk_a_fast -period 9 [get_ports clk_a]
    create_clock -add -name clk_a_slow -period 19 [get_ports clk_a]
    create_clock -name clk_b -period 14 [get_ports clk_b]
    set_clock_groups -logically_exclusive -group [get_clocks clk_a_fast] -group [get_clocks clk_a_slow]
    read_xdc -cells link/inst $xdc
    report_exceptions -file [file join $folder exceptions.rpt]
    audit_pointers $folder $aw $stages 9.0
    report_bus_skew -file [file join $folder bus_skew.rpt]
    set skew [audit_skew $folder $aw 9.0]
    set first [get_pins -of_objects [get_cells -hier -regexp {(.*/)?u_ab/u_sync_wr_ptr/sync_chain_reg\[0\]\[0\]}] -filter {REF_PIN_NAME == D}]
    set fp [open [file join $folder clock_modes.tsv] w]
    puts $fp "clock\tpath\trequirement_ns\tslack_ns"
    if {$read_mode == 0} {
        set reverse_ram [get_cells -hier -filter {NAME =~ *u_ba/mem_reg* && IS_PRIMITIVE && REF_NAME =~ RAMD*}]
        set launches [get_pins -of_objects $reverse_ram -filter {REF_PIN_NAME == CLK}]
    }
    foreach clock {clk_a_fast clk_a_slow} {
        set paths [list gray [get_timing_paths -quiet -from [get_clocks $clock] -to $first]]
        if {$read_mode == 0} {
            lappend paths ram [get_timing_paths -quiet -from $launches -to [get_clocks $clock]]
        }
        foreach {name path} $paths {
            if {[llength $path]!=1 || ![string match "*MaxDelay*datapath_only*" [get_property EXCEPTION $path]] ||
                [get_property REQUIREMENT $path]!=9.0 || [get_property SLACK $path]<0} {
                error "Missing or failing $name constraint in timing mode $clock"
            }
            puts $fp "$clock\t$name\t[get_property REQUIREMENT $path]\t[get_property SLACK $path]"
        }
    }
    close $fp
    if {$read_mode == 1} { audit_bram {clk_a_fast clk_a_slow} {clk_b} $read_mode }
    puts "IP_CLOCK_MODES_PASS max_skew_ns=$skew $folder"
}

# Audit the synchronous RAM clocks and their capture paths in the receiver.
proc audit_bram {a_clocks b_clocks read_mode} {
    set memories [get_cells -quiet -hier -filter {IS_PRIMITIVE && REF_NAME =~ RAMB*}]
    if {$read_mode == 0} {
        if {[llength $memories]} { error "Unexpected BRAM in FWFT mode: $memories" }
        return 0
    }
    if {[llength $memories]!=2} { error "Expected one BRAM per direction: $memories" }
    foreach fifo {u_ab u_ba} writes [list $a_clocks $b_clocks] reads [list $b_clocks $a_clocks] {
        set ram [filter $memories "NAME =~ */$fifo/*"]
        if {[llength $ram]!=1} { error "Expected a BRAM for $fifo: $ram" }
        set clock_sets {}
        foreach pin_name {CLKARDCLK CLKBWRCLK} {
            set pin [get_pins -of_objects $ram -filter "REF_PIN_NAME == $pin_name"]
            if {[llength $pin]!=1} { error "Missing $pin_name on $ram" }
            set active [get_clocks -quiet -of_objects $pin]
            lappend clock_sets [lsort [get_property NAME $active]]
        }
        if {[lsort $clock_sets] ne [lsort [list [lsort $writes] [lsort $reads]]]} {
            error "Unexpected clock domains on $ram: $clock_sets"
        }
        set data_pins [get_pins -of_objects $ram -filter {DIRECTION == OUT && REF_PIN_NAME =~ DO*}]
        foreach read_clock $reads {
            set clock [get_clocks $read_clock]
            set path [get_timing_paths -quiet -from $clock -through $data_pins -to $clock]
            if {[llength $path]!=1 || [get_property EXCEPTION $path] ne "" ||
                [get_property SLACK $path]<0} {
                error "Missing or failing local BRAM data path from $ram in $read_clock"
            }
        }
    }
    return [llength $memories]
}

proc verify_config {repo example folder dw aw stages ooc read_mode} {
    file mkdir $folder
    create_project consumer [file join $folder prj] -part xc7a35tcsg324-1
    set_property ip_repo_paths [list $repo] [current_project]
    update_ip_catalog
    set vlnv chenzhaoho:user:dual_fifo_link:1.1
    if {[llength [get_ipdefs -quiet $vlnv]]!=1} { error "IP catalog cannot resolve $vlnv" }
    create_ip -vlnv $vlnv -module_name duplex_i
    set ip [get_ips duplex_i]
    set_property -dict [list CONFIG.DW $dw CONFIG.AW $aw CONFIG.SYNC_STAGES $stages CONFIG.READ_MODE $read_mode] $ip
    set xci [get_files */duplex_i.xci]
    set_property generate_synth_checkpoint $ooc $xci
    generate_target all $ip
    add_files -norecurse [file join $example duplex_example.v]
    add_files -fileset constrs_1 -norecurse [file join $example duplex_example.xdc]
    set_property top duplex_example [current_fileset]
    set_property generic "DW=$dw" [current_fileset]
    update_compile_order -fileset sources_1
    if {$ooc} {
        create_ip_run $xci
        launch_runs duplex_i_synth_1 -jobs 1
        complete_run duplex_i_synth_1
    }
    launch_runs synth_1 -jobs 1
    complete_run synth_1
    launch_runs impl_1 -to_step route_design -jobs 1
    complete_run impl_1
    open_run impl_1

    report_timing_summary -report_unconstrained -file [file join $folder timing.rpt]
    report_utilization -file [file join $folder utilization.rpt]
    report_exceptions -file [file join $folder exceptions.rpt]
    report_bus_skew -file [file join $folder bus_skew.rpt]
    report_route_status -file [file join $folder route.rpt]
    report_cdc -details -file [file join $folder cdc.rpt]
    check_timing -verbose -file [file join $folder check_timing.rpt]
    audit_pointers $folder $aw $stages
    set routed [audit_routing $folder]
    set skew [audit_skew $folder $aw]
    set cdc [audit_cdc $folder $dw $aw $stages $read_mode]
    set brams [audit_bram {clk_a} {clk_b} $read_mode]
    set setup [get_property SLACK [get_timing_paths -delay_type max]]
    set hold [get_property SLACK [get_timing_paths -delay_type min]]
    if {![string is double -strict $setup] || ![string is double -strict $hold] || $setup<0 || $hold<0} {
        error "Timing did not close: setup=$setup hold=$hold"
    }
    if {!$ooc} {
        set scoped_xdc [file join $repo dual_fifo_link_1_1 src dual_fifo_link.xdc]
        audit_clock_modes [file join $folder clock_modes] $scoped_xdc $aw $stages $read_mode
    }
    set fp [open [file join $folder result.txt] w]
    puts $fp "DW=$dw AW=$aw SYNC_STAGES=$stages OOC=$ooc READ_MODE=$read_mode SETUP_NS=$setup HOLD_NS=$hold"
    puts $fp "ROUTED_NETS=$routed GRAY_BITS=[expr {4*($aw+1)}] MAX_BUS_SKEW_NS=$skew BRAM_COUNT=$brams CDC=$cdc"
    close $fp
    close_project
    puts "IP_IMPLEMENTATION_PASS DW=$dw AW=$aw SYNC_STAGES=$stages READ_MODE=$read_mode setup=$setup hold=$hold"
}

puts "RESULTS $results"
foreach {profile dw aw stages ooc mode} {default 32 8 2 1 0
                                          compact 16 6 3 0 0
                                          bram 32 8 2 1 1
                                          bram_compact 16 6 3 0 1} {
    if {$profile in $profiles} {
        verify_config $repo $example [file join $results $profile] $dw $aw $stages $ooc $mode
    }
}
puts "IP_CONSUMER_PASS profiles={$profiles} $results"

# Audit the routed reference example using the Vivado 2020.2 report format.
proc report_text {folder name} {
    set fp [open [file join $folder ${name}.rpt] r]
    set body [read $fp]
    close $fp
    return $body
}

proc audit_routing {folder} {
    set route [report_text $folder route]
    foreach {key field} {routable {routable nets} routed {fully routed nets} errors {nets with routing errors}} {
        set pattern [format {# of %s\.+\s*:\s*(\d+)} $field]
        if {![regexp $pattern $route -> count]} { error "Missing route count: $field" }
        set nets($key) $count
    }
    if {$nets(routable) == 0 || $nets(routed) != $nets(routable) || $nets(errors) != 0} {
        error "Incomplete routing in $folder"
    }

    set checks [report_text $folder check_timing]
    foreach name {no_clock constant_clock pulse_width_clock unconstrained_internal_endpoints
                  multiple_clock generated_clocks loops partial_input_delay
                  partial_output_delay latch_loops} {
        if {![regexp [format {checking %s \(0\)} $name] $checks]} { error "check_timing failed: $name" }
    }
    if {![regexp {checking no_input_delay \(1\)} $checks] ||
        ![regexp {(?m)^rst_n_async\s*$} $checks]} { error "Expected only the external asynchronous reset exception" }
    if {![regexp {checking no_output_delay \(2\)} $checks] ||
        ![string match "*0 ports with no output delay specified*" $checks] ||
        ![string match "*2 ports with no output delay but with a timing clock defined*" $checks] ||
        ![regexp {(?m)^activity_clk_a$} $checks] || ![regexp {(?m)^activity_clk_b$} $checks]} {
        error "Only the two forwarded clocks may be reported as outputs without data delays"
    }
    return $nets(routed)
}

proc audit_skew {folder aw {budget 10.0}} {
    set counts {}
    set width [expr {$aw+1}]
    set worst 0.0
    foreach line [split [report_text $folder bus_skew] "\n"] {
        if {[regexp {^set_bus_skew .*?/(u_ab|u_ba)/(wr|rd)_gray_reg} $line -> fifo ptr]} {
            set key $fifo/$ptr
            if {[dict exists $counts $key]} { error "Repeated skew group $key" }
            dict set counts $key 0
        } elseif {[regexp {^Endpoints:\s*(\d+)} $line -> bits]} {
            if {$bits!=$width} { error "Wrong number of skew endpoints: $bits" }
            dict incr counts $key
        } elseif {[regexp {^Requirement:\s*([0-9.]+)ns} $line -> ns]} {
            if {$ns!=$budget} { error "Unexpected example skew budget: $ns (expected $budget)" }
            dict incr counts $key
        } elseif {[regexp {^Slack \(([^)]+)\)\s*:\s*([-0-9.]+)ns} $line -> status slack]} {
            if {$status ne "MET" || $slack<0} { error "Bus skew failed: $line" }
            set worst [expr {max($worst,$budget-$slack)}]
            dict incr counts $key
        }
    }
    foreach key {u_ab/wr u_ab/rd u_ba/wr u_ba/rd} {
        if {![dict exists $counts $key] || [dict get $counts $key]!=3} { error "Missing skew evidence for $key" }
    }
    return [format %.3f $worst]
}

proc audit_cdc {folder dw aw stages read_mode} {
    set reported [dict create]
    set counted [dict create]
    set seen [dict create]
    foreach line [split [report_text $folder cdc] "\n"] {
        if {[regexp {^(CDC-\d+)\s+\S+\s+(\d+)\s+} $line -> id count]} {
            dict set reported $id $count
        }
        if {![regexp {^\s*\d+\s+(CDC-\d+)\s+(\S+)} $line -> id severity]} { continue }
        set pins [regexp -all -inline {\S+} $line]
        set src [lindex $pins end-1]
        set dst [lindex $pins end]
        switch -- $id {
            CDC-6 {
                if {$severity ne "Warning" || ![regexp {\s(\d+)\s+Max Delay Datapath Only\s} $line -> depth] ||
                    $depth!=$stages ||
                    ![regexp {/(u_ab|u_ba)/(wr|rd)_gray_reg\[(\d+):0\]/C$} $src -> fifo ptr hi] || $hi!=$aw ||
                    ![string match [format {*/%s/u_sync_%s_ptr/*} $fifo $ptr] $dst] ||
                    ![regexp {sync_chain_reg\[0\]\[(\d+):0\]/D$} $dst -> hi] || $hi!=$aw} {
                    error "Unclassified Gray crossing: $line"
                }
                set endpoint "$id/$fifo/$ptr"
            }
            CDC-15 {
                if {$severity ne "Warning" || ![string match "*Max Delay Datapath Only*" $line] ||
                    ![regexp {/(u_ab|u_ba)/mem_reg[^ ]*/CLK$} $src -> fifo]} { error "Unclassified RAM launch: $line" }
                set port [expr {$fifo eq "u_ab" ? "b" : "a"}]
                if {[regexp {/(u_ab|u_ba)/g_read_fwft\.last_popped_reg\[(\d+)\]/D$} $dst -> receiver bit] && $receiver eq $fifo} {
                    set sink retained
                } elseif {[regexp {^sample_([ab])_reg\[(\d+)\]/D$} $dst -> receiver bit] && $receiver eq $port} {
                    set sink consumer
                } else { error "Unclassified RAM capture: $line" }
                if {$bit >= $dw} { error "RAM capture outside configured word: $line" }
                set endpoint "$id/$fifo/$sink/$bit"
            }
            CDC-9 {
                if {$severity ne "Info" || $src ne "rst_n_async" ||
                    ![regexp {\s(\d+)\s+False Path\s+} $line -> depth] || $depth!=$stages ||
                    ![regexp {/(u_rst_[ab]|u_rst_sync_(wr|rd))/sync_chain_reg\[0\]/(CLR|PRE)$} $dst]} {
                    error "Unclassified reset crossing: $line"
                }
                set endpoint "$id/$dst"
            }
            default { error "Unexpected CDC finding: $line" }
        }
        if {[dict exists $seen $endpoint]} { error "Duplicate CDC endpoint: $endpoint" }
        dict set seen $endpoint 1
        dict incr counted $id
    }
    set categories [expr {$read_mode == 0 ? 3 : 2}]
    if {[dict size $reported]!=$categories || [dict size $counted]!=$categories} {
        error "Missing or unexpected CDC categories: $reported"
    }
    dict for {id n} $reported {
        if {![dict exists $counted $id] || [dict get $counted $id]!=$n} { error "Incomplete CDC evidence for $id" }
    }
    set expected_ram_crossings [expr {$read_mode == 0 ? 4*$dw : 0}]
    set ram_crossings 0
    if {[dict exists $counted CDC-15]} { set ram_crossings [dict get $counted CDC-15] }
    if {[dict get $counted CDC-6]!=4 || $ram_crossings!=$expected_ram_crossings || [dict get $counted CDC-9]<2} {
        error "Incomplete crossings: $counted"
    }
    return $counted
}

# Private loopback bridge. Only a fixed command set is accepted: no client eval.
set live_fields {
    tx_a tx_b rx_a rx_b atu btu aru bru af bf at bt av bv ax bx ar br
    pending_a pending_b stalls_a stalls_b errors
    dut/u_ab/wr_bin dut/u_ab/rd_bin dut/u_ab/wr_gray dut/u_ab/rd_gray
    dut/u_ba/wr_bin dut/u_ba/rd_bin dut/u_ba/wr_gray dut/u_ba/rd_gray
    dut/u_ab/wr_gray_sync dut/u_ab/rd_gray_sync dut/u_ba/wr_gray_sync dut/u_ba/rd_gray_sync
    ad bd aq bq clk_a clk_b
}
set live_load_a 0
set live_load_b 0
if {![info exists live_gui]} {set live_gui 0}
set live_log [open "simulator_commands.log" w]
fconfigure $live_log -buffering line -encoding ascii
proc live_note {text} {
    global live_log
    set line "LIVE $text"
    puts $live_log $line
    flush $live_log
    puts stdout $line
    flush stdout
}
proc live_refresh_wave {} {
    global live_gui
    if {$live_gui} {
        set end_ns [expr {$::now/1000.0}]
        set start_ns [expr {max(0.0,$end_ns-2000.0)}]
        if {[catch {wave zoom range ${start_ns}ns ${end_ns}ns} problem]} {
            live_note "WAVE_ERROR $problem"
        }
    }
}
proc live_state {} {
    global live_fields
    set answer [list [string map {" " "_"} $::now]]
    foreach field $live_fields { lappend answer [examine -radix unsigned /tb_terminal_live/$field] }
    return [join $answer " "]
}
proc live_command {channel} {
    global live_load_a live_load_b
    if {[eof $channel]} { close $channel; return }
    if {[gets $channel line]<0} { return }
    set words [split $line " "]
    set id [lindex $words 0]
    set operation [lindex $words 1]
    if {![string is integer -strict $id]} {close $channel;return}
    live_note "CMD #$id sim_ps=$::now [join [lrange $words 1 end] { }]"
    if {$operation eq "QUIT"} {
        live_note "ACK #$id QUIT sim_ps=$::now stopping"
        puts $channel "OK $id goodbye";flush $channel
        after 0 {quit -force}
        return
    }
    if {[catch {
        switch -- $operation {
            STATUS {}
            STEP {
                set duration [lindex $words 2]
                if {![string is integer -strict $duration] || $duration<1 || $duration>100000} {error "bad_duration"}
                run $duration ns
            }
            RECEIVE {
                set side [lindex $words 2];set enabled [lindex $words 3]
                if {$side ni {a b} || $enabled ni {0 1}} {error "bad_receive"}
                force -deposit /tb_terminal_live/receive_$side $enabled
                run 40 ns
            }
            LOAD {
                set side [lindex $words 2];set count [lindex $words 3]
                if {$side ni {a b} || ![string is integer -strict $count] || $count<1 || $count>4096} {error "bad_load"}
                incr live_load_$side
                force -deposit /tb_terminal_live/count_$side [format "32'd%d" $count]
                force -deposit /tb_terminal_live/load_$side [format "32'd%d" [set live_load_$side]]
                run 40 ns
            }
            RESET {
                force -deposit /tb_terminal_live/rst_n 0
                run 140 ns
                force -deposit /tb_terminal_live/receive_a 1
                force -deposit /tb_terminal_live/receive_b 1
                force -deposit /tb_terminal_live/rst_n 1
                run 280 ns
            }
            FLUSH {vcd flush}
            default {error "unknown_operation"}
        }
        set result [live_state]
        if {$operation in {STEP RECEIVE LOAD RESET}} {live_refresh_wave}
    } problem]} {
        live_note "ERROR #$id $operation $problem"
        puts $channel "ERROR $id [string map {" " "_" "\n" "_"} $problem]"
    } else {
        live_note "ACK #$id $operation sim_ps=$::now AB\[W=[examine -radix unsigned /tb_terminal_live/tx_a],R=[examine -radix unsigned /tb_terminal_live/rx_b]\] BA\[W=[examine -radix unsigned /tb_terminal_live/tx_b],R=[examine -radix unsigned /tb_terminal_live/rx_a]\]"
        puts $channel "OK $id $result"
    }
    flush $channel
}
proc live_connect {channel address port} {
    fconfigure $channel -blocking 0 -buffering line -translation lf -encoding ascii
    fileevent $channel readable [list live_command $channel]
}
if {$live_gui} {
    view transcript
    do wave_terminal_live.do
    live_note "GUI_READY native Transcript/Wave, same live tb_terminal_live instance"
}
run 140 ns
force -deposit /tb_terminal_live/rst_n 1
run 280 ns
set listener [socket -server live_connect -myaddr 127.0.0.1 0]
set port [lindex [fconfigure $listener -sockname] 2]
set out [open "bridge.port" w];puts $out $port;close $out
puts "LIVE_BRIDGE_READY $port"
live_note "READY port=$port gui=$live_gui sim_ps=$::now"
live_refresh_wave
vwait live_shutdown

# vivado -mode batch -source ip/vivado/package_dual_fifo_ip.tcl -tclargs build/ip_repo
if {$argc != 1} { error "Expected an output IP repository directory" }
set here [file dirname [file normalize [info script]]]
set root [file dirname [file dirname $here]]
set repo [file normalize [lindex $argv 0]]
set dest [file join $repo dual_fifo_link_1_1]
file mkdir $repo
set scratch [file join [file dirname $repo] .pack-[pid]-[clock clicks]]
file mkdir $scratch
set stage [file join $scratch dual_fifo_link_1_1]
set token ".generated-dual-fifo-ip"

proc add_interface_parameter {iface name value} {
    set item [ipx::get_bus_parameters $name -of_objects $iface]
    if {![llength $item]} { set item [ipx::add_bus_parameter $name $iface] }
    set_property value $value $item
}

proc make_package {root here scratch stage} {
    create_project pack [file join $scratch project] -part xc7a35tcsg324-1
    set fp [open [file join $root ip rtl_sources.f] r]
    set files [split [string trim [read $fp]] "\n"]
    close $fp
    foreach rel $files { add_files -norecurse [file join $root [string trim $rel]] }
    set_property top dual_fifo_link [current_fileset]
    foreach xdc {dual_fifo_link.xdc dual_fifo_ooc.xdc} {
        add_files -fileset constrs_1 -norecurse [file join $here $xdc]
    }
    set timing [get_files */dual_fifo_link.xdc]
    set_property PROCESSING_ORDER LATE $timing
    set_property USED_IN {implementation} $timing
    set_property USED_IN {synthesis out_of_context} [get_files */dual_fifo_ooc.xdc]
    update_compile_order -fileset sources_1

    ipx::package_project -root_dir $stage -vendor chenzhaoho -library user -taxonomy /UserIP -import_files -set_current true
    set core [ipx::current_core]
    set_property name dual_fifo_link $core
    set_property version 1.1 $core
    set_property core_revision 1 $core
    set_property display_name {Duplex asynchronous FIFO} $core
    set_property description {Two independent ready/valid streams with FWFT LUTRAM or synchronous block RAM.} $core
    set_property supported_families {artix7 Production} $core
    foreach {name choices} {AW {6 8} DW {16 32} SYNC_STAGES {2 3} READ_MODE {0 1}} {
        set item [ipx::get_user_parameters $name -of_objects $core]
        set_property value_validation_type list $item
        set_property value_validation_list $choices $item
    }
    foreach pin {clk_a clk_b rst_n_async} {
        set addr [expr {$pin eq "rst_n_async" ? "reset" : "clock"}]
        if {![llength [ipx::get_bus_interfaces $pin -of_objects $core]]} {
            ipx::infer_bus_interface $pin xilinx.com:signal:${addr}_rtl:1.0 $core
        }
        set iface [ipx::get_bus_interfaces $pin -of_objects $core]
        if {$addr eq "reset"} {
            add_interface_parameter $iface POLARITY ACTIVE_LOW
        } else {
            add_interface_parameter $iface ASSOCIATED_RESET rst_n_async
        }
    }
    ipx::create_xgui_files $core
    ipx::update_checksums $core
    ipx::check_integrity $core
    ipx::save_core $core
    close_project
}

if {[catch {
    make_package $root $here $scratch $stage
    close [open [file join $stage $token] w]
    # Replace only a previous package produced by this script.
    if {[file exists $dest]} {
        if {![file isfile [file join $dest $token]]} { error "Unrelated output already exists: $dest" }
        file rename $dest [file join $scratch previous]
    }
    if {[catch {file rename $stage $dest} rename_error]} {
        if {[file exists [file join $scratch previous]]} { file rename [file join $scratch previous] $dest }
        error $rename_error
    }
} message]} {
    puts stderr "Packaging failed: $message (diagnostics in $scratch)"
    exit 1
}
file delete -force $scratch
puts "IP_PACKAGE_PASS chenzhaoho:user:dual_fifo_link:1.1 $dest"

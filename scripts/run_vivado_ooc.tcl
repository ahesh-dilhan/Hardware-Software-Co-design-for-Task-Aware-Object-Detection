# Reproducible out-of-context implementation flow for standalone RTL blocks.
#
# Usage:
#   vivado -mode batch -source scripts/run_vivado_ooc.tcl -tclargs \
#     <top> <run-name> <clock-port> <generic-or-dash> <source> [source ...]
#
# Example:
#   vivado -mode batch -source scripts/run_vivado_ooc.tcl -tclargs \
#     systolic_gemm systolic_n16 clk_i N=16 rtl/systolic/systolic_gemm.sv
#
# Reports and the routed checkpoint are generated below build/vivado/, which
# is intentionally ignored by Git.  Commit only a reviewed result summary.

if {$argc < 5} {
    puts stderr "ERROR: expected top, run-name, clock-port, generic-or-dash, and source file(s)"
    exit 2
}

set top_name       [lindex $argv 0]
set run_name       [lindex $argv 1]
set clock_port     [lindex $argv 2]
set generic_value  [lindex $argv 3]
set source_files   [lrange $argv 4 end]

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
set output_dir [file join $repo_root build vivado $run_name]
set part_name  "xc7k325tffg900-2"
set period_ns  6.667

file mkdir $output_dir
set_param general.maxThreads 8

foreach relative_source $source_files {
    set source_path [file normalize [file join $repo_root $relative_source]]
    if {![file exists $source_path]} {
        puts stderr "ERROR: source does not exist: $source_path"
        exit 2
    }
    read_verilog -sv $source_path
}

set synth_arguments [list \
    synth_design \
    -top $top_name \
    -part $part_name \
    -mode out_of_context \
    -flatten_hierarchy rebuilt]

if {$generic_value ne "-"} {
    lappend synth_arguments -generic $generic_value
}

puts "INFO: synthesizing $top_name as $run_name for $part_name"
puts "INFO: generic override: $generic_value"
eval $synth_arguments

set clock_objects [get_ports -quiet $clock_port]
if {[llength $clock_objects] != 1} {
    puts stderr "ERROR: expected exactly one clock port named $clock_port"
    exit 2
}

create_clock -name core_clock -period $period_ns $clock_objects
set_clock_uncertainty 0.200 [get_clocks core_clock]

opt_design
place_design
phys_opt_design
route_design

report_utilization \
    -file [file join $output_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 \
    -file [file join $output_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -max_paths 10 \
    -report_unconstrained \
    -file [file join $output_dir timing_summary.rpt]
report_methodology \
    -file [file join $output_dir methodology.rpt]
report_drc \
    -file [file join $output_dir drc.rpt]
write_checkpoint -force [file join $output_dir routed.dcp]

set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_paths  [get_timing_paths -quiet -delay_type min -max_paths 1]
set summary_file [open [file join $output_dir run_summary.txt] w]
puts $summary_file "run=$run_name"
puts $summary_file "top=$top_name"
puts $summary_file "part=$part_name"
puts $summary_file "period_ns=$period_ns"
puts $summary_file "clock_port=$clock_port"
puts $summary_file "generic=$generic_value"
puts $summary_file "vivado_version=[version -short]"
if {[llength $setup_paths] > 0} {
    puts $summary_file "worst_setup_slack_ns=[get_property SLACK [lindex $setup_paths 0]]"
}
if {[llength $hold_paths] > 0} {
    puts $summary_file "worst_hold_slack_ns=[get_property SLACK [lindex $hold_paths 0]]"
}
close $summary_file

puts "INFO: completed routed out-of-context run: $run_name"
puts "INFO: reports: $output_dir"

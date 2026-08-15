open_project -reset dcse_hls_project
set_top dcse_top
add_files src/dcse_top.cpp -cflags "-Isrc"
add_files -tb tb/dcse_tb.cpp -cflags "-Isrc"
open_solution -reset "solution1"
set_part xc7k325tffg900-2
create_clock -period 6.667 -name default
csim_design -clean
if {[info exists ::env(HLS_CSIM_ONLY)] && $::env(HLS_CSIM_ONLY) eq "1"} {
    puts "HLS_CSIM_ONLY=1: C simulation passed; skipping synthesis."
    exit
}
csynth_design
puts "================================================================"
puts "Done. Report: dcse_hls_project/solution1/syn/report/dcse_top_csynth.rpt"
puts "Review the generated report for achieved timing, latency, and resources."
puts "No timing or utilization result is claimed until it appears in that report."
puts "================================================================"
exit

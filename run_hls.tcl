open_project dcse_hls_project
set_top dcse_top
add_files src/dcse_top.cpp
add_files -tb tb/dcse_tb.cpp
open_solution "solution1" -flow_target vivado
set_part xc7k325tffg900-2
create_clock -period 6.667 -name default
set_directive_pipeline  "dcse_top/mcp_systolic/ROWS/COLS" -II 1
set_directive_unroll    "dcse_top/mcp_systolic/ROWS/COLS/OUT_CH"
set_directive_dataflow  "dcse_top"
csim_design -clean
csynth_design
puts "================================================================"
puts "Done. Report: dcse_hls_project/solution1/syn/report/dcse_top_csynth.rpt"
puts "Targets: DSP<=288  BRAM<=14.6Mb  LUT<=15000  Period<=6.667ns"
puts "================================================================"
exit

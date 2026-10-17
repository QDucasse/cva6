# Out-of-context synthesis, placement and routing of the CVA6 core (module
# cva6) for area and timing figures.
#
# vivado -mode batch -source util/synth_ooc.tcl -tclargs \
#     <repo> <target config> <part> <clock period in ns> <output dir> [define=value ...]
#
# The sources come from core/Flist.cva6 of <repo>. The extra arguments are
# Verilog defines, for instance JITDOMAIN_NR_DOMAINS=4. Reports go to
# <output dir>: utilization.rpt, timing_summary.rpt and summary.txt.

lassign $argv repo target part period outdir
set defines [lrange $argv 5 end]

set_param general.maxThreads 8
file mkdir $outdir

set vars [dict create \
  CVA6_REPO_DIR $repo \
  HPDCACHE_DIR $repo/core/cache_subsystem/hpdcache \
  TARGET_CFG $target]

proc expand {line vars} {
  dict for {name value} $vars { set line [string map [list "\${$name}" $value] $line] }
  return $line
}

# Flist syntax: one file per line, +incdir+<dir>, -F <nested list>, // comments
proc read_flist {path vars files_var incdirs_var} {
  upvar $files_var files
  upvar $incdirs_var incdirs
  set fh [open $path r]
  foreach raw [split [read $fh] "\n"] {
    set line [string trim [regsub {//.*$} $raw ""]]
    if {$line eq ""} continue
    set line [expand $line $vars]
    if {[string match "+incdir+*" $line]} {
      lappend incdirs [string range $line 8 end]
    } elseif {[string match "-F *" $line]} {
      read_flist [string trim [string range $line 3 end]] $vars files incdirs
    } else {
      lappend files $line
    }
  }
  close $fh
}

set files {}
set incdirs {}
read_flist $repo/core/Flist.cva6 $vars files incdirs
# The SRAMs of the FPGA flow, which Flist.cva6 leaves to the platform
foreach f {
  common/local/util/tc_sram_fpga_wrapper.sv
  vendor/pulp-platform/fpga-support/rtl/SyncSpRamBeNx64.sv
  vendor/pulp-platform/fpga-support/rtl/SyncSpRamBeNx32.sv
  vendor/pulp-platform/fpga-support/rtl/SyncSpRam.sv
} { lappend files $repo/$f }

create_project -in_memory -part $part
read_verilog -sv $files
set_property include_dirs $incdirs [current_fileset]

set xdc $outdir/clock.xdc
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $period \[get_ports clk_i\]"
close $fh
read_xdc -mode out_of_context $xdc

set define_args {}
foreach d $defines { lappend define_args -verilog_define $d }

synth_design -top cva6 -part $part -mode out_of_context {*}$define_args
opt_design
place_design
phys_opt_design
route_design

report_utilization -file $outdir/utilization.rpt
report_timing_summary -file $outdir/timing_summary.rpt

# Summary: resources and timing
set util [report_utilization -return_string]
proc used {util pattern} {
  if {[regexp "\\|\\s*$pattern\\s*\\|\\s*(\[0-9.\]+)" $util -> n]} { return $n }
  return "?"
}
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
set fh [open $outdir/summary.txt w]
puts $fh "defines: $defines"
puts $fh "LUT: [used $util {CLB LUTs\*?}]"
puts $fh "FF: [used $util {CLB Registers}]"
puts $fh "BRAM: [used $util {Block RAM Tile}]"
puts $fh "DSP: [used $util {DSPs}]"
puts $fh "WNS (ns): $wns"
puts $fh [format "Fmax (MHz): %.1f" $fmax]
close $fh

# The capture package may have a newer revision than the saved block design.
# Upgrade before any script validates the BD or calls make_wrapper.
set captures [get_bd_cells -filter {VLNV =~ "fh.local:user:gmax3412_capture:*"}]
if {[llength $captures] != 2} {error "Expected two GMAX capture cells: $captures"}
upgrade_bd_cells $captures
save_bd_design

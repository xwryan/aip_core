# The bridge start inside aip_init_so.tcl performs an initial $stop; VCS UCLI
# then drops the rest of the file being sourced, so keep the assertions in a
# nested script and invoke it through this tiny entry file.
source tests/so_ucli_smoke.tcl

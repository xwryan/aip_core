# Keep this file to the single bridge start: in a simv built without -debug_access+f, UCLI's `run`
# returns from the $stop handshake with Tcl code `return`, which ends only this file, not the parent loader.
_aip_advance bootstrap

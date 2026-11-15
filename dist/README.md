# AIP binary distribution

This directory contains the reproducible Linux x86-64 build entry point and
runtime artifacts for AIP Core. The files below are generated locally by
`dist/Makefile`:

```text
dist/
├── aip_init.tcl                 # text Tcl/UCLI loader entry point
├── aip_init_so.tcl              # runtime loader entry point (binary Tcl bridge)
├── aip_run.tcl                  # startup helper used by aip_init_so.tcl
├── lib/
│   ├── libaip_soload.so         # runtime command-plugin registry
│   ├── libaip_socket_dpi.so     # socket DPI implementation
│   └── libaip_tcl_bridge.so     # binary Tcl/UCLI bridge
├── bin/aip-client
└── include/aip_plugin.h
```

## Build

On a Linux x86-64 host with a GNU C11-compatible compiler, Python 3 and readline
development files installed:

```sh
make -C dist all
```

The four C targets explicitly use `-x c -std=gnu11` to preserve the C ABI and
C11 thread-local storage, even when `CC` defaults to C++ mode. Language
selection resets after each C source so additional object files and archives
can still be linked normally. Changes to this Makefile rebuild these targets;
after changing compiler settings, force a rebuild with `make -C dist -B all`.
If `_Thread_local` or implicit `void *` conversions fail, rerun the failing
compiler command with `-###`: GCC should select `cc1`, while `cc1plus` indicates
C++ mode. Check that the printed build command includes the explicit C flags.

Useful targets are `libs`, `soload`, `socket`, `tcl`, `client`, `test`,
`test-ucli-tcl`, `test-ucli-so`, and `clean`. The Makefile does not embed a
compiler or installation path. When a
different toolchain is needed, override variables on the command line:

```sh
make -C dist clean
make -C dist all CC=clang CFLAGS='-O2 -g' \
    CPPFLAGS='-D_REENTRANT' LDFLAGS='-L/opt/lib'
```

`HOST_ARCH`/`TARGET_ARCH` default to `uname -m`/`x86_64`; a non-x86-64 host is
rejected so an incompatible library is not produced by accident.  A
cross-compiler may override `CC` and `HOST_ARCH` when it is known to emit
x86-64 code.  `READLINE_CFLAGS` and `READLINE_LIBS`
are also overrideable for distributions that install dependencies in a
non-standard prefix.

`make test` runs the Tcl loader and path-resolution contracts when `TCLSH` is available; on a VCS
host that does not put a standalone Tcl shell on `PATH`, it reports a skip.
Set `TCLSH=/path/to/tclsh` to enable that check.

## Loading from a user Tcl script

The text loader exposes the public Tcl/UCLI commands from the AIP distribution:

```tcl
source /path/to/aip_core/dist/aip_init.tcl
```

Initialization is idempotent within one Tcl interpreter. A missing or
unreadable distribution component is reported as an initialization error.

The text loader uses the Tcl interpreter supplied by UCLI and is intended for
interactive or `-do` scripts.

`make -C dist test-ucli-tcl` builds a temporary minimal SV/UCLI executable and
runs a smoke script. It is the quickest way to check the text loader in the
target UCLI environment.

## Loading the binary Tcl/UCLI entry point

`lib/libaip_tcl_bridge.so` provides the same public Tcl/UCLI commands in a
single binary artifact:

```tcl
source /path/to/aip_core/dist/aip_init_so.tcl
```

`aip_init_so.tcl` loads the bridge, performs the required startup handshake, and
sets the same initialization state as `aip_init.tcl`. Only one of the two loaders should be sourced in a
session.

Relative `source` paths resolve from the simulator's working directory. Quote
or brace paths containing spaces. When VCS omits file metadata, the loaders
also inspect literal `source` arguments and try `AIP_CORE/dist`, the working
directory and its `dist` child. For computed paths, set `::env(AIP_CORE)` and use
`source [file join $::env(AIP_CORE) dist aip_init_so.tcl]`. Location errors list
the working directory and searched paths; build the library if it is missing.

The binary loader is intended for `simv -ucli`. Build the simulation with
`-debug_access+r+w+f` for the Tcl bridge and DUT controls; `-debug_access+all`
is a broader alternative. Spell capabilities separately (`+r+w+f`); do not use
`+rwf` as a substitute.

`make -C dist test-ucli-so` builds the library and runs
`simv -ucli -do dist/tests/so_ucli_smoke_entry.tcl` against it.

The binary loader also provides same-session `resume`, `aip_watch`, and
`aip_sim_status`; it does not require a second initialization mechanism. Rebuild
with `make -C dist tcl` after changing the distribution. New scripts can use
ordinary `source` / `-do` without `aip_run_self`. The old AIP bridge-cleanup
command is now `aip_recover`; `resume` belongs to VCS. See
[the main usage guide](../README.md#82-同会话暂停直接续跑与后台观察) for TTY/batch
behavior, pending-request restrictions, and legacy replay compatibility.

While a retained `pause%` is active, ordinary registered commands are routed
through the independent bounded injection queue. Use `aip_submit` to obtain a
ticket and `aip_job status|wait|cancel|release` to manage it. Same registered
bindings are FIFO; different bindings may run concurrently. Results and
parameters are per-ticket, and advancing debug time also advances the original
task and the DUT. TCP does not expose this ticket transport.

The socket bridge starts listening only after its registered, argument-free
`<instance>_listen` command (for example, `c_bridge_listen`) runs through the Tcl
bridge. Source the loader first, then invoke this command. For checkpoint use,
save before the first listen; restore in a new simv process, source the loader
again, then listen. Rolling back within a process that has already listened,
or restoring live sockets or clients, is unsupported: OS file descriptors do
not roll back with simulation state.
After upgrading, run `make -C dist all`, recompile simv and regenerate snapshots.

Successful listening prints a per-simulation 32-bit `auth_key` and the actual
listening port in the simulation log. Multiple simulations on one host may
share `127.0.0.1` by passing port `0`; the kernel selects an unused ephemeral
port during `bind()`. After the client authenticates, commands that are not registered AIP
commands are passed directly to the VCS UCLI Tcl interpreter:

```text
aip-client 127.0.0.1 <actual_port> --key 2876349012
aip_watch tb.dut.link_up 1 stop=0
aip_watch_status 1
aip_sim_status
set ::debug_mode 1
```

The client also accepts `AIP_AUTH_KEY` or prompts for the key when `--key` is
omitted. `aip_watch ... stop=0` only reports a match and continues; `stop=1`
pauses at the UCLI stop point and requires a local `resume`. `aip_watch` is an
immediate registration and does not accept `wait=0`; adding it returns a Tcl
usage error. Simulation-time controls such as `run`, `step` and `resume` should
be entered at the local UCLI prompt. Use this subset with `simv -ucli` after
loading one of the AIP Tcl loaders in that session.

## Linking the C libraries into VCS

For VCS versions that accept external C link flags, pass the distribution
directory through `-LDFLAGS` (the tested VCS command rejects `-sv_lib` as a
`vcs` compile option):

```sh
vcs -sverilog -full64 ... \
  -LDFLAGS "-L/path/to/dist/lib \
             -Wl,-rpath,/path/to/dist/lib \
             -laip_soload -laip_socket_dpi" \
  -o simv_binary ...
```

The plugin ABI is declared in `include/aip_plugin.h`; third-party command
plugins can include that header and export `aip_plugin_init`.

## Simulator-specific extensions

Native simulator extensions are separate from the portable AIP runtime
libraries. If an integration needs one, use the target simulator's supported
startup/link flow and keep it out of the ordinary `aip_init*.tcl` and command
plugin path. The portable distribution does not promise that a native extension
can be loaded as a generic runtime `.so`.

## Full integration example (SV + C libraries + binary Tcl loader)

Verified on VCS W-2024.09 with `-debug_access+r+w+f`, both C libraries linked
and the binary Tcl/UCLI bridge loaded from `libaip_tcl_bridge.so`.

1. Build the artifacts once:

```sh
make -C <aip_core>/dist all
```

   Deliverables: `dist/lib/*.so`, `dist/aip_init_so.tcl`, `dist/aip_run.tcl`,
   `dist/include/aip_plugin.h`, and the AIP SV include package used by the
   testbench.

2. Testbench:

```systemverilog
`include "aip_core_pkg.sv"            // must be the first AIP file in the unit
module tb;
    // register commands: `aip_cmd_task / `aip_cmd_seq / `aip_cmd_cseq / `aip_cmd_creg ...
    `aip_tcl_bridge_create(tcl)                            // UCLI bridge
    `aip_c_bridge_create(c_bridge, "127.0.0.1", 0, "")  // created idle; listen uses a dynamic port
endmodule
```

3. Compile:

```sh
vcs -sverilog -ntb_opts uvm -timescale=1ns/1ps -full64 \
    -debug_access+r+w+f \
    +incdir+<aip_core> +incdir+<aip_core>/src/sv \
    +define+AIP_ENABLE_SOLOAD \
    -LDFLAGS "-L<aip_core>/dist/lib -Wl,-rpath,<aip_core>/dist/lib \
              -laip_soload -laip_socket_dpi -ldl" \
    tb.sv -o simv
```

   - `-debug_access+r+w+f` is required by the Tcl bridge (`get`/`force`);
     spell the options out, `+rwf` does not enable `force`.
   - `+define+AIP_ENABLE_SOLOAD` and `-laip_soload` only when runtime C
     command plugins (`so_load`) are used; `-laip_socket_dpi` only with the
     TCP bridge.
   - `-rpath` lets `simv` find the libraries without `LD_LIBRARY_PATH`.

4. Run:

```tcl
# my_test.tcl
source <aip_core>/dist/aip_init_so.tcl   ;# instead of dist/aip_init.tcl (pick one)
aip_checkpoint base                  ;# save the baseline before opening any listener
c_bridge_listen                       ;# explicitly open the TCP listener
my_cmd a=1 b=2
```

```sh
./simv -ucli -do my_test.tcl
```

   C plugins: `gcc -fPIC -shared my_plugin.c -I<aip_core>/dist/include -o my_plugin.so`,
   then `so_load path=./my_plugin.so` at the UCLI prompt.  TCP client:
   `dist/bin/aip-client 127.0.0.1 <actual_port> --key <auth_key>` in another terminal;
   the key is printed once by the bridge in the simulation log.

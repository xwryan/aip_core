// aip_soload.sv — SV side of runtime .so command-plugin loader.
// Inert unless compiled with +define+AIP_ENABLE_SOLOAD (and aip_soload.c linked).
`ifndef AIP_SOLOAD_SV
`define AIP_SOLOAD_SV

`ifdef AIP_ENABLE_SOLOAD

import "DPI-C" function int aip_so_load(input string path, output byte err[256], input int err_max);
import "DPI-C" function int aip_so_loaded_name(input int i, output byte name[128], input int name_max);
import "DPI-C" function int aip_so_exec(input string name, input string args, output byte resp[1024], input int resp_max);
import "DPI-C" function int aip_so_unload(input string path);
import "DPI-C" function int aip_so_removed_name(input int i, output byte name[128], input int name_max);

// Plugin command entry: cmd_exec forwards to the .so handler via DPI.
class aip_cmd_plugin_entry extends aip_cmd;
    task cmd_exec();
        byte resp[1024];
        string resp_s;
        int rc;
        rc = aip_so_exec(this.cmd_name, this.args_in, resp, 1024);
        resp_s = "";
        for (int i = 0; i < 1024; i++) begin
            if (resp[i] == 0) break;
            resp_s = {resp_s, $sformatf("%c", resp[i])};
        end
        this.result_out = resp_s;
        this.status = (rc == 0) ? 0 : 1;
    endtask
    function new(string name); super.new(name); endfunction

    static function void register_cmd(string name);
        aip_cmd_plugin_entry e;
        if (aip_cmd::get_handle(name) != null) begin
            `aip_error(("[aip_soload] command '%s' already registered, skip", name));
            return;
        end
        e = new(name);
    endfunction
endclass

// Loader tasks + built-in so_load/so_unload/so_reload commands.
class aip_soload;
    static task load(string path, output int status, output string msg);
        byte err[256];
        byte nm[128];
        string name;
        int n, i, j;
        n = aip_so_load(path, err, 256);
        if (n < 0) begin
            string errs = "";
            for (i = 0; i < 256; i++) begin
                if (err[i] == 0) break;
                errs = {errs, $sformatf("%c", err[i])};
            end
            status = 1;
            msg = {"ERROR: ", errs};
            `aip_error(("[aip_soload] load '%s' failed: %s", path, errs));
            return;
        end
        for (i = 0; i < n; i++) begin
            void'(aip_so_loaded_name(i, nm, 128));
            name = "";
            for (j = 0; j < 128; j++) begin
                if (nm[j] == 0) break;
                name = {name, $sformatf("%c", nm[j])};
            end
            aip_cmd_plugin_entry::register_cmd(name);
        end
        status = 0;
        msg = $sformatf("OK: loaded %s (%0d cmds)", path, n);
        `aip_info(("[aip_soload] %s", msg));
    endtask

    static task unload(string path, output int status, output string msg);
        byte nm[128];
        string name;
        int n, i, j;
        n = aip_so_unload(path);
        if (n < 0) begin
            status = 1;
            msg = {"ERROR: not loaded: ", path};
            return;
        end
        for (i = 0; i < n; i++) begin
            void'(aip_so_removed_name(i, nm, 128));
            name = "";
            for (j = 0; j < 128; j++) begin
                if (nm[j] == 0) break;
                name = {name, $sformatf("%c", nm[j])};
            end
            aip_cmd::unregister(name);
        end
        status = 0;
        msg = $sformatf("OK: unloaded %s (%0d cmds)", path, n);
        `aip_info(("[aip_soload] %s", msg));
    endtask

    static task reload(string path, output int status, output string msg);
        int st; string m;
        unload(path, st, m);           // ignore unload failure (may be first load)
        load(path, status, msg);
    endtask
endclass

class \__aip_cmd_so_load extends aip_cmd;
    task cmd_exec();
        string path; int st; string m;
        path = aip_cmd::get_arg(this.args_in, "path");
        if (path == "") begin this.result_out = "ERROR: so_load: missing path"; this.status = 1; return; end
        aip_soload::load(path, st, m);
        this.result_out = m; this.status = st;
    endtask
    function new(string name); super.new(name); endfunction
    static \__aip_cmd_so_load __inst = new("so_load");
endclass

class \__aip_cmd_so_unload extends aip_cmd;
    task cmd_exec();
        string path; int st; string m;
        path = aip_cmd::get_arg(this.args_in, "path");
        if (path == "") begin this.result_out = "ERROR: so_unload: missing path"; this.status = 1; return; end
        aip_soload::unload(path, st, m);
        this.result_out = m; this.status = st;
    endtask
    function new(string name); super.new(name); endfunction
    static \__aip_cmd_so_unload __inst = new("so_unload");
endclass

class \__aip_cmd_so_reload extends aip_cmd;
    task cmd_exec();
        string path; int st; string m;
        path = aip_cmd::get_arg(this.args_in, "path");
        if (path == "") begin this.result_out = "ERROR: so_reload: missing path"; this.status = 1; return; end
        aip_soload::reload(path, st, m);
        this.result_out = m; this.status = st;
    endtask
    function new(string name); super.new(name); endfunction
    static \__aip_cmd_so_reload __inst = new("so_reload");
endclass

`endif // AIP_ENABLE_SOLOAD
`endif // AIP_SOLOAD_SV

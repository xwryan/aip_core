// schema 公共宏：生成类型 companion、字段适配及 struct/array/queue apply 入口。
// 内部 include 片段，只能由 aip_cmdline.sv 加载（直接包含会产生第二份 $unit/package 类型）。
`ifndef AIP_CMDLINE_INTERNAL_INCLUDE
`AIP_CMDLINE_INTERNAL_INCLUDE_ERROR__USE_AIP_CMDLINE_SV
`else
`define aip_struct_type_begin(STYPE) \
class aip_struct_schema__``STYPE; \
    static function string schema_id(); \
        return $typename(aip_struct_schema__``STYPE); \
    endfunction \
    static function void register_schema(); \
        STYPE __aip_dummy; bit __aip_prev_mode; string __aip_schema_id; \
        __aip_schema_id = schema_id(); \
        if (aip_struct_runtime::schema_is_registered(__aip_schema_id)) return; \
        if (aip_struct_runtime::schema_is_registering(__aip_schema_id)) \
            aip_struct_runtime::fail($sformatf("recursive schema registration detected for %s", __aip_schema_id)); \
        aip_struct_runtime::schema_begin(__aip_schema_id); \
        __aip_prev_mode = aip_struct_runtime::metadata_mode; \
        aip_struct_runtime::metadata_mode = 1; \
        apply_with_compact("__aip_meta", __aip_dummy, ""); \
        aip_struct_runtime::metadata_mode = __aip_prev_mode; \
        aip_struct_runtime::schema_finish(__aip_schema_id); \
    endfunction \
    static function void apply_array(input string __aip_root, input string __aip_overall, inout STYPE __aip_arr[]); \
        string __aip_schema_id; bit __aip_owner; \
        __aip_schema_id = schema_id(); \
        register_schema(); \
        __aip_owner = (aip_struct_runtime::materialization_phase == aip_struct_runtime::PHASE_NORMAL); \
        aip_struct_runtime::begin_container(__aip_root, __aip_schema_id, __aip_arr.size()); \
        aip_struct_runtime::prepare_container_generator(__aip_root, __aip_overall); \
        aip_struct_runtime::prepare_field_generators(__aip_root, __aip_schema_id); \
        if (__aip_owner) aip_struct_runtime::materialization_phase = aip_struct_runtime::PHASE_FIXED; \
        foreach (__aip_arr[__aip_i]) begin \
            string __aip_r = $sformatf("%s[%0d]", __aip_root, __aip_i); \
            string __aip_c = aip_struct_runtime::container_slot(__aip_root, __aip_i, __aip_overall); \
            apply_with_compact(__aip_r, __aip_arr[__aip_i], __aip_c); \
        end \
        if (__aip_owner) begin \
            aip_struct_runtime::preflight_unique(__aip_root, __aip_arr.size(), __aip_schema_id); \
            aip_struct_runtime::materialization_phase = aip_struct_runtime::PHASE_EACH; \
            foreach (__aip_arr[__aip_i]) begin \
                string __aip_r = $sformatf("%s[%0d]", __aip_root, __aip_i); \
                string __aip_c = aip_struct_runtime::container_slot(__aip_root, __aip_i, __aip_overall); \
                apply_with_compact(__aip_r, __aip_arr[__aip_i], __aip_c); \
            end \
            aip_struct_runtime::materialization_phase = aip_struct_runtime::PHASE_NORMAL; \
            aip_struct_array_postprocess#(STYPE)::apply(__aip_root, __aip_arr); \
        end else if (aip_struct_runtime::materialization_phase == aip_struct_runtime::PHASE_FIXED) begin \
            aip_struct_runtime::preflight_unique(__aip_root, __aip_arr.size(), __aip_schema_id); \
        end else if (aip_struct_runtime::materialization_phase == aip_struct_runtime::PHASE_EACH) begin \
            aip_struct_array_postprocess#(STYPE)::apply(__aip_root, __aip_arr); \
        end \
    endfunction \
    static function void apply(input string __aip_root, ref STYPE __aip_value); \
        register_schema(); \
        aip_struct_runtime::validate_root(__aip_root); \
        apply_with_compact(__aip_root, __aip_value, ""); \
    endfunction \
    static function void apply_with_compact(input string __aip_root, ref STYPE __aip_value, input string __aip_inherited_compact); \
        string __aip_compact = __aip_inherited_compact; \
        string __aip_schema_id = schema_id(); \
        string __aip_fields[$]; \
        aip_struct_runtime::lookup_t __aip_root_lookup; \
        begin : __aip_reserved_size end \
        begin : __aip_reserved_each end \
        begin : __aip_reserved_unique end \
        begin : __aip_reserved_sort end \
        aip_cmdline_diagnostic::push_value(__aip_root, __aip_compact); \
        aip_struct_runtime::validate_generated_root(__aip_root); \
        __aip_root_lookup = aip_struct_runtime::lookup(__aip_root); \
        if (__aip_root_lookup.found) begin \
            aip_cmdline_diagnostic::select_value(__aip_root, __aip_root_lookup.value); \
            aip_struct_runtime::check_nonempty(__aip_root_lookup.value, "struct ROOT"); \
            __aip_compact = __aip_root_lookup.value; \
        end

`define aip_struct_type_end(STYPE) \
        aip_cmdline_diagnostic::select_value(__aip_root, __aip_compact); \
        aip_struct_runtime::validate_compact(__aip_compact, __aip_fields); \
        aip_cmdline_diagnostic::pop(); \
    endfunction \
endclass

// 诊断值先标为 <default>，使默认值校验失败可定位；取到实际输入后再由字段宏更新。
`define aip_struct_field_preamble(FIELD) \
        aip_cmdline_diagnostic::select_value({__aip_root, ".", `"FIELD`"}, "<default>"); \
        aip_struct_runtime::check_field_name(`"FIELD`"); \
        __aip_fields.push_back(`"FIELD`");

`define aip_field_int(FTYPE, FIELD, DEFAULT=0) \
        begin : __aip_reserved_``FIELD \
            bit [0:((1 / (($bits(FTYPE) >= 1 && $bits(FTYPE) <= 1024) ? 1 : 0)) - 1)] __aip_width_guard; \
            FTYPE __aip_default; FTYPE __aip_tmp; string __aip_raw; bit __aip_found; bit __aip_from_each; int __aip_attempts; string __aip_key; \
            __aip_default = (DEFAULT); __aip_tmp = __aip_default; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_SCALAR, ""); \
            aip_struct_runtime::register_schema_typed_field(__aip_schema_id, `"FIELD`", 1, $bits(FTYPE), aip_struct_typed_key#(FTYPE)::declared_signed()); \
            aip_struct_refcheck#(FTYPE)::check(__aip_value.FIELD); \
            aip_struct_runtime::check_width($bits(FTYPE), `"FIELD`"); \
            aip_struct_runtime::check_integral_default($isunknown(__aip_default), `"FIELD`"); \
            __aip_key = {__aip_root, ".", `"FIELD`"}; \
            begin aip_struct_runtime::lookup_t __aip_l; __aip_l = aip_struct_runtime::lookup_field_with_compact(__aip_root, `"FIELD`", __aip_compact); __aip_found = __aip_l.found; __aip_raw = __aip_l.value; __aip_from_each = __aip_l.from_each; end \
            aip_struct_runtime::mark_typed_source(__aip_root, `"FIELD`", __aip_from_each, __aip_raw); \
            if (aip_struct_runtime::field_should_apply(__aip_from_each)) begin \
                if (__aip_found) begin \
                    aip_struct_runtime::check_nonempty(__aip_raw, `"FIELD`"); \
                    if ((__aip_raw.len() >= 4 && __aip_raw.substr(0,3) == "seq:") || (__aip_raw.len() >= 5 && __aip_raw.substr(0,4) == "perm:")) begin \
                        bit __aip_slot_found; string __aip_slot; \
                        __aip_slot = aip_struct_runtime::scalar_generator_slot(__aip_root, `"FIELD`", __aip_raw, __aip_slot_found); \
                        if (__aip_slot_found) __aip_raw = __aip_slot; \
                    end \
                    __aip_tmp = aip_strict_int_queue_runtime#(FTYPE)::draw_strict(__aip_raw, __aip_key); \
                end \
                __aip_value.FIELD = __aip_tmp; \
                aip_struct_typed_key#(FTYPE)::record(__aip_root, `"FIELD`", __aip_value.FIELD, 1); \
                if (__aip_from_each && aip_struct_runtime::typed_unique_enabled(__aip_root, `"FIELD`")) begin \
                    while (aip_struct_runtime::typed_current_conflicts(__aip_root, `"FIELD`", aip_struct_runtime::typed_container_extent(__aip_root))) begin \
                        if (!aip_struct_runtime::consume_typed_redraw(__aip_root, `"FIELD`")) \
                            aip_struct_runtime::fail($sformatf("%s: could not find a distinct candidate", aip_struct_runtime::typed_rule_name(__aip_root, `"FIELD`"))); \
                        __aip_tmp = aip_strict_int_queue_runtime#(FTYPE)::draw_strict(__aip_raw, __aip_key); \
                        __aip_value.FIELD = __aip_tmp; \
                        aip_struct_typed_key#(FTYPE)::record(__aip_root, `"FIELD`", __aip_value.FIELD, 1); \
                    end \
                end \
            end else if (aip_struct_runtime::materialization_phase == aip_struct_runtime::PHASE_FIXED && __aip_from_each) begin \
                // Reserve a typed placeholder so finite preflight knows the target kind before the each pass. \
                __aip_value.FIELD = __aip_default; \
                aip_struct_typed_key#(FTYPE)::record(__aip_root, `"FIELD`", __aip_value.FIELD, 1); \
            end \
        end

`define aip_field_string(FIELD, DEFAULT="") \
        begin : __aip_reserved_``FIELD \
            string __aip_default; string __aip_tmp; string __aip_raw; bit __aip_found; bit __aip_from_each; int __aip_attempts; string __aip_key; \
            __aip_default = (DEFAULT); __aip_tmp = __aip_default; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_SCALAR, ""); \
            aip_struct_runtime::register_schema_typed_field(__aip_schema_id, `"FIELD`", 2, 0, 0); \
            aip_struct_refcheck#(string)::check(__aip_value.FIELD); \
            __aip_key = {__aip_root, ".", `"FIELD`"}; \
            begin aip_struct_runtime::lookup_t __aip_l; __aip_l = aip_struct_runtime::lookup_field_with_compact(__aip_root, `"FIELD`", __aip_compact); __aip_found = __aip_l.found; __aip_raw = __aip_l.value; __aip_from_each = __aip_l.from_each; end \
            aip_struct_runtime::mark_typed_source(__aip_root, `"FIELD`", __aip_from_each, __aip_raw); \
            if (aip_struct_runtime::field_should_apply(__aip_from_each)) begin \
                if (__aip_found) __aip_tmp = aip_struct_runtime::resolve_string(__aip_raw); \
                __aip_value.FIELD = __aip_tmp; \
                aip_struct_runtime::record_typed_string(__aip_root, `"FIELD`", __aip_value.FIELD); \
                if (__aip_from_each && aip_struct_runtime::typed_unique_enabled(__aip_root, `"FIELD`")) begin \
                    while (aip_struct_runtime::typed_current_conflicts(__aip_root, `"FIELD`", aip_struct_runtime::typed_container_extent(__aip_root))) begin \
                        if (!aip_struct_runtime::consume_typed_redraw(__aip_root, `"FIELD`")) \
                            aip_struct_runtime::fail($sformatf("%s: could not find a distinct candidate", aip_struct_runtime::typed_rule_name(__aip_root, `"FIELD`"))); \
                        __aip_tmp = aip_struct_runtime::resolve_string(__aip_raw); \
                        __aip_value.FIELD = __aip_tmp; \
                        aip_struct_runtime::record_typed_string(__aip_root, `"FIELD`", __aip_value.FIELD); \
                    end \
                end \
            end else if (aip_struct_runtime::materialization_phase == aip_struct_runtime::PHASE_FIXED && __aip_from_each) begin \
                __aip_value.FIELD = __aip_default; \
                aip_struct_runtime::record_typed_string(__aip_root, `"FIELD`", __aip_value.FIELD); \
            end \
        end

`define aip_field_real(FIELD, DEFAULT=0.0) \
        begin : __aip_reserved_``FIELD \
            real __aip_default; real __aip_tmp; string __aip_raw; bit __aip_found; bit __aip_from_each; int __aip_attempts; string __aip_key; \
            __aip_default = (DEFAULT); __aip_tmp = __aip_default; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_SCALAR, ""); \
            aip_struct_runtime::register_schema_typed_field(__aip_schema_id, `"FIELD`", 3, 0, 0); \
            aip_struct_refcheck#(real)::check(__aip_value.FIELD); \
            aip_struct_runtime::check_real(__aip_default, `"FIELD`"); \
            __aip_key = {__aip_root, ".", `"FIELD`"}; \
            begin aip_struct_runtime::lookup_t __aip_l; __aip_l = aip_struct_runtime::lookup_field_with_compact(__aip_root, `"FIELD`", __aip_compact); __aip_found = __aip_l.found; __aip_raw = __aip_l.value; __aip_from_each = __aip_l.from_each; end \
            aip_struct_runtime::mark_typed_source(__aip_root, `"FIELD`", __aip_from_each, __aip_raw); \
            if (aip_struct_runtime::field_should_apply(__aip_from_each)) begin \
                if (__aip_found) begin aip_struct_runtime::check_nonempty(__aip_raw, `"FIELD`"); __aip_tmp = aip_struct_real_array_runtime::draw_strict(__aip_raw, __aip_key); end \
                aip_struct_runtime::check_real(__aip_tmp, `"FIELD`"); \
                __aip_value.FIELD = __aip_tmp; \
                aip_struct_runtime::record_typed_real(__aip_root, `"FIELD`", __aip_value.FIELD); \
                if (__aip_from_each && aip_struct_runtime::typed_unique_enabled(__aip_root, `"FIELD`")) begin \
                    while (aip_struct_runtime::typed_current_conflicts(__aip_root, `"FIELD`", aip_struct_runtime::typed_container_extent(__aip_root))) begin \
                        if (!aip_struct_runtime::consume_typed_redraw(__aip_root, `"FIELD`")) \
                            aip_struct_runtime::fail($sformatf("%s: could not find a distinct candidate", aip_struct_runtime::typed_rule_name(__aip_root, `"FIELD`"))); \
                        __aip_tmp = aip_struct_real_array_runtime::draw_strict(__aip_raw, __aip_key); \
                        aip_struct_runtime::check_real(__aip_tmp, `"FIELD`"); \
                        __aip_value.FIELD = __aip_tmp; \
                        aip_struct_runtime::record_typed_real(__aip_root, `"FIELD`", __aip_value.FIELD); \
                    end \
                end \
            end else if (aip_struct_runtime::materialization_phase == aip_struct_runtime::PHASE_FIXED && __aip_from_each) begin \
                __aip_value.FIELD = __aip_default; \
                aip_struct_runtime::record_typed_real(__aip_root, `"FIELD`", __aip_value.FIELD); \
            end \
        end

`define aip_field_enum(ETYPE, FIELD, DEFAULT) \
        begin : __aip_reserved_``FIELD \
            ETYPE __aip_default; ETYPE __aip_tmp; ETYPE __aip_iter; bit __aip_default_valid; string __aip_raw; bit __aip_found; bit __aip_from_each; int __aip_attempts; string __aip_key; \
            string __aip_names[$]; logic [1023:0] __aip_bits[$]; logic [1023:0] __aip_enum_bits; \
            __aip_default = (DEFAULT); __aip_tmp = __aip_default; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_SCALAR, ""); \
            aip_struct_runtime::register_schema_typed_field(__aip_schema_id, `"FIELD`", 4, $bits(ETYPE), aip_struct_typed_key#(ETYPE)::declared_signed()); \
            aip_struct_refcheck#(ETYPE)::check(__aip_value.FIELD); \
            __aip_iter = __aip_iter.first(); \
            __aip_default_valid = 0; \
            do begin __aip_enum_bits = '0; __aip_enum_bits[$bits(ETYPE)-1:0] = __aip_iter; __aip_names.push_back(__aip_iter.name()); __aip_bits.push_back(__aip_enum_bits); aip_struct_runtime::register_schema_enum_value(__aip_schema_id, `"FIELD`", __aip_iter.name(), __aip_enum_bits); if (__aip_default === __aip_iter) __aip_default_valid = 1; if (__aip_iter == __aip_iter.last()) break; __aip_iter = __aip_iter.next(); end while (1); \
            aip_struct_runtime::check_enum_default(__aip_default_valid, `"FIELD`"); \
            __aip_key = {__aip_root, ".", `"FIELD`"}; \
            begin aip_struct_runtime::lookup_t __aip_l; __aip_l = aip_struct_runtime::lookup_field_with_compact(__aip_root, `"FIELD`", __aip_compact); __aip_found = __aip_l.found; __aip_raw = __aip_l.value; __aip_from_each = __aip_l.from_each; end \
            aip_struct_runtime::mark_typed_source(__aip_root, `"FIELD`", __aip_from_each, __aip_raw); \
            if (aip_struct_runtime::field_should_apply(__aip_from_each)) begin \
                if (__aip_found) begin aip_struct_runtime::check_nonempty(__aip_raw, `"FIELD`"); __aip_tmp = aip_strict_enum_queue_runtime#(ETYPE)::draw(__aip_raw, __aip_key, __aip_names, __aip_bits); end \
                __aip_value.FIELD = __aip_tmp; \
                aip_struct_typed_key#(ETYPE)::record(__aip_root, `"FIELD`", __aip_value.FIELD, 4); \
                if (__aip_from_each && aip_struct_runtime::typed_unique_enabled(__aip_root, `"FIELD`")) begin \
                    while (aip_struct_runtime::typed_current_conflicts(__aip_root, `"FIELD`", aip_struct_runtime::typed_container_extent(__aip_root))) begin \
                        if (!aip_struct_runtime::consume_typed_redraw(__aip_root, `"FIELD`")) \
                            aip_struct_runtime::fail($sformatf("%s: could not find a distinct candidate", aip_struct_runtime::typed_rule_name(__aip_root, `"FIELD`"))); \
                        __aip_tmp = aip_strict_enum_queue_runtime#(ETYPE)::draw(__aip_raw, __aip_key, __aip_names, __aip_bits); \
                        __aip_value.FIELD = __aip_tmp; \
                        aip_struct_typed_key#(ETYPE)::record(__aip_root, `"FIELD`", __aip_value.FIELD, 4); \
                    end \
                end \
            end else if (aip_struct_runtime::materialization_phase == aip_struct_runtime::PHASE_FIXED && __aip_from_each) begin \
                __aip_value.FIELD = __aip_default; \
                aip_struct_typed_key#(ETYPE)::record(__aip_root, `"FIELD`", __aip_value.FIELD, 4); \
            end \
        end

`define aip_field_struct(STYPE, FIELD) \
        begin : __aip_reserved_``FIELD \
            string __aip_raw; bit __aip_found; string __aip_key; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_STRUCT, aip_struct_schema__``STYPE::schema_id()); \
            aip_struct_schema__``STYPE::register_schema(); \
            aip_struct_refcheck#(STYPE)::check(__aip_value.FIELD); \
            __aip_key = {__aip_root, ".", `"FIELD`"}; \
            begin aip_struct_runtime::lookup_t __aip_l; __aip_l = aip_struct_runtime::lookup_field_with_compact(__aip_root, `"FIELD`", __aip_compact); __aip_found = __aip_l.found; __aip_raw = __aip_l.value; end \
            aip_cmdline_diagnostic::select_value(__aip_key, __aip_raw); \
            if (__aip_found) aip_struct_runtime::check_nonempty(__aip_raw, `"FIELD`"); \
            aip_struct_schema__``STYPE::apply_with_compact(__aip_key, __aip_value.FIELD, __aip_found ? __aip_raw : ""); \
        end

// Array members use the same typed resolver as the legacy list macros, with keys rooted at the struct path (e.g. cfg.tags[1]).
// Static arrays go through a temporary open array: VCS cannot bind a fixed unpacked array to a ref open-array formal.
`define aip_field_int_sarray(FTYPE, FIELD, ELEMENT_DEFAULT=0) \
        begin : __aip_reserved_``FIELD \
            bit [0:((1 / (($bits(FTYPE) >= 1 && $bits(FTYPE) <= 1024) ? 1 : 0)) - 1)] __aip_width_guard; \
            FTYPE __aip_default; FTYPE __aip_sv[]; \
            __aip_default = (ELEMENT_DEFAULT); \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_PRIMITIVE_ARRAY, ""); \
            if (!aip_struct_runtime::metadata_mode) \
                aip_struct_runtime::validate_static_array_range({__aip_root, ".", `"FIELD`"}, $unpacked_dimensions(__aip_value.FIELD), $left(__aip_value.FIELD), $right(__aip_value.FIELD), $low(__aip_value.FIELD), $high(__aip_value.FIELD), $size(__aip_value.FIELD)); \
            aip_struct_refcheck#(FTYPE)::check(__aip_value.FIELD[$left(__aip_value.FIELD)]); \
            aip_struct_runtime::check_width($bits(FTYPE), `"FIELD`" ); \
            aip_struct_runtime::check_integral_default($isunknown(__aip_default), `"FIELD`" ); \
            if (aip_struct_runtime::nonstruct_array_should_apply()) begin \
                aip_struct_schema_array_runtime#(FTYPE)::resolve(__aip_root, `"FIELD`", __aip_compact, __aip_default, $size(__aip_value.FIELD), 0, __aip_sv); \
                aip_struct_schema_array_runtime#(FTYPE)::postprocess(__aip_root, `"FIELD`", __aip_sv); \
                foreach (__aip_value.FIELD[__aip_i]) __aip_value.FIELD[__aip_i] = __aip_sv[__aip_i]; \
            end \
        end

`define aip_field_string_sarray(FIELD, ELEMENT_DEFAULT="") \
        begin : __aip_reserved_``FIELD \
            string __aip_sv[]; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_PRIMITIVE_ARRAY, ""); \
            if (!aip_struct_runtime::metadata_mode) \
                aip_struct_runtime::validate_static_array_range({__aip_root, ".", `"FIELD`"}, $unpacked_dimensions(__aip_value.FIELD) - $unpacked_dimensions(string), $left(__aip_value.FIELD), $right(__aip_value.FIELD), $low(__aip_value.FIELD), $high(__aip_value.FIELD), $size(__aip_value.FIELD)); \
            aip_struct_refcheck#(string)::check(__aip_value.FIELD[$left(__aip_value.FIELD)]); \
            if (aip_struct_runtime::nonstruct_array_should_apply()) begin \
                aip_struct_string_array_runtime::resolve(__aip_root, `"FIELD`", __aip_compact, (ELEMENT_DEFAULT), $size(__aip_value.FIELD), 0, __aip_sv); \
                aip_struct_string_array_runtime::postprocess(__aip_root, `"FIELD`", __aip_sv); \
                foreach (__aip_value.FIELD[__aip_i]) __aip_value.FIELD[__aip_i] = __aip_sv[__aip_i]; \
            end \
        end

`define aip_field_int_darray(FTYPE, FIELD, ELEMENT_DEFAULT=0, DEFAULT_SIZE=0) \
        begin : __aip_reserved_``FIELD \
            bit [0:((1 / (($bits(FTYPE) >= 1 && $bits(FTYPE) <= 1024) ? 1 : 0)) - 1)] __aip_width_guard; \
            FTYPE __aip_default; FTYPE __aip_sv[]; real __aip_default_size_real; int __aip_default_size; \
            __aip_default = (ELEMENT_DEFAULT); \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_PRIMITIVE_ARRAY, ""); \
            aip_struct_array_refcheck#(FTYPE)::check(__aip_value.FIELD); \
            aip_struct_runtime::check_width($bits(FTYPE), `"FIELD`" ); \
            aip_struct_runtime::check_integral_default($isunknown(__aip_default), `"FIELD`" ); \
            if (aip_struct_runtime::nonstruct_array_should_apply()) begin \
                __aip_default_size_real = real'(DEFAULT_SIZE); aip_struct_runtime::validate_default_size(__aip_default_size_real); __aip_default_size = int'(__aip_default_size_real); \
                aip_struct_schema_array_runtime#(FTYPE)::resolve(__aip_root, `"FIELD`", __aip_compact, __aip_default, -1, __aip_default_size, __aip_sv); \
                __aip_value.FIELD = __aip_sv; \
                aip_struct_schema_array_runtime#(FTYPE)::postprocess(__aip_root, `"FIELD`", __aip_value.FIELD); \
            end \
        end

`define aip_field_string_darray(FIELD, ELEMENT_DEFAULT="", DEFAULT_SIZE=0) \
        begin : __aip_reserved_``FIELD \
            string __aip_sv[]; real __aip_default_size_real; int __aip_default_size; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_PRIMITIVE_ARRAY, ""); \
            aip_struct_array_refcheck#(string)::check(__aip_value.FIELD); \
            if (aip_struct_runtime::nonstruct_array_should_apply()) begin \
                __aip_default_size_real = real'(DEFAULT_SIZE); aip_struct_runtime::validate_default_size(__aip_default_size_real); __aip_default_size = int'(__aip_default_size_real); \
                aip_struct_string_array_runtime::resolve(__aip_root, `"FIELD`", __aip_compact, (ELEMENT_DEFAULT), -1, __aip_default_size, __aip_sv); \
                __aip_value.FIELD = __aip_sv; \
                aip_struct_string_array_runtime::postprocess(__aip_root, `"FIELD`", __aip_value.FIELD); \
            end \
        end

`define aip_field_real_sarray(FIELD, ELEMENT_DEFAULT=0.0) \
        begin : __aip_reserved_``FIELD \
            real __aip_sv[]; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_PRIMITIVE_ARRAY, ""); \
            if (!aip_struct_runtime::metadata_mode) \
                aip_struct_runtime::validate_static_array_range({__aip_root, ".", `"FIELD`"}, $unpacked_dimensions(__aip_value.FIELD), $left(__aip_value.FIELD), $right(__aip_value.FIELD), $low(__aip_value.FIELD), $high(__aip_value.FIELD), $size(__aip_value.FIELD)); \
            aip_struct_refcheck#(real)::check(__aip_value.FIELD[$left(__aip_value.FIELD)]); \
            aip_struct_runtime::check_real((ELEMENT_DEFAULT), `"FIELD`" ); \
            if (aip_struct_runtime::nonstruct_array_should_apply()) begin \
                aip_struct_real_array_runtime::resolve_schema(__aip_root, `"FIELD`", __aip_compact, (ELEMENT_DEFAULT), $size(__aip_value.FIELD), 0, __aip_sv); \
                aip_struct_real_array_runtime::postprocess(__aip_root, `"FIELD`", __aip_sv); \
                foreach (__aip_value.FIELD[__aip_i]) __aip_value.FIELD[__aip_i] = __aip_sv[__aip_i]; \
            end \
        end

`define aip_field_real_darray(FIELD, ELEMENT_DEFAULT=0.0, DEFAULT_SIZE=0) \
        begin : __aip_reserved_``FIELD \
            real __aip_sv[]; real __aip_default_size_real; int __aip_default_size; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_PRIMITIVE_ARRAY, ""); \
            aip_struct_array_refcheck#(real)::check(__aip_value.FIELD); \
            aip_struct_runtime::check_real((ELEMENT_DEFAULT), `"FIELD`" ); \
            if (aip_struct_runtime::nonstruct_array_should_apply()) begin \
                __aip_default_size_real = real'(DEFAULT_SIZE); aip_struct_runtime::validate_default_size(__aip_default_size_real); __aip_default_size = int'(__aip_default_size_real); \
                aip_struct_real_array_runtime::resolve_schema(__aip_root, `"FIELD`", __aip_compact, (ELEMENT_DEFAULT), -1, __aip_default_size, __aip_sv); \
                __aip_value.FIELD = __aip_sv; \
                aip_struct_real_array_runtime::postprocess(__aip_root, `"FIELD`", __aip_value.FIELD); \
            end \
        end

`define aip_field_enum_sarray(ETYPE, FIELD, ELEMENT_DEFAULT) \
        begin : __aip_reserved_``FIELD \
            string __aip_names[$]; logic [1023:0] __aip_bits[$]; ETYPE __aip_sv[]; ETYPE __aip_iter; ETYPE __aip_default; bit __aip_def_ok; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_PRIMITIVE_ARRAY, ""); \
            if (!aip_struct_runtime::metadata_mode) \
                aip_struct_runtime::validate_static_array_range({__aip_root, ".", `"FIELD`"}, $unpacked_dimensions(__aip_value.FIELD), $left(__aip_value.FIELD), $right(__aip_value.FIELD), $low(__aip_value.FIELD), $high(__aip_value.FIELD), $size(__aip_value.FIELD)); \
            aip_struct_refcheck#(ETYPE)::check(__aip_value.FIELD[$left(__aip_value.FIELD)]); \
            __aip_default = (ELEMENT_DEFAULT); __aip_def_ok = 0; \
            __aip_iter = __aip_iter.first(); \
            do begin logic [1023:0] __aip_b; __aip_b='0; __aip_b[$bits(ETYPE)-1:0]=__aip_iter; __aip_names.push_back(__aip_iter.name()); __aip_bits.push_back(__aip_b); if (__aip_default === __aip_iter) __aip_def_ok = 1; if (__aip_iter == __aip_iter.last()) break; __aip_iter = __aip_iter.next(); end while (1); \
            aip_struct_runtime::check_enum_default(__aip_def_ok, `"FIELD`" ); \
            if (aip_struct_runtime::nonstruct_array_should_apply()) begin \
                aip_struct_enum_array_postprocess#(ETYPE)::resolve(__aip_root, `"FIELD`", __aip_compact, __aip_default, $size(__aip_value.FIELD), 0, __aip_names, __aip_bits, __aip_sv); \
                aip_struct_enum_array_postprocess#(ETYPE)::apply(__aip_root, `"FIELD`", __aip_sv); \
                foreach (__aip_value.FIELD[__aip_i]) __aip_value.FIELD[__aip_i] = __aip_sv[__aip_i]; \
            end \
        end

`define aip_field_enum_darray(ETYPE, FIELD, ELEMENT_DEFAULT, DEFAULT_SIZE=0) \
        begin : __aip_reserved_``FIELD \
            string __aip_names[$]; logic [1023:0] __aip_bits[$]; ETYPE __aip_sv[]; ETYPE __aip_iter; ETYPE __aip_default; bit __aip_def_ok; real __aip_default_size_real; int __aip_default_size; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_PRIMITIVE_ARRAY, ""); \
            aip_struct_array_refcheck#(ETYPE)::check(__aip_value.FIELD); \
            __aip_default = (ELEMENT_DEFAULT); __aip_def_ok = 0; \
            __aip_iter = __aip_iter.first(); \
            do begin logic [1023:0] __aip_b; __aip_b='0; __aip_b[$bits(ETYPE)-1:0]=__aip_iter; __aip_names.push_back(__aip_iter.name()); __aip_bits.push_back(__aip_b); if (__aip_default === __aip_iter) __aip_def_ok = 1; if (__aip_iter == __aip_iter.last()) break; __aip_iter = __aip_iter.next(); end while (1); \
            aip_struct_runtime::check_enum_default(__aip_def_ok, `"FIELD`" ); \
            if (aip_struct_runtime::nonstruct_array_should_apply()) begin \
                __aip_default_size_real = real'(DEFAULT_SIZE); aip_struct_runtime::validate_default_size(__aip_default_size_real); __aip_default_size = int'(__aip_default_size_real); \
                aip_struct_enum_array_postprocess#(ETYPE)::resolve(__aip_root, `"FIELD`", __aip_compact, __aip_default, -1, __aip_default_size, __aip_names, __aip_bits, __aip_sv); \
                __aip_value.FIELD = __aip_sv; \
                aip_struct_enum_array_postprocess#(ETYPE)::apply(__aip_root, `"FIELD`", __aip_value.FIELD); \
            end \
        end

`define aip_field_struct_sarray(STYPE, FIELD) \
        begin : __aip_reserved_``FIELD \
            STYPE __aip_sv[]; string __aip_base; string __aip_overall; int __aip_n; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_STRUCT_ARRAY, aip_struct_schema__``STYPE::schema_id()); \
            aip_struct_schema__``STYPE::register_schema(); \
            __aip_base = {__aip_root, ".", `"FIELD`"}; \
            if (!aip_struct_runtime::metadata_mode) \
                aip_struct_runtime::validate_static_array_range(__aip_base, $unpacked_dimensions(__aip_value.FIELD), $left(__aip_value.FIELD), $right(__aip_value.FIELD), $low(__aip_value.FIELD), $high(__aip_value.FIELD), $size(__aip_value.FIELD)); \
            aip_struct_refcheck#(STYPE)::check(__aip_value.FIELD[$left(__aip_value.FIELD)]); \
            __aip_n = $size(__aip_value.FIELD); \
            if (aip_struct_runtime::nested_array_should_allocate()) begin \
                __aip_sv = new[__aip_n]; \
                foreach (__aip_sv[__aip_i]) __aip_sv[__aip_i] = __aip_value.FIELD[__aip_i]; \
                begin aip_struct_runtime::lookup_t __aip_l; __aip_l = aip_struct_runtime::lookup(__aip_base); __aip_overall = __aip_l.found ? __aip_l.value : ""; end \
                aip_struct_runtime::validate_static_container_length(__aip_base, aip_struct_schema__``STYPE::schema_id(), __aip_n, __aip_overall); \
                aip_struct_runtime::validate_indexed_bounds_schema(__aip_base, __aip_n, aip_struct_schema__``STYPE::schema_id()); \
            end else begin \
                __aip_sv = new[__aip_n]; \
                begin aip_struct_runtime::lookup_t __aip_l; __aip_l = aip_struct_runtime::lookup(__aip_base); __aip_overall = __aip_l.found ? __aip_l.value : ""; end \
                foreach (__aip_sv[__aip_i]) __aip_sv[__aip_i] = __aip_value.FIELD[__aip_i]; \
            end \
            aip_struct_schema__``STYPE::apply_array(__aip_base, __aip_overall, __aip_sv); \
            foreach (__aip_value.FIELD[__aip_i]) __aip_value.FIELD[__aip_i] = __aip_sv[__aip_i]; \
        end

`define aip_field_struct_darray(STYPE, FIELD, DEFAULT_SIZE=0) \
        begin : __aip_reserved_``FIELD \
            STYPE __aip_sv[]; string __aip_base; string __aip_overall; int __aip_n; int __aip_old_n; real __aip_default_size_real; int __aip_default_size; \
            `aip_struct_field_preamble(FIELD) \
            aip_struct_runtime::register_schema_field(__aip_schema_id, `"FIELD`", aip_struct_runtime::META_STRUCT_ARRAY, aip_struct_schema__``STYPE::schema_id()); \
            aip_struct_schema__``STYPE::register_schema(); \
            aip_struct_array_refcheck#(STYPE)::check(__aip_value.FIELD); \
            __aip_base = {__aip_root, ".", `"FIELD`"}; \
            if (aip_struct_runtime::nested_array_should_allocate()) begin \
                __aip_default_size_real = real'(DEFAULT_SIZE); aip_struct_runtime::validate_default_size(__aip_default_size_real); __aip_default_size = int'(__aip_default_size_real); \
                __aip_old_n = __aip_value.FIELD.size(); \
                __aip_n = aip_struct_runtime::container_size_schema(__aip_base, __aip_default_size, aip_struct_schema__``STYPE::schema_id()); \
                aip_struct_runtime::charge_allocation(__aip_base, __aip_n); \
                __aip_sv = new[__aip_n]; \
                for (int __aip_i = 0; __aip_i < __aip_n && __aip_i < __aip_old_n; __aip_i++) __aip_sv[__aip_i] = __aip_value.FIELD[__aip_i]; \
                begin aip_struct_runtime::lookup_t __aip_l; __aip_l = aip_struct_runtime::lookup(__aip_base); __aip_overall = __aip_l.found ? __aip_l.value : ""; end \
                aip_struct_runtime::validate_indexed_bounds_schema(__aip_base, __aip_n, aip_struct_schema__``STYPE::schema_id()); \
            end else begin \
                begin aip_struct_runtime::lookup_t __aip_l; __aip_l = aip_struct_runtime::lookup(__aip_base); __aip_overall = __aip_l.found ? __aip_l.value : ""; end \
                __aip_sv = __aip_value.FIELD; \
            end \
            aip_struct_schema__``STYPE::apply_array(__aip_base, __aip_overall, __aip_sv); \
            __aip_value.FIELD = __aip_sv; \
        end

`define aip_struct_apply(ROOT, STYPE, TARGET) \
        begin \
            string __aip_root; \
            __aip_root = (ROOT); \
            aip_cmdline_diagnostic::push(__aip_root, `__FILE__, `__LINE__); \
            aip_struct_runtime::begin_allocation_scope(); \
            aip_struct_runtime::validate_root(__aip_root); \
            aip_struct_schema__``STYPE::register_schema(); \
            aip_struct_schema__``STYPE::apply(__aip_root, (TARGET)); \
            aip_struct_runtime::end_allocation_scope(); \
            aip_cmdline_diagnostic::pop(); \
        end

// Per-index rules (ROOT[i]) take precedence over the overall comma-separated list.
`define aip_struct_sarray_apply(ROOT, STYPE, TARGET) \
        begin \
            string __aip_root; string __aip_overall; aip_struct_runtime::lookup_t __aip_ol; \
            __aip_root = (ROOT); \
            aip_cmdline_diagnostic::push(__aip_root, `__FILE__, `__LINE__); \
            aip_struct_runtime::begin_allocation_scope(); \
            aip_struct_runtime::validate_root(__aip_root); \
            aip_struct_runtime::validate_static_array_range(__aip_root, $unpacked_dimensions(TARGET), $left(TARGET), $right(TARGET), $low(TARGET), $high(TARGET), $size(TARGET)); \
            aip_struct_schema__``STYPE::register_schema(); \
            __aip_ol = aip_struct_runtime::lookup(__aip_root); \
            __aip_overall = __aip_ol.found ? __aip_ol.value : ""; \
            aip_struct_runtime::validate_static_container_length(__aip_root, aip_struct_schema__``STYPE::schema_id(), $size(TARGET), __aip_overall); \
            aip_struct_runtime::validate_indexed_bounds_schema(__aip_root, $size(TARGET), aip_struct_schema__``STYPE::schema_id()); \
            aip_struct_schema__``STYPE::apply_array(__aip_root, __aip_overall, TARGET); \
            aip_struct_runtime::end_allocation_scope(); \
            aip_cmdline_diagnostic::pop(); \
        end

// The .size rule is evaluated once before allocation; DEFAULT_SIZE applies when size is omitted.
`define aip_struct_darray_apply(ROOT, STYPE, TARGET, DEFAULT_SIZE=0) \
        begin \
            string __aip_root; real __aip_default_size_real; int __aip_default_size; string __aip_overall; aip_struct_runtime::lookup_t __aip_ol; int __aip_n; STYPE __aip_sv[]; int __aip_old_n; \
            __aip_root = (ROOT); __aip_default_size_real = real'(DEFAULT_SIZE); \
            aip_cmdline_diagnostic::push(__aip_root, `__FILE__, `__LINE__); \
            aip_struct_runtime::begin_allocation_scope(); \
            aip_struct_runtime::validate_root(__aip_root); \
            aip_struct_runtime::validate_default_size(__aip_default_size_real); __aip_default_size = int'(__aip_default_size_real); \
            aip_struct_schema__``STYPE::register_schema(); \
            __aip_ol = aip_struct_runtime::lookup(__aip_root); \
            __aip_overall = __aip_ol.found ? __aip_ol.value : ""; \
            __aip_n = aip_struct_runtime::container_size_schema(__aip_root, __aip_default_size, aip_struct_schema__``STYPE::schema_id()); \
            aip_struct_runtime::charge_allocation(__aip_root, __aip_n); \
            __aip_old_n = TARGET.size(); __aip_sv = new[__aip_n]; for (int __aip_i = 0; __aip_i < __aip_n && __aip_i < __aip_old_n; __aip_i++) __aip_sv[__aip_i] = TARGET[__aip_i]; \
            aip_struct_runtime::validate_indexed_bounds_schema(__aip_root, __aip_n, aip_struct_schema__``STYPE::schema_id()); \
            aip_struct_schema__``STYPE::apply_array(__aip_root, __aip_overall, __aip_sv); \
            TARGET = __aip_sv; \
            aip_struct_runtime::end_allocation_scope(); \
            aip_cmdline_diagnostic::pop(); \
        end

// Built in a temporary dynamic array (ref-queue binding differs for bounded/unbounded queues; MAX_SIZE is checked
// before any push_back). Existing records are copied first so unregistered fields and opaque handles survive re-apply.
`define aip_struct_queue_apply(ROOT, STYPE, TARGET, DEFAULT_SIZE=0, MAX_SIZE=-1) \
        begin \
            string __aip_root; real __aip_default_size_real; real __aip_max_size_real; int __aip_default_size; int __aip_max_size; string __aip_overall; aip_struct_runtime::lookup_t __aip_ol; int __aip_n; STYPE __aip_sv[]; int __aip_rules; int __aip_controls; int __aip_fields; string __aip_flags; \
            __aip_root = (ROOT); __aip_default_size_real = real'(DEFAULT_SIZE); __aip_max_size_real = real'(MAX_SIZE); \
            aip_cmdline_diagnostic::push(__aip_root, `__FILE__, `__LINE__); \
            aip_struct_runtime::begin_allocation_scope(); \
            aip_struct_runtime::validate_root(__aip_root); \
            aip_struct_runtime::validate_default_size(__aip_default_size_real); __aip_default_size = int'(__aip_default_size_real); \
            aip_struct_runtime::validate_max_size(__aip_max_size_real); __aip_max_size = int'(__aip_max_size_real); \
            aip_struct_schema__``STYPE::register_schema(); \
            __aip_ol = aip_struct_runtime::lookup(__aip_root); \
            __aip_overall = __aip_ol.found ? __aip_ol.value : ""; \
            __aip_n = aip_struct_runtime::container_size_schema(__aip_root, __aip_default_size, aip_struct_schema__``STYPE::schema_id(), __aip_max_size); \
            aip_struct_runtime::check_container_capacity(__aip_root, __aip_n, __aip_max_size_real); \
            aip_struct_runtime::charge_allocation(__aip_root, __aip_n); \
            __aip_sv = new[__aip_n]; \
            for (int __aip_i = 0; __aip_i < __aip_n && __aip_i < TARGET.size(); __aip_i++) \
                __aip_sv[__aip_i] = TARGET[__aip_i]; \
            aip_struct_runtime::validate_indexed_bounds_schema(__aip_root, __aip_n, aip_struct_schema__``STYPE::schema_id()); \
            aip_struct_schema__``STYPE::apply_array(__aip_root, __aip_overall, __aip_sv); \
            TARGET.delete(); \
            foreach (__aip_sv[__aip_i]) TARGET.push_back(__aip_sv[__aip_i]); \
            if (TARGET.size() != __aip_sv.size()) \
                aip_struct_runtime::fail($sformatf("%s queue size mismatch after copy (expected %0d, got %0d)", __aip_root, __aip_sv.size(), TARGET.size())); \
            aip_struct_runtime::struct_queue_rule_stats(__aip_root, aip_struct_schema__``STYPE::schema_id(), __aip_rules, __aip_controls, __aip_flags); \
            __aip_fields = aip_struct_runtime::schema_registered_field_count(aip_struct_schema__``STYPE::schema_id()); \
            if (aip_cmdline_print_control::should_print(__aip_root, "")) \
                `aip_info(("[aip_cmdline] queue_summary root='%s' type='%s' kind='struct_queue' size=%0d fields=%0d rules=%0d controls=%0d flags=%s", __aip_root, $typename(STYPE), TARGET.size(), __aip_fields, __aip_rules, __aip_controls, __aip_flags)); \
            aip_struct_runtime::end_allocation_scope(); \
            aip_cmdline_diagnostic::pop(); \
        end
`endif // AIP_CMDLINE_INTERNAL_INCLUDE

#!/usr/bin/env bash
# 串行执行参数解析基准矩阵，收集进程内计时的中位数与范围；每个样本单独启动 simv。
# 依赖已编译的 tests/sv/simv_cmdline_benchmark 与 GNU timeout/sort/awk。
set -euo pipefail

bench_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bench_sv_dir=$(cd -- "$bench_script_dir/../sv" && pwd)
bench_repeats=${BENCH_REPEATS:-3}
bench_repeat_iters=${BENCH_REPEAT_ITERS:-1000}
bench_micro_iters=${BENCH_MICRO_ITERS:-10000}
bench_array_iters=${BENCH_ARRAY_ITERS:-1}
bench_timeout=${BENCH_TIMEOUT:-120}
bench_filter=${BENCH_FILTER:-'*'}

# 参数仅控制工作量，必须是有限正整数；重复次数取奇数，避免中位数定义歧义。
for bench_number in "$bench_repeats" "$bench_repeat_iters" "$bench_micro_iters" "$bench_array_iters" "$bench_timeout"; do
    if [[ ! $bench_number =~ ^[1-9][0-9]*$ ]]; then
        echo "benchmark counts/timeouts must be positive decimal integers" >&2
        exit 2
    fi
done
if ((bench_repeats > 9 || bench_repeats % 2 == 0)); then
    echo "BENCH_REPEATS must be odd and between 1 and 9" >&2
    exit 2
fi
if [[ ! -x $bench_sv_dir/simv_cmdline_benchmark ]]; then
    echo "build first: make bench_cmdline_build" >&2
    exit 2
fi

bench_log_dir=$(mktemp -d "$bench_sv_dir/cmdline_benchmark.XXXXXX")
printf 'BENCH_LOG_DIR %s\n' "$bench_log_dir"
cd -- "$bench_sv_dir"

# 任何失败都停止，不纳入统计。noise 是附加的无关 plusarg 数（非总参数数）。
# 字段均用确定值 1..16，不把 RNG、unique/sort 或打印耗时混入基准。
run_case() {
    local label=$1 scenario=$2 source=$3 noise=$4 iterations=$5 size=$6 miss=${7:-0}
    local field compact='' root log result cpu wall records=0 sample i median
    local -a args=() cpu_samples=() wall_samples=() sorted_cpu=() sorted_wall=()

    [[ $label == $bench_filter ]] || return 0
    args=(-no_save -exitstatus +ntb_random_seed=17 "+BENCH_CASE=$scenario"
          "+BENCH_SOURCE=$source" "+BENCH_ITERS=$iterations" "+BENCH_SIZE=$size" "+BENCH_MISS=$miss")
    for ((i = 0; i < noise; i++)); do
        args+=("+unused_bench_$i=$i")
    done
    root=bench.cfg
    if [[ $scenario == array ]]; then
        root=bench.rows.each
        args+=("+bench.rows.size=$size")
    fi
    for ((i = 0; i < 16; i++)); do
        printf -v field 'f%02d' "$i"
        if [[ $source == dotted ]]; then
            args+=("+$root.$field=$((i + 1))")
        fi
        [[ $i == 0 ]] || compact+=','
        compact+="$field=$((i + 1))"
    done
    if [[ $source == compact ]]; then
        args+=("+bench.cfg={$compact}")
    fi

    for ((sample = 1; sample <= bench_repeats; sample++)); do
        log="$bench_log_dir/${label}_${sample}.log"
        if ! timeout "${bench_timeout}s" ./simv_cmdline_benchmark "${args[@]}" > "$log" 2>&1; then
            cat "$log"
            echo "benchmark failed/timed out: $label sample=$sample" >&2
            return 1
        fi
        grep -Fxq BENCH_PASS "$log"
        [[ $(grep -c '^BENCH_RESULT ' "$log") == 1 ]]
        result=$(grep '^BENCH_RESULT ' "$log")
        cpu=$(awk '{for(i=1;i<=NF;i++) if($i~/^cpu_s=/) {sub(/^cpu_s=/,"",$i); print $i}}' <<< "$result")
        wall=$(awk '{for(i=1;i<=NF;i++) if($i~/^wall_s=/) {sub(/^wall_s=/,"",$i); print $i}}' <<< "$result")
        records=$(awk '{for(i=1;i<=NF;i++) if($i~/^records=/) {sub(/^records=/,"",$i); print $i}}' <<< "$result")
        [[ $cpu =~ ^[0-9]+[.][0-9]+$ && $wall =~ ^[0-9]+[.][0-9]+$ && $records =~ ^[1-9][0-9]*$ ]]
        cpu_samples+=("$cpu")
        wall_samples+=("$wall")
        printf 'BENCH_SAMPLE label=%s noise=%s sample=%s %s\n' "$label" "$noise" "$sample" "$result"
    done

    mapfile -t sorted_cpu < <(printf '%s\n' "${cpu_samples[@]}" | sort -n)
    mapfile -t sorted_wall < <(printf '%s\n' "${wall_samples[@]}" | sort -n)
    median=$((bench_repeats / 2))
    printf 'BENCH_SUMMARY label=%s noise=%s repeats=%s records=%s cpu_median_s=%s cpu_min_s=%s cpu_max_s=%s wall_median_s=%s\n' \
        "$label" "$noise" "$bench_repeats" "$records" "${sorted_cpu[$median]}" \
        "${sorted_cpu[0]}" "${sorted_cpu[$((bench_repeats - 1))]}" "${sorted_wall[$median]}"
}

# 首调用含懒初始化/首次注册；热重复先预热，二者不能相减当成纯注册耗时。
run_case init_dotted_0 init dotted 0 1 1
run_case init_dotted_1000 init dotted 1000 1 1
run_case repeat_defaults_0 repeat defaults 0 "$bench_repeat_iters" 1
run_case repeat_dotted_0 repeat dotted 0 "$bench_repeat_iters" 1
run_case repeat_dotted_100 repeat dotted 100 "$bench_repeat_iters" 1
run_case repeat_dotted_1000 repeat dotted 1000 "$bench_repeat_iters" 1
run_case repeat_compact_0 repeat compact 0 "$bench_repeat_iters" 1
run_case repeat_compact_1000 repeat compact 1000 "$bench_repeat_iters" 1
run_case repeat_override_0 repeat override 0 "$bench_repeat_iters" 1
run_case repeat_override_1000 repeat override 1000 "$bench_repeat_iters" 1

# 动态结构体数组保留真实 fixed/each 两阶段；不启用会改变问题性质的 unique/sort。
run_case array_128_0 array dotted 0 "$bench_array_iters" 128
run_case array_128_1000 array dotted 1000 "$bench_array_iters" 128
run_case array_1024_0 array dotted 0 "$bench_array_iters" 1024
run_case array_1024_1000 array dotted 1000 "$bench_array_iters" 1024
run_case array_override_1024_1000 array override 1000 "$bench_array_iters" 1024

# 微基准只定位成本来源，不把其耗时比例当成整个 apply 的精确热点占比。
run_case lookup_hit_0 lookup dotted 0 "$bench_micro_iters" 1
run_case lookup_hit_1000 lookup dotted 1000 "$bench_micro_iters" 1
run_case lookup_miss_0 lookup dotted 0 "$bench_micro_iters" 1 1
run_case lookup_miss_1000 lookup dotted 1000 "$bench_micro_iters" 1 1
run_case lookup_override_1000 lookup override 1000 "$bench_micro_iters" 1
run_case compact_scan compact compact 0 "$bench_micro_iters" 1

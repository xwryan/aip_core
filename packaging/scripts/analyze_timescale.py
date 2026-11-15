#!/usr/bin/env python3
# Python 3.6 compatible
"""
分析 VCS .f filelist 中所有源文件的 `timescale 单位.
支持嵌套 .f (-f / -F), 按编译顺序输出每个文件 timescale,
显示最终 sticky timescale 与所有冲突点.

用法:
    python3 analyze_timescale.py top.f [more.f ...]
    python3 analyze_timescale.py top.f -v       # verbose
    python3 analyze_timescale.py top.f -j out.json
    python3 analyze_timescale.py top.f --default 1ns/1ps
"""
import argparse
import json
import os
import re
import sys

# 匹配 `timescale <unit>/<precision>
TS_RE = re.compile(r'^\s*`\s*timescale\s+([0-9]+\s*[a-z]+)\s*/\s*([0-9]+\s*[a-z]+)',
                   re.IGNORECASE | re.MULTILINE)
RESETALL_RE = re.compile(r'^\s*`\s*resetall\b', re.IGNORECASE | re.MULTILINE)

# .f 中需忽略的选项 (后面带文件路径但非源文件)
SKIP_OPT_WITH_ARG = {'-v', '-y', '-l', '-o', '-cm_dir', '-cm_name', '-cm_log',
                     '-cm_hier', '-timescale'}
SKIP_OPT_PREFIX = ('+', '-D', '-d', '-P', '-p')


def strip_comments(line):
    for marker in ('//', '#', '--'):
        idx = line.find(marker)
        if idx >= 0:
            line = line[:idx]
    return line.strip()


def expand_filelist(path, base_dir, seen, files_out, errors):
    """递归展开 .f, 按出现顺序加入 files_out."""
    abspath = os.path.abspath(os.path.join(base_dir, path)) if not os.path.isabs(path) else path
    if abspath in seen:
        errors.append("cycle/repeat: {}".format(abspath))
        return
    seen.add(abspath)
    if not os.path.exists(abspath):
        errors.append("not found: {}".format(abspath))
        return

    new_base = os.path.dirname(abspath)
    with open(abspath, 'r', errors='replace') as fh:
        for raw in fh:
            line = strip_comments(raw)
            if not line:
                continue
            line = os.path.expandvars(line)
            tokens = line.split()
            i = 0
            while i < len(tokens):
                tok = tokens[i]
                if tok in ('-f', '-F'):
                    if i + 1 < len(tokens):
                        expand_filelist(tokens[i + 1], new_base, seen, files_out, errors)
                        i += 2
                        continue
                if tok in SKIP_OPT_WITH_ARG:
                    i += 2
                    continue
                if tok.startswith(SKIP_OPT_PREFIX):
                    i += 1
                    continue
                src_abs = os.path.abspath(os.path.join(new_base, tok)) if not os.path.isabs(tok) else tok
                if os.path.exists(src_abs):
                    files_out.append(src_abs)
                else:
                    errors.append("source not found: {} (from {})".format(tok, abspath))
                i += 1


def scan_file_timescales(path):
    """返回 [(lineno, kind, unit, prec)] 按行号排序."""
    events = []
    try:
        with open(path, 'r', errors='replace') as fh:
            text = fh.read()
    except Exception as e:
        return events
    for m in TS_RE.finditer(text):
        lineno = text[:m.start()].count('\n') + 1
        unit = re.sub(r'\s+', '', m.group(1))
        prec = re.sub(r'\s+', '', m.group(2))
        events.append((lineno, 'timescale', unit, prec))
    for m in RESETALL_RE.finditer(text):
        lineno = text[:m.start()].count('\n') + 1
        events.append((lineno, 'resetall', None, None))
    events.sort()
    return events


def parse_unit_to_fs(u):
    m = re.match(r'(\d+)(fs|ps|ns|us|ms|s)$', u)
    if not m:
        return None
    n = int(m.group(1))
    mult = {'fs': 1, 'ps': 1000, 'ns': 1000000, 'us': 1000000000,
            'ms': 1000000000000, 's': 1000000000000000}[m.group(2)]
    return n * mult


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('filelist', nargs='+', help='one or more .f files')
    ap.add_argument('-v', '--verbose', action='store_true')
    ap.add_argument('-j', '--json', help='write JSON report to this path')
    ap.add_argument('--default', default=None,
                    help='vcs -timescale 默认 (e.g. 1ns/1ps)')
    args = ap.parse_args()

    files = []
    errors = []
    for f in args.filelist:
        expand_filelist(f, os.getcwd(), set(), files, errors)

    current_unit = None
    current_prec = None
    if args.default:
        try:
            cu, cp = args.default.split('/')
            current_unit, current_prec = cu.strip(), cp.strip()
        except Exception:
            print("WARN: --default 格式应是 1ns/1ps", file=sys.stderr)

    report = []
    transitions = []
    conflicts = []

    print("=" * 100)
    print("Filelist expansion: {} source files".format(len(files)))
    if errors:
        print("ERRORS:")
        for e in errors:
            print("  ! " + e)
    print("=" * 100)
    header = "{:<60} {:<20} {}".format("FILE", "TIMESCALE@END", "EVENTS")
    print(header)
    print("-" * 100)

    for path in files:
        ext = os.path.splitext(path)[1].lower()
        if ext not in ('.sv', '.svh', '.v', '.vh'):
            continue
        events = scan_file_timescales(path)
        file_transitions = []
        for lineno, kind, u, p in events:
            if kind == 'resetall':
                file_transitions.append("L{} resetall".format(lineno))
                transitions.append((path, lineno, 'resetall', None, None))
            else:
                old = "{}/{}".format(current_unit, current_prec) if current_unit else "<default>"
                file_transitions.append("L{} `timescale {}/{} (was {})".format(lineno, u, p, old))
                if current_unit and (current_unit != u or current_prec != p):
                    conflicts.append((path, lineno, old, "{}/{}".format(u, p)))
                current_unit, current_prec = u, p
                transitions.append((path, lineno, 'timescale', u, p))

        end_ts = "{}/{}".format(current_unit, current_prec) if current_unit else "<unset>"
        rel = os.path.relpath(path)
        if args.verbose or events:
            disp = rel if len(rel) <= 60 else "..." + rel[-57:]
            print("{:<60} {:<20} {}".format(
                disp, end_ts,
                "; ".join(file_transitions) if file_transitions else "-"
            ))
        report.append({
            'file': path,
            'events': [{'line': e[0], 'kind': e[1], 'unit': e[2], 'prec': e[3]} for e in events],
            'timescale_at_end': end_ts,
        })

    print("-" * 100)
    final = "{}/{}".format(current_unit, current_prec) if current_unit else "<unset>"
    print("FINAL sticky timescale at end of compilation: {}".format(final))

    if conflicts:
        print("\nCONFLICTS (timescale 中途变化, {} 处):".format(len(conflicts)))
        for path, lineno, old, new in conflicts:
            print("  {}:{}  {} -> {}".format(os.path.relpath(path), lineno, old, new))

    worst_prec = None
    worst_loc = None
    for path, lineno, kind, u, p in transitions:
        if kind != 'timescale':
            continue
        pfs = parse_unit_to_fs(p)
        if pfs is None:
            continue
        if worst_prec is None or pfs > worst_prec:
            worst_prec = pfs
            worst_loc = (path, lineno, "{}/{}".format(u, p))
    if worst_loc:
        print("\n最差精度: {} @ {}:{}".format(worst_loc[2], os.path.relpath(worst_loc[0]), worst_loc[1]))
        print("  (1fs < 1ps < 1ns < 1us; 精度数值越大越粗糙)")

    if args.json:
        with open(args.json, 'w') as fh:
            json.dump({
                'files': report,
                'final_timescale': final,
                'conflicts': [{'file': c[0], 'line': c[1], 'from': c[2], 'to': c[3]} for c in conflicts],
                'errors': errors,
            }, fh, indent=2)
        print("\nJSON written: {}".format(args.json))

    return 1 if conflicts or errors else 0


if __name__ == '__main__':
    sys.exit(main())

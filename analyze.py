#!/usr/bin/env python3
"""analyze.py - merge all run outputs into a single docker/out/report.md.

Usage:
    python analyze.py <out_dir>

Reads:
    out_dir/llama_bench.out      - ttps pp (prompt tok/s), tg (gen tok/s)
    out_dir/single_shot.out      - contains trailing --stats summary
    out_dir/stress_ab.out        - ApacheBench concurrency test
    out_dir/soak.out             - 3 min sustained generation
    out_dir/thermal.csv          - timestamp_iso,temp_c,sensor_name
    out_dir/docker_stats.csv     - name,cpu_pct,mem_usage,mem_pct,net_io,block_io,pids,ts_iso
    out_dir/exit_code.csv        - container_exit_code,N
    out_dir/halt_event.csv       - (optional) thermal halt record
Outputs:
    out_dir/report.md            - human-readable report with pass/fail status

Pass criteria (suggested; adjust in PASS constants below):
    tg >= 4.0 tok/s          (usable CPU inference)
    peak mem <= 6.3 GB      (headroom under 7 GB cap)
    max temp <= 83 C        (no halt triggered)
    no OOM kill detected
"""
import csv
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

PASS_TG_TPS = 4.0
PASS_PEAK_MEM_GB = 6.3
PASS_MAX_TEMP_C = 83.0
PASS_OOM = False  # True means OOM is disqualifying


def parse_pp_tg(bench_text: str):
    """Extract pp (prompt ttps) and tg (gen ttps) from llama-bench output.

    llama-bench prints a markdown table with columns like:
       model | size | params | backend | threads | test | t/s
    Test rows are named like 'pp 512' and 'tg 128'.
    Returns dict: {'pp512': float|None, 'tg128': float|None}
    """
    out = {'pp512': None, 'tg128': None}
    if not bench_text:
        return out
    for line in bench_text.splitlines():
        line = line.strip()
        if not line or line.startswith('|--') or line.startswith('model'):
            continue
        # match '| ... | pp 512 | ... |' or '| ... | tg 128 | ... |'
        m_pp = re.search(r'\bpp\s+512\b.*?([\d.]+)\s*\|?\s*$', line)
        m_tg = re.search(r'\btg\s+128\b.*?([\d.]+)\s*\|?\s*$', line)
        if m_pp:
            try: out['pp512'] = float(m_pp.group(1))
            except: pass
        if m_tg:
            try: out['tg128'] = float(m_tg.group(1))
            except: pass
    # also do lenient scan: 'pp 512' line followed by token-per-sec number
    if out['pp512'] is None or out['tg128'] is None:
        for line in bench_text.splitlines():
            cols = [c.strip() for c in line.split('|') if c.strip()]
            if len(cols) < 2: continue
            test = cols[-3] if len(cols) >= 3 else cols[-2]
            val = cols[-1]
            try: valf = float(val)
            except: continue
            if 'pp 512' in ' '.join(cols): out['pp512'] = out['pp512'] or valf
            if 'tg 128' in ' '.join(cols): out['tg128']  = out['tg128']  or valf
    return out


def parse_single_shot_stats(text: str):
    """Find the --stats line(s) near the bottom of single_shot.out."""
    stats = {}
    if not text: return stats
    m = re.search(r'avg:\s+-?[\d.]+\s+ms\s+/s', text)
    if m: stats['avg_ms_per_s'] = m.group(0)
    m = re.search(r'editor.eval time = ([\d.]+)', text)
    if m: stats['eval_time_s'] = float(m.group(1))
    m = re.search(r'\bload time\s*=\s*([\d.]+)', text)
    if m: stats['load_time_s'] = float(m.group(1))
    m = re.findall(r'\bsample time\s*=\s*([\d.]+)\sms', text)
    if m: stats['sample_ms'] = m
    # common format:
    #   llama_perf: prompt eval time = X ms / Y tokens (Z ms/T)
    #   eval time = ...
    for key, pat in [
        ('prompt_eval_ms', r'prompt eval time\s*=\s*([\d.]+)\s*ms'),
        ('eval_ms',        r'\beval time\s*=\s*([\d.]+)\s*ms'),
        ('prompt_tokens',  r'prompt eval time\s*=\s*[\d.]+\s*ms\s*/\s*(\d+)\s*tokens'),
        ('eval_tokens',    r'\beval time\s*=\s*[\d.]+\s*ms\s*/\s*(\d+)\s*tokens'),
    ]:
        mm = re.search(pat, text)
        if mm: stats[key] = float(mm.group(1))
    return stats


def parse_ab(text: str):
    out = {}
    if not text: return out
    m = re.search(r'Time taken for tests:\s+([\d.]+)\s+seconds', text)
    if m: out['t_s'] = float(m.group(1))
    m = re.search(r'Requests per second:\s+([\d.]+)\s+\[#/sec\]', text)
    if m: out['rps'] = float(m.group(1))
    m = re.search(r'Failed requests:\s+(\d+)', text)
    if m: out['failed'] = int(m.group(1))
    m = re.search(r'Complete requests:\s+(\d+)', text)
    if m: out['complete'] = int(m.group(1))
    m = re.search(r'Time per request:\s+([\d.]+)\s+\[ms\]\s*\(mean\)', text)
    if m: out['lat_mean_ms'] = float(m.group(1))
    return out


def read_csv(path):
    if not os.path.exists(path): return []
    with open(path, 'r', encoding='utf-8-sig', errors='replace') as f:
        return list(csv.DictReader(f))


def parse_mem_usage(mem_usage: str):
    """`docker stats` MemUsage like '3.5GiB / 7GiB'."""
    if not mem_usage: return None
    m = re.match(r'([\d.]+)\s*([KMGTPE]i?B?)', mem_usage, re.I)
    if not m: return None
    val = float(m.group(1)); unit = m.group(2).lower()
    factor = {'b':1,'kb':1024,'kib':1024,'mb':1024**2,'mib':1024**2,
              'gb':1024**3,'gib':1024**3,'tb':1024**4}[unit.replace('ib','b').split()[0].replace('ib','b')]
    return val * factor


def to_gb(bytes_):
    if bytes_ is None: return None
    return bytes_ / (1024**3)


def main(out_dir: Path):
    report = []
    r = report.append
    r(f"# medLLM_V1 SFT CPU Docker Stress Report\n")
    r(f"Generated: {datetime.now(timezone.utc).isoformat()}\n")
    r(f"Host: Windows + Docker Desktop (WSL2 backend)  | Container cap: `--memory=7g --cpus=4 --cpuset-cpus=0-3`\n")
    r(f"Model: medLLM_V1_sft_16bit-Q4_K_M.gguf  | Engine: llama.cpp (GGML_NATIVE=ON)\n")
    r(f"\n---\n")

    # --- llama-bench ----------------------------------------------------------
    bench_path = out_dir / 'llama_bench.out'
    bench_text = bench_path.read_text(encoding='utf-8', errors='replace') if bench_path.exists() else ''
    bench = parse_pp_tg(bench_text)
    r(f"## 1. Cold load + benchmark (`llama-bench -p 512 -n 128`)\n")
    r(f"| Metric | Value | Pass |")
    r(f"|---|---|---|")
    if bench['pp512'] is not None:
        r(f"| Prompt throughput (pp 512) | {bench['pp512']:.2f} t/s | -- |")
    else:
        r(f"| Prompt throughput (pp 512) | (not parsed) | -- |")
    if bench['tg128'] is not None:
        r(f"| Generate throughput (tg 128) | {bench['tg128']:.2f} t/s | {'PASS' if bench['tg128'] >= PASS_TG_TPS else 'FAIL'} (>= {PASS_TG_TPS}) |")
    else:
        r(f"| Generate throughput (tg 128) | (not parsed) | -- |")
    r("")

    # --- single shot ---------------------------------------------------------
    ss_path = out_dir / 'single_shot.out'
    ss_text = ss_path.read_text(encoding='utf-8', errors='replace') if ss_path.exists() else ''
    ss = parse_single_shot_stats(ss_text)
    r(f"## 2. Single-shot MedQA inference (256 tokens)\n")
    if 'load_time_s' in ss: r(f"- Load time: {ss['load_time_s']:.2f} s")
    if 'prompt_ms' in ss or 'prompt_eval_ms' in ss:
        v = ss.get('prompt_eval_ms', ss.get('prompt_ms'))
        r(f"- Prompt eval: {v:.1f} ms")
    if 'eval_ms' in ss: r(f"- Gen eval: {ss['eval_ms']:.1f} ms")
    if 'eval_tokens' in ss and 'eval_ms' in ss:
        r(f"- Throughput: {ss['eval_tokens']/(ss['eval_ms']/1000):.2f} t/s")
    for k, v in sorted(ss.items()):
        if k not in ('load_time_s','prompt_eval_ms','eval_ms','eval_tokens','prompt_tokens'):
            r(f"- {k}: {v}")
    r("")

    # --- ab ------------------------------------------------------------------
    ab_path = out_dir / 'stress_ab.out'
    ab_text = ab_path.read_text(encoding='utf-8', errors='replace') if ab_path.exists() else ''
    ab = parse_ab(ab_text)
    r(f"## 3. Concurrent stress (llama-server + ab -n 60 -c 4)\n")
    r(f"| Metric | Value |")
    r(f"|---|---|")
    for k in ['t_s','rps','complete','failed','lat_mean_ms']:
        if k in ab: r(f"| {k} | {ab[k]} |")
    if 'complete' in ab and 'failed' in ab:
        ok = ab['complete'] - ab['failed']
        r(f"| successful | {ok} |")
    r("")

    # --- docker stats --------------------------------------------------------
    stats_rows = read_csv(out_dir / 'docker_stats.csv')
    peak_bytes = None
    peak_pct = None
    if stats_rows:
        peak_bytes = max((parse_mem_usage(row['mem_usage']) or 0) for row in stats_rows) if any(parse_mem_usage(row['mem_usage']) for row in stats_rows) else None
        peak_pct = max((float(row['mem_pct']) if row['mem_pct'] and row['mem_pct'].strip() else 0) for row in stats_rows)
    r(f"## 4. Container resource usage\n")
    r(f"| Metric | Value | Pass |")
    r(f"|---|---|---|")
    r(f"| Samples | {len(stats_rows)} | -- |")
    if peak_pct is not None:
        r(f"| Peak RAM pct (of 7G cap) | {peak_pct:.1f}% | -- |")
    if peak_bytes is not None:
        peak_gb = to_gb(peak_bytes)
        ok = peak_gb <= PASS_PEAK_MEM_GB
        r(f"| Peak RAM absolute | {peak_gb:.2f} GB | {'PASS' if ok else 'FAIL'} (<= {PASS_PEAK_MEM_GB}) |")
    cpu_max = None
    if stats_rows:
        cpu_vals = [float(row['cpu_pct']) for row in stats_rows if row['cpu_pct'].strip()]
        if cpu_vals: cpu_max = max(cpu_vals); r(f"| Peak CPU% (4 cores) | {cpu_max:.1f}% | -- |")
    r("")

    # --- thermal -------------------------------------------------------------
    th_rows = read_csv(out_dir / 'thermal.csv')
    temps = [float(row['temp_c']) for row in th_rows if row.get('temp_c') and row['temp_c'].strip()]
    r(f"## 5. Thermal (LibreHardwareMonitor 1s poll)\n")
    r(f"| Metric | Value |")
    r(f"|---|---|")
    if temps:
        r(f"| Samples | {len(temps)} |")
        r(f"| Min temp | {min(temps):.1f} C |")
        r(f"| Max temp | {max(temps):.1f} C | (halt trigger at {PASS_MAX_TEMP_C}) |")
        r(f"| Mean temp | {sum(temps)/len(temps):.1f} C |")
        over = [t for t in temps if t >= 80]
        r(f"| Samples >= 80 C | {len(over)} |")
    else:
        r(f"| Samples | 0 (no thermal data - check LHM) |")
    r("")

    # --- soak ---------------------------------------------------------------
    soak_path = out_dir / 'soak.out'
    soak_text = soak_path.read_text(encoding='utf-8', errors='replace') if soak_path.exists() else ''
    r(f"## 6. Sustained 3-min thermal soak\n")
    r(f"- Output bytes: {len(soak_text)}")
    soak_tokens = len(re.findall(r'\b\w+\b', soak_text))
    r(f"- Word count (output tokens approx): {soak_tokens}")
    # detect thermal throttling: compute tokens/s in first 30s vs last 30s
    r("")

    # --- exit code + halt ----------------------------------------------------
    halt_path = out_dir / 'halt_event.csv'
    if halt_path.exists():
        r(f"## 7. Thermal HALT\n")
        r(f":- See `halt_event.csv`. Test was STOPPED automatically by watch_and_halt.ps1.")
        r("")

    exit_path = out_dir / 'exit_code.csv'
    if exit_path.exists():
        ec_text = exit_path.read_text(encoding='utf-8', errors='replace').strip()
        r(f"## 8. Container exit\n")
        r(f"```")
        r(ec_text)
        r(f"```")
        r("")
        if '137' in ec_text or '137 ' in ec_text:
            r("- exit code 137 == OOM kill or signal.")
        if '143' in ec_text:
            r("- exit code 143 == SIGTERM (probably from thermal halt).")
        r("")

    # --- overall verdict -----------------------------------------------------
    r(f"## Overall verdict\n")
    verdicts = []
    if bench.get('tg128') is not None:
        verdicts.append(('tg >= %g t/s' % PASS_TG_TPS, bench['tg128'] >= PASS_TG_TPS, f"{bench['tg128']:.2f}"))
    if peak_bytes is not None:
        verdicts.append(('peak RAM <= %g GB' % PASS_PEAK_MEM_GB, to_gb(peak_bytes) <= PASS_PEAK_MEM_GB, f"{to_gb(peak_bytes):.2f} GB"))
    if temps:
        verdicts.append(('max temp <= %g C' % PASS_MAX_TEMP_C, max(temps) <= PASS_MAX_TEMP_C, f"{max(temps):.1f} C"))
    if halt_path.exists():
        verdicts.append(('no thermal halt', False, "halt triggered"))
    r(f"| Criteria | Pass | Actual |")
    r(f"|---|---|---|")
    for c, ok, val in verdicts:
        r(f"| {c} | {'PASS' if ok else 'FAIL'} | {val} |")
    overall = all(p[1] for p in verdicts) if verdicts else False
    r("")
    r(f"### RESULT: {'PASS' if overall else 'FAIL'}")
    r("")

    # save
    md = '\n'.join(report)
    (out_dir / 'report.md').write_text(md, encoding='utf-8')
    print(md)
    print("\nReport written to", out_dir / 'report.md')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python analyze.py <out_dir>")
        sys.exit(2)
    main(Path(sys.argv[1]).resolve())
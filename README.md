# llm-cpu-stress-test

Test whether your Windows laptop can run a quantized LLM (GGUF format) under
constrained resources — CPU-only inference, limited RAM, with a **thermal
governor** that auto-kills the container if your CPU gets too hot.

Works with **any GGUF model** supported by `llama.cpp` (Qwen, Llama, Mistral,
Phi, etc.). Just drop your `.gguf` file into the folder and run.

> **You bring the model. The repo provides everything else.**

---

## What it does

This repo runs your GGUF model inside a Docker container with resource caps
that emulate a constrained laptop (default: 7 GB RAM, 4 CPU cores). While the
model runs four test stages, three host-side monitors record what happens:

| Stage | What it does | What you get |
|---|---|---|
| 1. Single-shot inference | Sends a real medical prompt (MedQA USMLE sample) to the model and captures its text answer | The model's actual reasoning + answer in `single_shot.out` |
| 2. Cold load + benchmark | Runs `llama-bench` to measure prompt and generation throughput | Tokens/sec table in `llama_bench.out` |
| 3. Concurrent stress | Starts `llama-server`, fires 30 parallel requests with medical prompts | Latency + throughput metrics + saved responses |
| 4. Thermal soak | 3-minute sustained generation on a long medical prompt | Output text + temperature curve over time |

In parallel, the host collects:

- **CPU package temperature** every 1 second from [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
- **Container RAM/CPU** usage every 2 seconds from `docker stats`
- **Thermal governor** that kills the container if CPU hits 83 °C (your safety net)

At the end, `analyze.py` merges everything into `out/report.md` with a pass/fail
verdict.

---

## What you need to bring

| Requirement | Version | Why |
|---|---|---|
| **Windows 10/11** | any | PowerShell 5.1+ ships with it; scripts use `Start-Job`, `Invoke-RestMethod` |
| **Docker Desktop** | recent | With WSL2 backend enabled. Verify with `docker ps` |
| **LibreHardwareMonitor** | latest | For CPU temperature readings. Free, open-source |
| **Python 3** | 3.8+ | For the report generator (`analyze.py`) |
| **A GGUF model file** | any GGUF | The quantized model you want to test |

No GPU, no CUDA, no Linux dual-boot required.

---

## Quick start (one command)

If you've already done the one-time setup below (Docker, LibreHardwareMonitor,
Python installed), the fastest path is the **`run.ps1` bootstrap script** — it
checks all prerequisites, prompts for anything missing, auto-builds the Docker
image on first run, and runs the test:

```powershell
git clone https://github.com/david-shina/llm-cpu-stress-test.git
cd llm-cpu-stress-test
# drop your model.gguf in this folder (or let run.ps1 prompt you for the path)
.\run.ps1
```

`run.ps1` will:
1. Verify Docker, Python, and LibreHardwareMonitor are reachable
2. Prompt for the LHM API URL if `localhost:8085` doesn't respond
3. Prompt for your GGUF path if none is found in the folder
4. Auto-build the Docker image if it isn't built yet (~10 min, first time only)
5. Prompt you to choose **Smoke** (single prompt, ~2 min) or **Full** (4 stages, 3–6 min)
6. Run the test and print the path to `out\report.md`

Non-interactive mode (skip all prompts):

```powershell
.\run.ps1 -Smoke -LhmApiUrl "http://localhost:8085/data.json" -GgufPath ".\model.gguf"
```

Prefer the manual step-by-step? Continue to the next section.

---

## Complete step-by-step usage

### Phase A — One-time setup (~15 minutes, do this once)

#### A1. Install Docker Desktop

1. Download from <https://www.docker.com/products/docker-desktop/>
2. Install with the **WSL2 backend** enabled (it's the default)
3. Launch it and wait until the whale icon in the system tray says "Docker Desktop is running"
4. Verify in PowerShell:
   ```powershell
   docker ps
   ```
   If you see a table header (even an empty one), you're good.

#### A2. Install LibreHardwareMonitor

1. Download the latest release zip from
   <https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases>
2. Extract it to a permanent location, e.g. `C:\Tools\LibreHardwareMonitor\`
3. **Right-click `LibreHardwareMonitor.exe` → Run as administrator**
   (Required — without admin rights it cannot read CPU thermal sensors.)
4. In the app: **Options → Web Server**
   - Check **Enable built-in web server**
   - Set **Port** to `8085`
   - Click **OK**
5. Verify in your browser: open `http://localhost:8085/data.json`
   - You should see JSON with sensor data
   - Expand the CPU node in the LHM main window and confirm a **Package** row
     exists under **Temperatures**

#### A3. Install Python 3

1. Download from <https://www.python.org/downloads/>
2. During install, check **"Add Python to PATH"**
3. Verify in a new PowerShell window:
   ```powershell
   python --version
   ```

#### A4. Find your host IP (for the LHM API)

The scripts connect to LHM over HTTP. On most setups `localhost` works, but if
Docker's WSL2 network interferes you may need your LAN IP instead.

```powershell
ipconfig | findstr "192.168"
```

Use whichever IPv4 address appears (e.g. `192.168.1.223`). You'll pass this to
the scripts as `-LhmApiUrl "http://YOUR_IP:8085/data.json"`.

If `localhost:8085` works in your browser, you can also just use:
```
-LhmApiUrl "http://localhost:8085/data.json"
```

#### A5. Get this repo

Either clone it:
```powershell
git clone https://github.com/<owner>/llm-cpu-stress-test.git
cd llm-cpu-stress-test
```

Or download the ZIP from the GitHub page and extract it.

#### A6. Provide your GGUF model

Place your `.gguf` file in the repo folder and rename it to `model.gguf`:

```powershell
# Example: copy your downloaded GGUF here
copy "C:\Users\me\Downloads\my-model-Q4_K_M.gguf" ".\model.gguf"
```

Alternatively, you can keep it anywhere and pass `-GgufPath` to the run script.

### Phase B — Build the Docker image (~10 minutes, do this once)

```powershell
.\build.ps1
```

This compiles `llama.cpp` from source inside an `ubuntu:22.04` container with
your CPU's native instruction set (AVX2, AVX-VNNI, etc.). The resulting image
is tagged `llm-cpu-test:latest` and is about 2 GB.

You only need to re-run this if you edit the `Dockerfile` or update `llama.cpp`.

Verify it built:

```powershell
docker images | findstr llm-cpu-test
```

You should see `llm-cpu-test:latest`.

### Phase C — Preflight check (5 seconds, do this before every run)

Confirm LibreHardwareMonitor is running and reachable before starting a real
test. This avoids wasting 5 minutes only to discover LHM stopped:

```powershell
.\check_lhm.ps1 -ApiUrl "http://<your-IP>:8085/data.json"
```

Expected:

```
OK: CPU package temp sensor = 'CPU Package' -> 62.0 C
LHM preflight PASSED.
```

If it fails, see [Troubleshooting](#troubleshooting).

### Phase D — Run the test

> **Shortcut:** `.\run.ps1` does Phases B, C, D, and E in one go (and prompts
> for anything missing). The steps below are the manual equivalent.

You have **two modes**:

#### D1. Full test (with thermal governor — recommended)

Runs all four stages. If the CPU hits 83 °C at any point, the governor
automatically kills the container and writes `halt_event.csv`. The test still
completes and generates a report (marked FAIL).

```powershell
.\run_test.ps1 -LhmApiUrl "http://<your-IP>:8085/data.json"
```

Expected runtime: 3–6 minutes (unless halted early by the governor).

#### D2. Smoke test (governor disabled)

Runs only stage 1 (one MedQA prompt, 500-token response). No halt. You get the
model's actual text answer. Useful for verifying the model works before
committing to a full run. Expected runtime: 1–2 minutes.

```powershell
.\run_test.ps1 -Smoke -LhmApiUrl "http://<your-IP>:8085/data.json"
```

> **Warning:** Smoke mode will not stop the container if temperatures get
> dangerous. If you see temps above 90 °C in `thermal.csv`, stop the container
> manually with `docker stop llm-stress` or `.\clean.ps1`.

### Phase E — Read the results

```powershell
cat .\out\report.md
```

Key lines at the bottom:

```
## Overall verdict

| Criteria | Pass | Actual |
|---|---|---|
| peak RAM <= 6.3 GB | PASS | 1.87 GB |
| max temp <= 83 C   | FAIL | 100.0 C |

### RESULT: FAIL
```

To see the model's actual answer to the medical prompt:

```powershell
cat .\out\single_shot.out
```

To see throughput metrics:

```powershell
cat .\out\llama_bench.out
```

### Phase F — Clean up (between runs)

```powershell
.\clean.ps1
```

This stops and removes the container and clears all output files in `out/`.

---

## All parameters

`run_test.ps1` accepts these parameters. All have defaults — you only need to
override what's different on your machine:

| Parameter | Default | What it controls |
|---|---|---|
| `-GgufPath` | `.\model.gguf` | Path to your `.gguf` model file |
| `-Image` | `llm-cpu-test:latest` | Docker image name (rarely changed) |
| `-Container` | `llm-stress` | Container name (rarely changed) |
| `-MemoryGB` | `7` | Docker `--memory` cap in GB |
| `-Cpus` | `4` | Docker `--cpus` cap |
| `-CpuSet` | `0-3` | Which physical CPU cores to pin (`--cpuset-cpus`) |
| `-WarnTempC` | `80` | Temperature to start warning (>= °C) |
| `-HaltTempC` | `83` | Temperature to auto-kill container (>= °C) |
| `-LhmApiUrl` | `http://localhost:8085/data.json` | LibreHardwareMonitor web API URL |
| `-Smoke` | (off) | Switch: skip governor + only run stage 1 |

### Examples

```powershell
# Different model file
.\run_test.ps1 -GgufPath "D:\models\my-model-q4_k_m.gguf" -LhmApiUrl "http://192.168.1.50:8085/data.json"

# Tighter RAM cap (for a 6 GB laptop target)
.\run_test.ps1 -MemoryGB 6 -LhmApiUrl "http://localhost:8085/data.json"

# Lower the halt threshold to be extra cautious
.\run_test.ps1 -HaltTempC 78 -WarnTempC 75 -LhmApiUrl "http://localhost:8085/data.json"

# Pin only 2 cores
.\run_test.ps1 -Cpus 2 -CpuSet "0-1" -LhmApiUrl "http://localhost:8085/data.json"

# Smoke test with a different model
.\run_test.ps1 -Smoke -GgufPath "C:\models\other.gguf" -LhmApiUrl "http://localhost:8085/data.json"
```

---

## Output files

All outputs are written to `out/`. `clean.ps1` wipes this folder.

| File | Format | Contents |
|---|---|---|
| `report.md` | Markdown | Auto-generated summary with pass/fail verdict |
| `thermal.csv` | CSV | `timestamp_iso,temp_c,sensor_name` — one row per second |
| `docker_stats.csv` | CSV | `name,cpu_pct,mem_usage,mem_pct,net_io,block_io,pids,ts_iso` — one row per 2 seconds |
| `single_shot.out` | Text | Stage 1: prompt + model's reasoning + final answer + throughput footer |
| `llama_bench.out` | Text | Stage 2: raw `llama-bench` throughput table |
| `stress_server.log` | Text | Stage 3: `llama-server` startup log |
| `stress_responses.jsonl` | Text | Stage 3: actual model responses to 30 concurrent medical prompts |
| `stress_ab.out` | Text | Stage 3: ApacheBench summary (latency, throughput) |
| `ab_latency.csv` | CSV | Stage 3: ApacheBench percentile latency table |
| `soak.out` | Text | Stage 4: 3-minute sustained medical generation |
| `exit_code.csv` | CSV | Container exit code (0 ok, 137 OOM, 143 SIGTERM) |
| `halt_event.csv` | CSV | Only present if governor halted the test — timestamp + temp |
| `watch.log` | Text | Governor activity log (when it warned, when it halted) |
| `error.log` | Text | Only present if model file wasn't found |

---

## Pass / fail criteria

`analyze.py` checks these and prints a verdict at the bottom of `report.md`:

| Criterion | Threshold | Why |
|---|---|---|
| Generation throughput | `tg >= 4 tok/s` | Below this is unusable for interactive chat |
| Peak RAM | `<= 6.3 GB` | Leaves headroom under the 7 GB container cap |
| Max CPU package temp | `<= 83 °C` | Governor halts at 83; 85 is the disqual cap |
| Container exit code | `0` (or `143` if governor halted) | `137` = OOM kill |

Adjust the thresholds in `analyze.py` (the `PASS_*` constants at the top of the
file) if your situation allows different limits.

---

## Reducing CPU overhead

If your laptop runs too hot under the default settings, edit `llm_run.sh`:

| Lever | Default | Try | Tradeoff |
|---|---|---|---|
| `THREADS` | `2` | `1` | ~half the heat, ~half the speed |
| `CTX` (context) | `2048` | `1024` or `512` | Less RAM and attention CPU; shorter max prompt |
| `-b` (batch) | (default) | `512` | Slower prompt eval; calmer spikes |
| `-ub` (ubatch) | (default) | `64` | Smaller physical batch |
| `--load-mode` | `auto` | `mlock` | Predictable CPU, longer load time |
| `-CpuSet` (in `run_test.ps1`) | `0-3` | E-core indices (e.g. `6-9` on Intel hybrid) | Much cooler, ~3× slower |
| Quantization | Q4_K_M | Q3_K_S or Q2_K (re-quantize your model) | Less memory traffic, accuracy loss |

See the [llama.cpp documentation](https://github.com/ggerganov/llama.cpp) for
the full list of inference flags.

---

## Thermal safety

The thermal safety system has three layers, in order of precedence:

### 1. Pre-run cooldown

`run_test.ps1` waits up to 3 minutes before starting the test until idle CPU
temperature drops below 75 °C. If it doesn't cool down in time, the test
proceeds anyway with a warning.

### 2. Live governor (`watch_and_halt.ps1`)

Host-side script that tails `thermal.csv` every 700 ms. When the CPU package
temperature reaches the halt threshold (default 83 °C):

1. Writes `halt_event.csv` with the offending timestamp and temperature
2. Runs `docker stop -t 0 llm-stress` (SIGKILL — immediate, no grace period)
3. Logs to `watch.log` and exits

The governor runs on the **host** (not inside the container) so the container's
CPU load cannot starve it.

### 3. In-container timeout

Stage 4 (thermal soak) runs inside `timeout 180` inside the container. Even
if the governor fails, the soak stage ends after 3 minutes on its own.

### Emergency override

If the container gets stuck or you need to stop it instantly:

```powershell
docker stop -t 0 llm-stress
```

Or:

```powershell
.\clean.ps1
```

---

## Troubleshooting

### `docker: failed to connect to the daemon`

Docker Desktop isn't running. Launch it from the Start Menu and wait until the
system tray icon says "running". Then retry `docker ps`.

### `LHM preflight: FAIL: cannot reach LibreHardwareMonitor API`

LibreHardwareMonitor isn't running, or its web server is off.

1. Right-click `LibreHardwareMonitor.exe` → **Run as administrator**
2. In LHM: **Options → Web Server** → ensure enabled on port **8085**
3. Confirm `http://localhost:8085/data.json` loads in your browser
4. If using a LAN IP (e.g. `192.168.1.50`), confirm that IP still matches:
   ```powershell
   ipconfig | findstr "192.168"
   ```

### `LHM preflight: FAIL: no CPU package temperature sensor found`

LHM is running but can't read the CPU package temperature. Usually means LHM
wasn't launched as administrator. Close it, right-click → Run as administrator,
and retry.

### `Model GGUF not found at .\model.gguf`

You haven't provided a model file. Either:

```powershell
# Option 1: rename your file to model.gguf in this folder
copy "C:\path\to\your.gguf" ".\model.gguf"

# Option 2: pass the path explicitly
.\run_test.ps1 -GgufPath "C:\path\to\your.gguf" -LhmApiUrl "http://localhost:8085/data.json"
```

### `Image 'llm-cpu-test:latest' not found`

You haven't built the image yet:

```powershell
.\build.ps1
```

### Container exits with code 137

OOM kill — the container ran out of RAM. The model is bigger than the cap, or
the KV cache grew too large. Lower the context size by editing `CTX=2048` in
`llm_run.sh` to `CTX=1024` or smaller. Or raise the cap:

```powershell
.\run_test.ps1 -MemoryGB 8 -LhmApiUrl "http://localhost:8085/data.json"
```

### Governor never halts even though temps are high

Make sure you're using the actual LHM URL. If `localhost:8085` doesn't return
data, the collector writes empty rows and the governor has nothing to read.

Check `out/watch.log` — if it shows `first samples - temp=...` the governor is
working. If it never logs, the collector isn't reaching LHM.

### Container hangs forever

`llama-cli` can wait on stdin if `--single-turn` isn't set or gets removed
during a script edit. Open another PowerShell window and run:

```powershell
.\clean.ps1
```

### PowerShell jobs not terminating

`clean.ps1` writes a `STOP.collect` sentinel file that all three background
loops check. If a job still hangs, restart PowerShell.

### `python` not found

Python isn't on your PATH. Either install it from <https://python.org> and
restart PowerShell, or skip the report generation and read the raw outputs in
`out/` directly.

### Wrong IP (LHM was working yesterday, fails today)

Your LAN IP may have changed. Re-run `ipconfig | findstr 192.168` and update
the `-LhmApiUrl` parameter accordingly. Or use `localhost` if LHM is on the
same machine.

---

## File reference

```
llm-cpu-stress-test/
├── README.md              This file
├── LICENSE                MIT
├── .gitignore             Excludes out/, logs, *.gguf
├── run.ps1                One-shot bootstrap (start here — runs all the steps for you)
├── Dockerfile             Builds the llm-cpp image (ubuntu:22.04 + llama.cpp compiled from source)
├── build.ps1              Wraps `docker build` (run once, or let run.ps1 auto-invoke)
├── run_test.ps1           Main orchestrator — run.ps1 delegates to this
├── check_lhm.ps1          Preflight — verifies LHM is reachable (run.ps1 auto-invokes)
├── collect_thermal.ps1    Background job — writes thermal.csv every 1 second
├── watch_and_halt.ps1     Background job — kills container at halt temperature
├── analyze.py             Merges all outputs into out/report.md
├── clean.ps1              Stops container + wipes out/ folder
├── llm_run.sh             Runs INSIDE the container — the 4-stage test sequence
├── prompts/
│   └── medqa_sample.txt   MedQA USMLE prompt for stage 1
└── out/                   All outputs land here (created automatically, gitignored)
    ├── report.md
    ├── thermal.csv
    ├── docker_stats.csv
    ├── single_shot.out
    ├── llama_bench.out
    ├── stress_*.log/.out/.jsonl
    ├── soak.out
    ├── halt_event.csv     (only if governor halted)
    └── watch.log
```

---

## Known limitations

1. **Docker caps limit quantity, not quality.** Setting `--cpus=4` limits the
   container to 4 cores, but the per-core speed is still that of your host CPU.
   If your host is a 12th-gen i7, your numbers will be faster than what a real
   10th-gen i5 would produce. Treat throughput numbers as an **upper bound**
   for a less powerful CPU.

2. **Thermal behavior is host-specific**. A thicker laptop with better cooling
   will run cooler than a thin-and-light even with the same CPU. The 85 °C
   disqual cap should still be respected regardless — the governor enforces it
   automatically with a 2 °C safety margin (halts at 83 °C).

3. **llama.cpp runs text-only**. If your model is multimodal (vision + text,
   like Qwen3.5-VL), only the text pathway is exercised. The vision encoder
   isn't part of this test.

4. **`--cpuset-cpus=0-3`** picks cores 0–3 as numbered by the Windows/WSL2
   scheduler. On Intel hybrid CPUs (12th gen+), these are typically P-cores
   (performance cores). To use E-cores instead, try `-CpuSet "6-9"` or similar
   and verify via LibreHardwareMonitor's Clocks view.

5. **Single MedQA sample is not an accuracy benchmark**. The model answering
   one USMLE question correctly (or incorrectly) tells you nothing about its
   real medical accuracy. To measure accuracy, run the full MedQA test set
   (1273 items) with `lm-evaluation-harness` or a similar framework. This repo
   is for capacity and thermal feasibility, not for benchmarking medical
   accuracy.

6. **Stage 4 thermal soak is capped at 3 minutes**. The `timeout 180` inside
   `llm_run.sh` ends it after 3 minutes even if the model hasn't finished
   generating. This is a safety feature; raise it in the script if you want
   longer sustained load (but watch the temperature).

7. **`docker stats` reports container RSS, not total memory pressure.** Under
   WSL2 + Docker Desktop, the reported memory may understate real usage
   because the OS page cache for mmap'd weights is shared with the host kernel.
   For a more accurate "real footprint" estimate on a true Linux laptop, add
   the GGUF file size (~2.5 GB for a 4B Q4_K_M model) plus KV cache to the
   reported peak RAM.

---

## License

MIT — see [LICENSE](LICENSE).
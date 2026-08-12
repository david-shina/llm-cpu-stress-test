#!/usr/bin/env bash
# llm_run.sh - runs INSIDE the llm-cpu-test container.
# Executes inference tests with real medical prompts and collects metrics.
#
# Stages (reordered: single-shot inference FIRST so we capture text output
# before thermal governor can halt):
#   1. single-shot MedQA inference (cool; -t 2; -n 200)  - actual model text
#   2. cold load + bench      (llama-bench: pp/tg tok/s, mem weights)  - throughput
#   3. concurrent prompt stress (llama-server + ab with medical prompts)
#   4. sustained thermal soak  (llama-cli -n 2048, 3 min cap) with prompt
#
# Thermal-aware: uses 2 threads to slow heat ramp and give the host-side
# governor (halts container at 83C) more time to react. Trade-off: ~half the
# tok/s, but doubles the wall-time before halt triggers.
#
# Outputs under /out (mounted volume, see run_test.ps1):
#   single_shot.out   - actual model response to MedQA prompt + --stats
#   llama_bench.out   - raw llama-bench throughput table
#   stress_server.log - llama-server stdout
#   stress_responses.jsonl - actual model responses to stress requests
#   stress_ab.out     - ab output (concurrent request metrics)
#   soak.out          - 3-min sustained generation with a medical prompt
#
# Runs as container ENTRYPOINT. Aborts early if model file missing.

set -euo pipefail

MODEL="/models/medLLM_V1_sft_16bit-Q4_K_M.gguf"
OUT="/out"
THREADS=2
CTX=2048
MODE="${MODE:-full}"

mkdir -p "$OUT"

if [[ ! -f "$MODEL" ]]; then
    echo "FATAL: model GGUF not found at $MODEL" | tee "$OUT/error.log"
    exit 2
fi

echo_t() { date -u +"%Y-%m-%dT%H:%M:%SZ $1"; }

# === Stage 1: Single-shot MedQA inference (actual model text output) ========
echo_t "=== stage 1: single-shot MedQA inference (-t $THREADS, -n 200) ==="
if [[ -f /test/prompts/medqa_sample.txt ]]; then
    PROMPT="$(cat /test/prompts/medqa_sample.txt)"
else
    PROMPT="You are a medical assistant. Summarize the management of acute pancreatitis."
fi
{
    echo_t "begin"
    echo "=== PROMPT ==="
    echo "$PROMPT"
    echo "=== RESPONSE ==="
    llama-cli -m "$MODEL" -t "$THREADS" -c "$CTX" -n 500 --temp 0.7 \
        --color off --single-turn -p "$PROMPT"
} > "$OUT/single_shot.out" 2>&1
echo_t "stage1 done"

# In smoke mode, only stage 1 runs - we just want the model's response.
if [[ "$MODE" == "smoke" ]]; then
    echo_t "MODE=smoke -> exiting after stage 1 (single-shot)"
    exit 0
fi

# === Stage 2: cold load + llama-bench (throughput table) ====================
echo_t "=== stage 2: cold load + llama-bench (-t $THREADS) ==="
{ echo_t "begin"; time llama-bench -m "$MODEL" -p 256 -n 64 -t "$THREADS" ; } > "$OUT/llama_bench.out" 2>&1
echo_t "stage2 done"

# === Stage 3: concurrent prompt stress (server + ab with medical prompts) ===
echo_t "=== stage 3: concurrent prompt stress ==="
llama-server -m "$MODEL" -t "$THREADS" -c "$CTX" --port 8080 --host 0.0.0.0 > "$OUT/stress_server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 30); do
    if curl -s http://127.0.0.1:8080/health >/dev/null 2>&1; then break; fi
    sleep 1
done

# A second, different medical prompt for the stress workload.
cat > /tmp/post1.json <<'JSON'
{"prompt": "A 65-year-old male presents with crushing substernal chest pain, diaphoresis, and dyspnea. ECG shows ST elevation in leads II, III, aVF. What is the diagnosis and immediate management?", "n_predict": 96, "temperature": 0.7, "threads": 2}
JSON
cat > /tmp/post2.json <<'JSON'
{"prompt": "List the indications for initiating dialysis in acute kidney injury (AEIOU).", "n_predict": 96, "temperature": 0.7, "threads": 2}
JSON

# Alternate between the two prompts and save each response, not just metrics.
{
    echo_t "begin stress (30 requests, 3 concurrent)"
    for i in $(seq 1 15); do
        curl -s -X POST -H "Content-Type: application/json" -d @/tmp/post1.json http://127.0.0.1:8080/completion
        echo ""
        curl -s -X POST -H "Content-Type: application/json" -d @/tmp/post2.json http://127.0.0.1:8080/completion
        echo ""
    done
} > "$OUT/stress_responses.jsonl" 2>&1 &

# Also run `ab` for proper latency/throughput metrics on the same endpoint.
{ echo_t "begin ab"; ab -n 30 -c 3 -p /tmp/post1.json -T application/json -s 120 -e "$OUT/ab_latency.csv" http://127.0.0.1:8080/completion ; } > "$OUT/stress_ab.out" 2>&1
wait
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
echo_t "stage3 done"

# === Stage 4: sustained thermal soak with a medical prompt ==================
echo_t "=== stage 4: sustained 3-min thermal soak with prompt (-t $THREADS) ==="
{
    echo_t "begin soak"
    echo "=== PROMPT ==="
    echo "Generate a comprehensive review of community-acquired pneumonia: organisms, clinical criteria, severity scores (CURB-65, PSI), empiric antibiotic therapy for inpatients, outpatient treatment options, and indications for ICU admission. Cover pediatric, adult, and elderly considerations. Continue in detail."
    echo "=== RESPONSE ==="
    timeout 180 llama-cli -m "$MODEL" -t "$THREADS" -c "$CTX" -n 8192 --temp 0.7 \
        --single-turn \
        -p "Generate a comprehensive review of community-acquired pneumonia: organisms, clinical criteria, severity scores (CURB-65, PSI), empiric antibiotic therapy for inpatients, outpatient treatment options, and indications for ICU admission. Cover pediatric, adult, and elderly considerations. Continue in detail."
} > "$OUT/soak.out" 2>&1
echo_t "stage4 done"

echo_t "=== all stages complete ==="
echo_t "llm_run.sh exit"
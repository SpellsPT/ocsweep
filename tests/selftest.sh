#!/usr/bin/env bash
# tests/selftest.sh — checks ocsweep's logic WITHOUT touching a GPU (no clocks changed, no load, no sudo).
# Run it after copying ocsweep to a new machine, and after any edit:   ./tests/selftest.sh
set -uo pipefail
D=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "  ok    $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }
fn()  { sed -n "/^$1() {/,/^}/p" "$D/ocsweep"; }     # pull one function out of the main script

echo "1. scripts parse"
for f in ocsweep ocsweep-runner ocsweep-apply build.sh install-service.sh tests/selftest.sh; do
  bash -n "$D/$f" 2>"$T/err" && ok "$f" || bad "$f: $(head -1 "$T/err")"
done

echo "1b. Python embedded in the scripts compiles"
awk -v dir="$T" '/<<.PY.$/ {n++; f=dir "/emb" n ".py"; on=1; next} /^PY$/ {on=0} on {print > f}' "$D/ocsweep" "$D/ocsweep-apply"
for f in "$T"/emb*.py; do python3 -m py_compile "$f" 2>"$T/err" && ok "embedded block $(basename "$f")" || bad "embedded python: $(tail -1 "$T/err")"; done

echo "2. memory step schedule and search (simulated cards)"
{ fn mem_step; fn mem_next; } > "$T/mn.sh"
sim() {  # sim LIMIT PASS FAIL → the offsets tested and the highest pass, for a card that fails above LIMIT
  bash -c '
    source "$1"; MEM_START=500; MEM_STEPS="0:500 2000:200 2400:100 2600:50"; MEM_CEIL=5000; MEM_RES=50
    declare -A S=([mem_pass]=$3); [ -n "$4" ] && S[mem_fail]=$4; sget() { echo "${S[$1]:-}"; }
    seq=""; while n=$(mem_next); [ "$n" != done ]; do
      [ $((n % 2)) -eq 0 ] || { echo "ODD $n"; exit; }
      if [ "$n" -le "$2" ]; then S[mem_pass]=$n; seq+="$n+ "; else S[mem_fail]=$n; seq+="$n- "; fi
    done; echo "$seq| ${S[mem_pass]}"' _ "$T/mn.sh" "$@"
}
r=$(sim 3920 0 "");  [[ "$r" == *"| 3900" ]] && ok "fresh card, limit 3920 → 3900  ($r)" || bad "limit 3920: $r"
r=$(sim 2680 2500 2750); [[ "$r" == *"| 2650" ]] && ok "resume 2500 ok / 2750 bad, limit 2680 → 2650  ($r)" || bad "resume: $r"
r=$(sim 1800 0 "");  h=${r##*| }; [ "$h" -gt 1750 ] && [ "$h" -le 1800 ] && ok "limit 1800 (coarse zone) → $h, within 50  ($r)" || bad "limit 1800: $r"
r=$(sim 9999 0 "");  [[ "$r" == *"| 5000" ]] && ok "never fails → stops at the 5000 ceiling" || bad "ceiling: $r"
r=$(sim 2625 2500 2750); [[ "$r" != *ODD* ]] && ok "offsets are always even" || bad "odd offset: $r"

echo "3. bandwidth must scale with the memory clock (EDC retry detection)"
fn bw_ok > "$T/bw.sh"
bw() { bash -c 'source "$1"; BW_NOISE=0.005; BASE=$2; sget() { echo "$BASE"; }; bw_ok "$3" "$4" "$5" "$6"' _ "$T/bw.sh" "$@"; }
bw 7001 345.32 343.03 2400 2500 && ok "real data: +0.67 % bandwidth for +0.6 % clock passes" || bad "real scaling rejected"
bw 7001 300.5 300.0 1000 1500   && bad "flat bandwidth over +500 accepted" || ok "flat bandwidth over a +500 step fails"
bw 7001 344.2 345.32 2500 2550  && ok "0.3 % dip on a tiny step is noise" || bad "noise rejected"

echo "4. a test that leaves a helper process behind cannot hang the sweep"
{ fn run_test; } > "$T/rt.sh"
start=$(date +%s)
out=$(timeout 30 bash -c 'source "$1"; RUN="$2"; UUID=none; run_test "$2" "$2/log" 20 bash -c "sleep 300 & echo helper-started; exit 7"; echo "rc=$?"' _ "$T/rt.sh" "$T")
[ "$out" = "rc=7" ] && [ $(( $(date +%s) - start )) -lt 10 ] && ok "returns at once with the test's exit code" || bad "run_test: '$out'"
if ps -eo args | awk '$1=="sleep" && $2=="300"' | grep -q .; then bad "leftover helper still running"; else ok "leftover helper killed"; fi

echo "4b. apply decisions (the real ocsweep-apply logic against a FAKE driver — no GPU touched)"
mkdir -p "$T/fake/bin"
cat > "$T/fake/pynvml.py" <<'FAKE'
import json, os
S = json.load(open(os.environ["FAKE_STATE"]))          # {"cards": [{"uuid","mem","core"}], "writes": []}
def _save(): json.dump(S, open(os.environ["FAKE_STATE"], "w"))
def nvmlInit(): pass
def nvmlDeviceGetCount(): return len(S["cards"])
def nvmlDeviceGetHandleByIndex(i): return i
def nvmlDeviceGetUUID(h): return S["cards"][h]["uuid"]
def nvmlDeviceGetPersistenceMode(h): return 1
def nvmlDeviceSetPersistenceMode(h, v): pass
def nvmlDeviceGetMemClkVfOffset(h): return S["cards"][h]["mem"]
def nvmlDeviceGetGpcClkVfOffset(h): return S["cards"][h]["core"]
def nvmlDeviceSetMemClkVfOffset(h, v): S["cards"][h]["mem"] = v; S["writes"].append(f"{h}:mem={v}"); _save()
def nvmlDeviceSetGpcClkVfOffset(h, v): S["cards"][h]["core"] = v; S["writes"].append(f"{h}:core={v}"); _save()
FAKE
printf '#!/bin/sh\nprintf "%%s\\n" $FAKE_BUSY\n' > "$T/fake/bin/nvidia-smi"; chmod +x "$T/fake/bin/nvidia-smi"
awk -v f="$T/apply.py" '/<<.PY.$/ {on=1; next} /^PY$/ {on=0} on {print > f}' "$D/ocsweep-apply"
scen() {  # scen "why" BUSY_UUIDS WHEN_BUSY FAIL_UNMAPPED CARDS_JSON MAP_JSON EXPECT_RC EXPECT_WRITES
  echo "{\"cards\": $5, \"writes\": []}" > "$T/fs.json"; echo "$6" > "$T/map.json"
  out=$(FAKE_STATE="$T/fs.json" FAKE_BUSY="$2" PYTHONPATH="$T/fake" PATH="$T/fake/bin:$PATH" \
        python3 "$T/apply.py" "$T/map.json" 8000 500 "$3" "$4" 2>&1); rc=$?
  w=$(python3 -c "import json;print(' '.join(json.load(open('$T/fs.json'))['writes']))")
  [ "$rc" = "$7" ] && [ "$w" = "$8" ] && ok "$1 (rc $rc, writes: ${w:-none})" || bad "$1: rc $rc (want $7), writes '$w' (want '$8') — $out"
}
M='{"GPU-a": {"name": "A", "mem": 2000, "core": 100}}'
scen "idle card lost its offsets → written"                 ""      0 0 '[{"uuid":"GPU-a","mem":0,"core":0}]'    "$M" 0 "0:mem=2000 0:core=100"
scen "busy card lost its offsets → NOT written, check FAILS" "GPU-a" 0 0 '[{"uuid":"GPU-a","mem":0,"core":0}]'    "$M" 1 ""
scen "busy card, APPLY_WHEN_BUSY=1 → written"                "GPU-a" 1 0 '[{"uuid":"GPU-a","mem":0,"core":0}]'    "$M" 0 "0:mem=2000 0:core=100"
scen "busy card already correct → nothing written, OK"       "GPU-a" 0 0 '[{"uuid":"GPU-a","mem":2000,"core":100}]' "$M" 0 ""
scen "unmapped card present, FAIL_ON_UNMAPPED=0 → ignored"   ""      0 0 '[{"uuid":"GPU-a","mem":2000,"core":100},{"uuid":"GPU-b","mem":0,"core":0}]' "$M" 0 ""
scen "unmapped card present, FAIL_ON_UNMAPPED=1 → FAILS"     ""      0 1 '[{"uuid":"GPU-a","mem":2000,"core":100},{"uuid":"GPU-b","mem":0,"core":0}]' "$M" 1 ""
scen "absurd value in the map → REFUSED, FAILS"              ""      0 0 '[{"uuid":"GPU-a","mem":0,"core":0}]' '{"GPU-a": {"mem": 20001, "core": 100}}' 1 "0:core=100"
scen "mapped card not in the machine → skipped, OK"          ""      0 0 '[]' "$M" 0 ""

echo "5. C sources compile"
gcc -O2 -Wall -Werror -o "$T/vramtemp" "$D/src/vramtemp.c" 2>"$T/err" && ok "vramtemp.c" || bad "vramtemp.c: $(head -3 "$T/err")"
"$T/vramtemp" 2>/dev/null; [ $? -eq 2 ] && ok "vramtemp prints usage without arguments" || bad "vramtemp usage"
if command -v nvcc >/dev/null; then nvcc -O3 -o "$T/vb" "$D/src/vrambench.cu" 2>"$T/err" && ok "vrambench.cu" || bad "vrambench.cu: $(head -3 "$T/err")"
else echo "  skip  vrambench.cu (no nvcc on PATH — build.sh finds it on its own)"; fi

echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]

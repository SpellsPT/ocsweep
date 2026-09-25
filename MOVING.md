# Moving ocsweep to another machine

> ⚠ **Vibe-coded**: written by an AI coding assistant for a non-developer, tested on a single two-GPU test bench,
> never reviewed by a human programmer. Treat it as a useful experiment, not as proven software. See README.md.

Written for whoever sets ocsweep up on a new box — a person or an AI coding session. Follow it top to bottom.

## 0. Before you start

- **The sweep crashes GPU drivers on purpose and reboots the machine by itself** when a card needs a reset.
  Never run a sweep on a machine that is serving anything (a chat bot, an inference server, a desktop in use).
  Plan downtime, or sweep the cards on a spare machine and carry only the resulting numbers over.
- `--apply` alone (keeping known-good offsets) is safe on a live machine — it only sets clock offsets.
- You need: Linux + NVIDIA driver, systemd, passwordless `sudo`, `python3` with `pynvml` for root, a CUDA
  toolkit (`nvcc`), `gcc`, `make`, `cmake`, `git`, `curl`. Optional: `llama-server` (llama.cpp) + a small GGUF.

## 1. Copy

The package is `ocsweep-<version>.tar.gz` (source only, no binaries, no machine data):

```bash
tar -xzf ocsweep-*.tar.gz            # creates ./ocsweep/
cd ocsweep
```

Copying the folder directly also works: only copy the tracked files. `bin/`, `build/`, `third_party/` are
rebuilt per machine (they are compiled for that machine's GPU architectures), and `data/` and `ocsweep.conf`
belong to the machine they were made on.

## 2. Check and build

```bash
./tests/selftest.sh     # no GPU load, no sudo: script syntax, step logic, bandwidth rule, hang protection
./build.sh              # finds nvcc, builds vrambench / vramtemp / gpu-burn / cuda_memtest for every GPU here
sudo apt install python3-pynvml   # Debian/Ubuntu, if the sweep says pynvml is missing
```

`build.sh` needs internet access once (it clones gpu-burn and cuda_memtest from GitHub at pinned commits).

## 3. Configure (optional)

```bash
cp ocsweep.conf.example ocsweep.conf
```

Everything has a default. The usual edits:

- `LLAMA_SERVER`, `LLAMA_LIBRARY_PATH`, `T4_MODEL` — turn on the LLM check (strongly recommended: it is the
  only test that caught a core overclock computing wrong answers without crashing). The model must fit on the
  smallest card being swept with `T4_CTX` context.
- `CORE_TEMP_LIMIT` / `CORE_TEMP_STOP` — a machine with poor airflow may need higher limits to finish at all.
- `MEM_CEIL` — the highest memory offset to try.
- `CUDA_HOME` — only if the CUDA toolkit is not on PATH or under `/usr/local` (then `./build.sh` cannot find it).
- Use **absolute paths** for `LLAMA_SERVER` and `T4_MODEL`: the background service does not see your shell's PATH,
  and a model on a disk that mounts late fails right after a reboot (the sweep then refuses to continue rather
  than mislabel every step).

## 4. Dry run

```bash
./ocsweep --card 0        # prints the plan, the tools found, the temperature readings; changes nothing
```

Check the line `thermal guard: … now: core XX°C, … vram=YY`. `vram=NA` means this card's memory temperature
is unknown to `vramtemp` (only the core temperature will guard it) — fine, but worth knowing.

## 5. Sweep

```bash
./install-service.sh --hw-watchdog   # the service that resumes after reboots (+ hardware watchdog if the board has one)
./ocsweep --start 0 1                # queue cards by nvidia-smi index or UUID; they run one after another
tail -f data/runs/*.log              # watch; expect reboots when a memory step fails
./ocsweep --report                   # per-step tables at any time
```

A card takes roughly 1–2 hours (memory steps ~4 min each, core checks, a 30-minute combined soak). Stop any
time with `./ocsweep --stop`.

## 6. Use the result

```bash
./ocsweep --apply 0 3000 100     # card 0: memory +3000 (NVML units), core +100 — now, at boot, re-checked every 15 min
./ocsweep --unapply 0            # back to stock, no longer managed
./ocsweep --status               # sweep state + what is applied + any crash hold
```

**On a box whose cards are always busy** (an LLM server starts seconds after boot), edit `/etc/ocsweep/apply.conf`
(created by the first `--apply`): set `APPLY_WHEN_BUSY=1` and `APPLY_BOOT_BEFORE="<your-llm>.service"`, then run
`--apply` once more so the boot unit picks up the ordering. Without that, lost offsets on busy cards are reported
as a FAILED check (never silently skipped) but not re-written. Add `ALERT_CMD` if you want a message on failures
or a crash hold. If an older tool already keeps offsets applied, `--apply` the SAME values first, then disable the
old tool, so two appliers never fight.

Pick numbers below the highest pass — the report's soak line is the recommendation. If the machine ever dies
without a clean shutdown after applying at boot, the next boot applies nothing (a "hold") until you run
`--apply` again — so a bad offset cannot cause a reboot loop. NVML memory offsets are
**transfer-rate MHz**: +3000 here is +1500 in MSI Afterburner.

## 7. Carrying numbers from one machine to another

A result belongs to one physical card, not to a card model: two cards of the same model can differ by
hundreds of MHz. Numbers found on a different card are a starting guess — confirm on the target card
(at least the soak) before relying on them for anything that matters.

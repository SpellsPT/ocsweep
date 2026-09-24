# ocsweep

Find how far an NVIDIA card's **memory** and **core** clocks can really go on Linux — automatically, one card at a
time, headless and crash-proof — confirm a sensible combination with one long test, then keep the chosen numbers
applied.

It is built for people who run LLMs and compute on consumer GeForce cards: the checks are about *correct results
and real bandwidth*, not a benchmark score that survives a few minutes.

> **The sweep crashes GPU drivers on purpose and reboots the machine by itself.** Never run a sweep on a machine
> that is serving anything. Applying known-good numbers (`--apply`) is safe anywhere.

## What it does

| phase | what | a step fails on |
|---|---|---|
| 1. memory | raises the memory offset with the core at +0. Big steps low, small steps high (default +500 → +200 from +2000 → +100 from +2400 → +50 from +2600); after the first failure it closes the gap | VRAM errors, gpu_burn errors, a new kernel Xid, a changed LLM answer, or **bandwidth that stops rising with the clock** |
| 2. core | checks a few fixed core offsets with the memory at +0 (default +100, +150, +200) | gpu_burn errors, Xid, a hang, a changed LLM answer |
| 3. soak | both together at sensible numbers — highest pass minus a margin, rounded down — for a long run (default 30 min) | same as above; on a failure it finds the culprit (memory alone: fails → memory drops, passes → core drops) and soaks again |
| apply | keeps your chosen offsets: at every boot and re-checked every 15 minutes | — |

**Why the bandwidth rule.** GDDR6/6X memory does not crash when overclocked too far — it detects transfer errors
and retries them (EDC). Past the real limit the clock goes up and the useful bandwidth does not. `vrambench`
measures it at every step, and a step must gain at least half of what its clock gain predicts.

**Why the LLM check** (optional, called T4). A core overclock can compute wrong numbers without crashing —
gpu_burn may still say OK. A real llama.cpp request at temperature 0 must return bit-identical text at every step.

**Why the core is only checked, not swept.** The core offset barely changes LLM token generation (it is memory
bound); it helps prompt processing a little. Beyond about +200 MHz NVIDIA cores get unreliable fast.

## Safety

- **Thermal guard** — memory-junction temperature (on cards whose sensor `vramtemp` knows, read through `/dev/mem`),
  core temperature, and time spent hot. A hot test is stopped, the card cools down, the step is retried once. Heat
  is never counted as a clock failure.
- **Crash-proof sweeps** — state is written to disk (fsync) before every step. If the machine dies during a step,
  that step becomes a failure and is never retried; the `ocsweep` service resumes after the reboot.
- **Watchdogs** — every test has a timeout and runs in its own process group (nothing it leaves behind can hang
  the sweep); a card that reports "needs a reset" or a silent driver triggers a save-and-reboot; optionally the
  board's hardware watchdog resets a frozen kernel.
- **Apply crash guard** — if the machine does not shut down cleanly after offsets were applied at boot (a hang,
  a watchdog reset), the next boot applies nothing and holds until you run `--apply` again. No reboot loops.
- **Root runs only root-owned code** — the helpers that run as root are installed to `/usr/local/libexec/ocsweep/`.
- **Nothing is applied automatically by a sweep.** You get numbers and a report; `--apply` is your decision.

## Requirements

Linux with the NVIDIA driver and systemd, passwordless `sudo`, a CUDA toolkit (`nvcc`), `gcc`, `make`, `cmake`,
`git`, `curl`, `python3` with `pynvml` for root (Debian/Ubuntu: `apt install python3-pynvml`).
Optional: `llama-server` (llama.cpp) and a small GGUF model that fits your smallest card, for the LLM check.

## Use

```bash
./tests/selftest.sh                  # no GPU, no sudo: checks the logic on this machine
./build.sh                           # builds the test tools for every GPU architecture in the box
cp ocsweep.conf.example ocsweep.conf # optional: limits, steps, the LLM check
./install-service.sh [--hw-watchdog] # the service that resumes sweeps after reboots + root-owned helpers
./ocsweep --card 0                   # dry run: shows the plan, changes nothing
./ocsweep --start 0 1                # sweep cards 0 and 1 in the background, one after the other
tail -f data/runs/*.log              # watch (expect reboots when a memory step fails)
./ocsweep --report                   # per-step tables: offset, clock, bandwidth, LLM speed, temperatures, result
./ocsweep --stop                     # stop; the running step is recorded as NOT tested
./ocsweep --apply 0 3000 100         # USE offsets on card 0: now, at every boot, re-checked every 15 min
./ocsweep --unapply 0                # stop managing card 0 and put it back to stock
./ocsweep --status                   # sweep state, queue, what is applied, any crash hold
```

Cards are given as the `nvidia-smi` index or the GPU UUID; state is kept by UUID, so a card can change slots.

**Units:** NVML memory offsets are **transfer-rate MHz** — the real clock moves by half, which is the number MSI
Afterburner shows (+3000 here = +1500 in Afterburner). Core offsets are plain MHz.

Moving to another machine: see **[MOVING.md](MOVING.md)**.

## Files

| file | what |
|---|---|
| `ocsweep` | the main script: sweep, report, status, start/stop, apply/unapply |
| `ocsweep-runner` | run by `ocsweep.service`: works through the queue, resumes after reboots, crash-loop guard |
| `ocsweep-apply` | run as root by `ocsweep-apply-boot.service` and `ocsweep-apply.timer`: applies `/etc/ocsweep/apply.json` |
| `build.sh` | builds `vrambench`, `vramtemp`, gpu-burn and cuda_memtest for the GPUs present (third-party code at pinned commits) |
| `install-service.sh` | installs the sweep service, the root-owned helpers, optionally the hardware watchdog; `--uninstall` |
| `ocsweep.conf.example` | every setting with its default and an explanation |
| `src/vrambench.cu` | memory bandwidth + address-dependent error check |
| `src/vramtemp.c` | GDDR6/6X memory-junction and hotspot temperature for GeForce cards |
| `tests/selftest.sh` | logic tests that need no GPU |
| `MOVING.md` | step-by-step setup on another machine |
| `LICENSE` | Apache License 2.0 |

Created on first use and never part of the package: `bin/`, `build/`, `third_party/` (per-machine builds),
`data/` (state, queue, logs, step tables) and `ocsweep.conf` (this machine's settings).

## Borrowed ideas and tools

- [wilicc/gpu-burn](https://github.com/wilicc/gpu-burn) (BSD-2) and
  [ComputationalRadiationPhysics/cuda_memtest](https://github.com/ComputationalRadiationPhysics/cuda_memtest)
  are downloaded and built by `build.sh` at pinned commits.
- Memory-temperature registers from
  [ThomasBaruzier/gddr6-core-junction-vram-temps](https://github.com/ThomasBaruzier/gddr6-core-junction-vram-temps)
  and [olealgoritme/gddr6](https://github.com/olealgoritme/gddr6), re-implemented in `src/vramtemp.c`. Cards not
  in its table get no memory temperature; the core temperature still guards them.
- Address-dependent test data from [GpuZelenograd/memtest_vulkan](https://github.com/GpuZelenograd/memtest_vulkan),
  used in `src/vrambench.cu`.
- Throttle-reason logging inspired by [huggingface/gpu-fryer](https://github.com/huggingface/gpu-fryer).

## Licence

[Apache License 2.0](LICENSE). gpu-burn (BSD-2) and cuda_memtest (NCSA) are not included here — `build.sh`
downloads them from their own repositories under their own licences.

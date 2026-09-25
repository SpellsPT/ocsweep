#!/usr/bin/env bash
# install-service.sh — install ocsweep.service (systemd, runs as YOU) so a sweep survives crashes and reboots.
#   ./install-service.sh                 install / update the service
#   ./install-service.sh --hw-watchdog   also enable a hardware watchdog timer, if the board has one
#                                        (resets the box if the kernel freezes — e.g. after a core-overclock crash)
#   ./install-service.sh --uninstall    remove the sweep service and the watchdog settings
#                                        (the --apply units stay: remove those with ./ocsweep --unapply <card>)
# Also installs root-owned copies of the helpers that run as root (/usr/local/libexec/ocsweep/): root never runs
# code from a folder a normal user can edit.
set -euo pipefail
D=$(cd "$(dirname "$(readlink -f "$0")")" && pwd); U=$(id -un)
if [ "${1:-}" = --uninstall ]; then
  sudo systemctl disable --now ocsweep.service 2>/dev/null || true; sudo rm -f /etc/systemd/system/ocsweep.service
  sudo rm -f /etc/systemd/system.conf.d/10-ocsweep-watchdog.conf /etc/modules-load.d/ocsweep-watchdog.conf
  sudo systemctl daemon-reload; sudo systemctl daemon-reexec
  echo "removed ocsweep.service and the watchdog settings (a loaded watchdog driver stays until reboot)"; exit 0
fi
OCSWEEP_DATA=""; CONF=${OCSWEEP_CONF:-$D/ocsweep.conf}; [ -f "$CONF" ] && . "$CONF"; DATA=${OCSWEEP_DATA:-$D/data}
[ -x "$D/bin/vramtemp" ] || { echo "run ./build.sh first"; exit 1; }
sudo install -d -o root -g root -m 755 /usr/local/libexec/ocsweep
sudo install -o root -g root -m 755 "$D/bin/vramtemp" /usr/local/libexec/ocsweep/vramtemp
sudo tee /etc/systemd/system/ocsweep.service >/dev/null <<UNIT
[Unit]
Description=ocsweep GPU overclock sweep — resumes after a crash/reboot ($D)
After=nvidia-persistenced.service network-online.target
Wants=network-online.target
ConditionPathExists=$DATA/queue

[Service]
Type=simple
User=$U
Environment=OCSWEEP_CONF=$CONF
# let the box settle after boot before stressing a GPU
ExecStartPre=/bin/sleep 60
ExecStart=$D/ocsweep-runner
TimeoutStartSec=300
Restart=no

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
echo "installed /etc/systemd/system/ocsweep.service (User=$U, $D). Start a sweep with: $D/ocsweep --start <card> [...]"
[ "${1:-}" = --hw-watchdog ] || exit 0
if [ ! -e /dev/watchdog ]; then
  # chipset watchdogs only (AMD / Intel): probing Super I/O watchdog drivers blind is not safe
  for m in sp5100_tco iTCO_wdt; do sudo modprobe "$m" 2>/dev/null && [ -e /dev/watchdog ] && { echo "$m" | sudo tee /etc/modules-load.d/ocsweep-watchdog.conf >/dev/null; echo "watchdog driver: $m"; break; }; done
fi
[ -e /dev/watchdog ] || { echo "no hardware watchdog found on this board — skipped (the software watchdog still works)"; exit 0; }
sudo mkdir -p /etc/systemd/system.conf.d
printf '# ocsweep: systemd feeds the hardware watchdog; a frozen kernel resets the box after 60 s\n[Manager]\nRuntimeWatchdogSec=60s\nRebootWatchdogSec=10min\n' | sudo tee /etc/systemd/system.conf.d/10-ocsweep-watchdog.conf >/dev/null
sudo systemctl daemon-reexec
echo "hardware watchdog active: $(systemctl show -p RuntimeWatchdogUSec --value) via $(systemctl show -p WatchdogDevice --value)"

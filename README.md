# thinkpad-intel-lap-detection-workaround

Fix aggressive CPU throttling on Linux ThinkPads (and other Intel laptops) where the CPU is pinned to its lowest clock speed — often around **1000 MHz** — even though temperatures are fine, the governor is set to `performance`, and the normal power limit looks correct.

The real culprit on many ThinkPads is a **hidden RAPL "MMIO" power-limit domain** that the embedded controller (EC) clamps to a very low value (e.g. **5 W**) when it thinks the laptop is "on a lap." This domain is *separate* from the usual `intel-rapl:0` limit, which is why the common fixes don't work. This tool detects it, raises it, and keeps it raised — then gives you two clickable icons to switch between Performance and Battery Saver.

> ⚠️ **Not medical/financial advice, but do read the disclaimer.** Raising power limits makes your CPU run hotter and draw more current. The defaults here are conservative and within Intel's rated envelope, but you are changing power behaviour your vendor set. Use at your own risk.

---

## The symptom

- CPU stuck at ~1000 MHz under load
- Temperatures are *low* (so it's not thermal throttling)
- `cpupower` / governor already set to `performance`
- GNOME Power settings show **Performance — Degraded (lap-detected)**
- Nothing you change seems to help

## Why it happens

Modern ThinkPads use Intel's Dynamic Platform & Thermal Framework (DPTF) plus a firmware "lap detection" sensor. On Windows this is managed by vendor drivers. On Linux those drivers don't run, so the firmware falls back to its most conservative state and clamps the CPU's **MMIO RAPL** power limit very low. The `lap-detected` label you see is the firmware's own sensor state — it **cannot be switched off** from Linux, because the sensor lives below the OS. What *can* be done is override the low power limit it imposes.

## How the fix works

1. A tiny **systemd service** reads your chosen limits from `/etc/cpu-power-profile` and writes them to every Intel RAPL domain (MMIO first — the one that's actually clamped), **re-applying every 5 seconds**. The re-apply loop is necessary because the EC resets the value on its own; a one-shot write gets reverted within seconds.
2. Two **switch scripts** simply change the values in that file.
3. Two **desktop launchers** run those scripts from clickable icons.

Performance is the default on every boot. No third-party binaries — only tools already on Ubuntu/GNOME.

---

## Requirements

- An **Intel** laptop exposing `intel-rapl` powercap (most do)
- `systemd` (Ubuntu, Fedora, Debian, etc.)
- GNOME for the clickable icons (the CLI parts work on any desktop)
- `notify-send` for the on-screen toast (optional; script tolerates its absence)

## Install

```bash
git clone https://github.com/vascenso-development/thinkpad-intel-lap-detection-workaround.git
cd thinkpad-intel-lap-detection-workaround
chmod +x install.sh
sudo ./install.sh
```

On first click of a **Desktop** icon, GNOME asks you to allow it: right-click → **Allow Launching** (once). Icons in the app grid work immediately.

### Verify it's holding

```bash
# Should read your Performance PL1 (e.g. 25000000 = 25 W), not 5000000
cat /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw
```

Then confirm real clocks under load:

```bash
sudo apt install stress
stress --cpu "$(nproc)" &
watch -n1 "grep MHz /proc/cpuinfo | sort -n | tail -1"
# Ctrl-C, then: kill %1
```

## Usage

- **CPU: Performance** icon → high sustained + turbo power (default)
- **CPU: Battery Saver** icon → low power for longer battery / cooler lap use

Switching takes up to 5 seconds to apply (the service's loop interval).

---

## Tuning for your laptop

The defaults suit a **ThinkPad T14 Gen 1** with an **Intel i7-10610U** (a 15 W chip that Intel rates for up to 25 W cTDP-up). **Other machines want different numbers.** Edit the block at the top of `install.sh` and re-run `sudo ./install.sh`:

```bash
PERF_PL1_W=25   # sustained power in Performance mode
PERF_PL2_W=38   # short turbo burst in Performance mode
BATT_PL1_W=12   # sustained power in Battery Saver mode
BATT_PL2_W=20   # short turbo burst in Battery Saver mode
```

### Finding sensible values

- Look up your CPU's **base TDP** and **cTDP-up** (e.g. on Intel ARK or a review site). Set `PERF_PL1_W` at or near the cTDP-up figure.
- Set `PERF_PL2_W` a bit higher for turbo response.
- **Your cooler is usually the real limit, not the chip.** Run a sustained `stress` test and watch temperature:
  - Settles **below ~90 °C** → you may have headroom; nudge PL1 up.
  - Hits **~95–100 °C and clocks drop** → back PL1 down. A lower PL1 that never thermal-throttles often gives *higher sustained* clocks than a high one that overheats and drops hard.
- Intel CPUs in these classes typically throttle at ~100 °C (TJmax); **~90 °C under a full synthetic load is a healthy target**, not a warning.

---

## Troubleshooting

### After reboot the limit is back at 5 W

The service probably isn't enabled/running. Check:

```bash
systemctl status reclamp.service --no-pager
```

- `Loaded: … disabled` or `Active: inactive (dead)` → it never started this boot. Fix:
  ```bash
  sudo systemctl enable reclamp.service
  sudo systemctl restart reclamp.service
  ```
  Then confirm it survives a reboot:
  ```bash
  sudo reboot
  # after login, without touching anything:
  systemctl is-active reclamp.service          # want: active
  cat /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw   # want: 25000000
  ```

The installer now enables and starts the service as separate steps and verifies both, so a fresh install shouldn't hit this — but this is the fix if it ever ends up `disabled`.

### The service runs but the limit still snaps back

Then your EC re-clamps faster than the loop re-applies. **The 5-second interval is a default, not a measured value** — some machines revert sub-second. Measure yours:

```bash
sudo systemctl stop reclamp.service
echo 25000000 | sudo tee /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw
watch -n1 "cat /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw"
```

- Never drops → you don't even need the loop; a boot-time one-shot would do.
- Drops after N seconds → set the loop `sleep` to well under N.

**Tuning the interval:** edit the `sleep 5` inside `ExecStart` in `/etc/systemd/system/reclamp.service`, then `sudo systemctl daemon-reload && sudo systemctl restart reclamp.service`.

### On battery, Performance mode does nothing

Some ThinkPads enforce a stricter power limit in firmware when on DC power, and may **lock** the register so no userspace write survives. Check whether it's locked on battery:

```bash
sudo rdmsr 0x610   # value starting with 8… (bit 63 set) = LOCKED → not fixable from Linux
```

If it's locked on battery, this is a genuine firmware limit and no re-apply interval will beat it. Also check whether the throttle is actually the pstate ceiling or EPP rather than the power limit on DC:

```bash
cat /sys/devices/system/cpu/intel_pstate/max_perf_pct
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
```

If `max_perf_pct` drops or EPP flips to `power` on battery, pin those instead — that's a different (and easier) fix than the power limit.

## Uninstall

```bash
sudo ./install.sh uninstall
```

Removes the service, scripts, sudoers entry and icons. Power limits return to firmware defaults on next reboot.

---

## How this was diagnosed (for the curious)

The throttle survived every "obvious" fix, so it came down to reading the actual hardware state. Useful commands if you're chasing a similar problem:

| Check | Command | What it tells you |
|---|---|---|
| Throttle reason | `sudo rdmsr -f 15:0 0x19C` | IA32_THERM_STATUS bits (bit 10 = power-limited *now*) |
| Clock modulation | `sudo rdmsr 0x19A` | T-state throttle (should be `0`) |
| Power-limit MSR lock | `sudo rdmsr 0x610` | If value starts with `8…` (bit 63), it's *locked* and unfixable in userspace |
| VR current limit | `sudo rdmsr 0x601` | IccMax (in ⅛ A units) |
| BD PROCHOT | `sudo rdmsr 0x1FC` | Odd value = active; even = disabled |
| **The actual culprit** | `cat /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw` | A tiny value (e.g. `5000000` = 5 W) is the hidden clamp |

`rdmsr` comes from `sudo apt install msr-tools && sudo modprobe msr`. Note: this fix itself does **not** need `msr-tools` — the RAPL powercap sysfs interface is all it uses. MSRs are only handy for diagnosis.

---

## License

MIT. Do whatever you like; no warranty.

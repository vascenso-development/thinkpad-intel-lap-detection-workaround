#!/bin/bash
#
# thinkpad-power-unlock — installer
# ---------------------------------
# Fixes CPU throttling on Linux caused by the firmware/EC clamping the
# Intel RAPL *MMIO* power-limit domain to a very low value (e.g. 5 W),
# which pins the CPU to its lowest clocks regardless of governor, pstate
# ceiling, or the normal intel-rapl:0 power limit.
#
# It installs:
#   1. A systemd service that continuously re-applies your chosen power
#      limits (out-stubborning the EC, which resets them every few sec).
#   2. Two switch scripts (Performance / Battery Saver).
#   3. Two clickable desktop launchers with icons.
#
# Performance is the default on every boot.
#
# Uses only tools shipped with Ubuntu/GNOME. No third-party binaries.
#
# Usage:
#   sudo ./install.sh            # install
#   sudo ./install.sh uninstall  # remove everything
#
# ⚠  TUNE THE WATT VALUES BELOW for your machine. The defaults suit a
#    ThinkPad T14 Gen 1 (Intel i7-10610U, 15 W chip, cTDP-up 25 W). A
#    different laptop/CPU/cooler may want different numbers — see README.
#
set -euo pipefail

# ─── Configurable power targets (in watts) ──────────────────────────────
PERF_PL1_W=25   # sustained power in Performance mode
PERF_PL2_W=38   # short turbo burst in Performance mode
BATT_PL1_W=12   # sustained power in Battery Saver mode
BATT_PL2_W=20   # short turbo burst in Battery Saver mode
# ────────────────────────────────────────────────────────────────────────

PROFILE_FILE="/etc/cpu-power-profile"
SERVICE_FILE="/etc/systemd/system/reclamp.service"
PERF_SCRIPT="/usr/local/bin/cpu-performance.sh"
BATT_SCRIPT="/usr/local/bin/cpu-battery.sh"
SUDOERS_FILE="/etc/sudoers.d/cpu-profile"

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo $0 ${1:-}" >&2
    exit 1
fi

# Figure out the real (non-root) user who invoked sudo, for the desktop icons
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

uW() { echo $(( $1 * 1000000 )); }   # watts → microwatts

# ─── Uninstall path ─────────────────────────────────────────────────────
if [ "${1:-}" = "uninstall" ]; then
    echo "Removing thinkpad-power-unlock…"
    systemctl disable --now reclamp.service 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$PROFILE_FILE" "$PERF_SCRIPT" "$BATT_SCRIPT" "$SUDOERS_FILE"
    rm -f "$REAL_HOME/.local/share/applications/cpu-performance.desktop" \
          "$REAL_HOME/.local/share/applications/cpu-battery.desktop" \
          "$REAL_HOME/Desktop/cpu-performance.desktop" \
          "$REAL_HOME/Desktop/cpu-battery.desktop"
    systemctl daemon-reload
    echo "Done. (CPU limits revert to firmware defaults on next reboot.)"
    exit 0
fi

# ─── Sanity check: is there a RAPL powercap domain at all? ──────────────
if ! ls /sys/class/powercap/intel-rapl*/*/constraint_0_power_limit_uw >/dev/null 2>&1; then
    echo "⚠  No Intel RAPL powercap interface found on this machine." >&2
    echo "   This tool targets Intel CPUs. Aborting." >&2
    exit 1
fi

echo "==> Writing power-profile file (default: Performance ${PERF_PL1_W}W/${PERF_PL2_W}W)"
echo "$(uW "$PERF_PL1_W") $(uW "$PERF_PL2_W")" > "$PROFILE_FILE"

echo "==> Installing systemd re-clamp service"
# The service loops forever, reading PL1/PL2 from $PROFILE_FILE and writing
# them to every available RAPL domain (MMIO first — that's the one the EC
# tends to clamp). It re-applies every 5 s to beat the EC's reset.
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Re-apply Intel RAPL power limits from /etc/cpu-power-profile
After=multi-user.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do read PL1 PL2 < /etc/cpu-power-profile; for d in /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0 /sys/class/powercap/intel-rapl/intel-rapl:0; do [ -w "$d/constraint_0_power_limit_uw" ] && echo $PL1 > "$d/constraint_0_power_limit_uw"; [ -w "$d/constraint_1_power_limit_uw" ] && echo $PL2 > "$d/constraint_1_power_limit_uw"; done; sleep 5; done'
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# Enable (start on boot) and start (start now) as separate explicit steps.
# A combined `enable --now` can silently no-op on some systems if the unit
# was already loaded or daemon-reload hadn't settled — so we verify below.
systemctl enable reclamp.service
systemctl restart reclamp.service

# Verify it actually came up; fail loudly if not, so the user isn't left
# thinking it worked when the limit will snap back to the firmware clamp.
sleep 1
if ! systemctl is-active --quiet reclamp.service; then
    echo "✗ reclamp.service failed to start. Diagnose with:" >&2
    echo "    systemctl status reclamp.service --no-pager" >&2
    echo "    journalctl -u reclamp.service -b --no-pager" >&2
    exit 1
fi
if ! systemctl is-enabled --quiet reclamp.service; then
    echo "✗ reclamp.service is running but NOT enabled for boot." >&2
    echo "    Run: sudo systemctl enable reclamp.service" >&2
    exit 1
fi
echo "   service is active and enabled for boot ✓"

echo "==> Installing profile switch scripts"
cat > "$PERF_SCRIPT" <<EOF
#!/bin/bash
echo "$(uW "$PERF_PL1_W") $(uW "$PERF_PL2_W")" | sudo tee $PROFILE_FILE >/dev/null
notify-send "CPU Profile" "⚡ Performance (${PERF_PL1_W}W/${PERF_PL2_W}W)" 2>/dev/null || true
EOF

cat > "$BATT_SCRIPT" <<EOF
#!/bin/bash
echo "$(uW "$BATT_PL1_W") $(uW "$BATT_PL2_W")" | sudo tee $PROFILE_FILE >/dev/null
notify-send "CPU Profile" "🔋 Battery Saver (${BATT_PL1_W}W/${BATT_PL2_W}W)" 2>/dev/null || true
EOF

chmod +x "$PERF_SCRIPT" "$BATT_SCRIPT"

echo "==> Granting passwordless write to the profile file (single file only)"
# Lets the clickable scripts change the profile without a password prompt.
# Scope is deliberately narrow: only `tee` to this one non-executable file.
echo "$REAL_USER ALL=(root) NOPASSWD: /usr/bin/tee $PROFILE_FILE" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

echo "==> Creating clickable desktop launchers for $REAL_USER"
APP_DIR="$REAL_HOME/.local/share/applications"
mkdir -p "$APP_DIR"

cat > "$APP_DIR/cpu-performance.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CPU: Performance
Comment=Set CPU to ${PERF_PL1_W}W/${PERF_PL2_W}W
Exec=$PERF_SCRIPT
Icon=power-profile-performance-symbolic
Terminal=false
Categories=System;
EOF

cat > "$APP_DIR/cpu-battery.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CPU: Battery Saver
Comment=Set CPU to ${BATT_PL1_W}W/${BATT_PL2_W}W
Exec=$BATT_SCRIPT
Icon=power-profile-power-saver-symbolic
Terminal=false
Categories=System;
EOF

# Copy to the Desktop too (best-effort)
if [ -d "$REAL_HOME/Desktop" ]; then
    cp "$APP_DIR/cpu-performance.desktop" "$APP_DIR/cpu-battery.desktop" "$REAL_HOME/Desktop/" 2>/dev/null || true
fi

# Fix ownership (we created these as root)
chown -R "$REAL_USER":"$REAL_USER" "$APP_DIR" 2>/dev/null || true
chown "$REAL_USER":"$REAL_USER" "$REAL_HOME/Desktop/cpu-"*.desktop 2>/dev/null || true
chmod +x "$REAL_HOME/Desktop/cpu-"*.desktop 2>/dev/null || true

# Refresh the desktop database and mark Desktop launchers trusted (best-effort)
sudo -u "$REAL_USER" update-desktop-database "$APP_DIR" 2>/dev/null || true
for f in "$REAL_HOME/Desktop/cpu-performance.desktop" "$REAL_HOME/Desktop/cpu-battery.desktop"; do
    [ -f "$f" ] && sudo -u "$REAL_USER" gio set "$f" metadata::trusted true 2>/dev/null || true
done

echo
echo "==> Verifying the power limit actually changed"
sleep 6   # allow at least one service loop iteration
MMIO="/sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw"
if [ -r "$MMIO" ]; then
    NOW="$(cat "$MMIO")"
    WANT="$(uW "$PERF_PL1_W")"
    if [ "$NOW" = "$WANT" ]; then
        echo "   limit is now ${NOW} µW (= ${PERF_PL1_W} W) ✓"
    else
        echo "   ⚠  limit reads ${NOW} µW, expected ${WANT} µW."
        echo "      The service is running but the write isn't holding — your"
        echo "      EC may re-clamp faster than the 5 s loop. Lower the sleep"
        echo "      interval in $SERVICE_FILE (see README: 'Tuning the interval')."
    fi
fi

echo
echo "✅ Done."
echo
echo "  • Performance is active now and on every reboot."
echo "  • Two icons ('CPU: Performance' / 'CPU: Battery Saver') are in your"
echo "    app grid and on the Desktop."
echo "  • First click of a Desktop icon: right-click → 'Allow Launching'."
echo
echo "  Verify it's holding:"
echo "    cat /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw"
echo
echo "  ⚠  If your CPU still throttles, the default watt values may be wrong"
echo "     for this machine — edit the values at the top of this script and"
echo "     re-run.  See README.md for how to find your chip's real limits."

#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/babynas-install.log
exec > >(tee -a "$LOG") 2>&1

# -------- Helpers --------
need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root." >&2; exit 1
  fi
}

pkg() { DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }

pause() { read -rp "Press Enter to continue..."; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

os_disk() {
  # Resolve base disk that backs /
  local root_src pk
  root_src=$(findmnt -n -o SOURCE /)
  pk=$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)
  if [[ -z "$pk" ]]; then
    # Fallback for whole-disk installs
    pk=$(lsblk -no NAME "$root_src" 2>/dev/null || true)
  fi
  echo "/dev/${pk}"
}

build_disks_list() {
  # List candidate whole disks (no loops, CD-ROMs). Exclude OS disk.
  local osd="$1"
  lsblk -d -n -o NAME,SIZE,MODEL,TYPE | awk -v osd="${osd#/dev/}" '
    $4=="disk" {
      tag="/dev/"$1
      if ($1!=substr(osd,6)) {
        desc=$2" " $3
        # whiptail expects: tag item status
        print tag, desc, "OFF"
      }
    }'
}

safe_deps() {
  apt-get update -y
  pkg whiptail parted gdisk pciutils curl ca-certificates gpg \
      qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
      cockpit cockpit-machines cockpit-storaged
}

enable_contrib_backports() {
  # Ensure contrib + non-free-firmware + backports for ZFS
  local SRC=/etc/apt/sources.list
  if ! grep -q "contrib" "$SRC"; then
    sed -i 's/\btrixie\b/& main contrib non-free-firmware/g' "$SRC"
    sed -i 's/\btrixie-security\b/& main contrib non-free-firmware/g' "$SRC"
    sed -i 's/\btrixie-updates\b/& main contrib non-free-firmware/g' "$SRC"
  fi
  if ! grep -q "trixie-backports" "$SRC"; then
    echo "deb http://deb.debian.org/debian trixie-backports main contrib non-free-firmware" >> "$SRC"
  fi
  apt-get update -y
}

install_zfs() {
  # ZFS from backports (dkms + userspace)
  pkg linux-image-amd64 linux-headers-amd64 -t trixie-backports
  pkg dkms build-essential
  pkg zfs-dkms zfsutils-linux -t trixie-backports
  modprobe zfs || true
}

enable_iommu() {
  if ! grep -q "intel_iommu=on" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& intel_iommu=on iommu=pt/' /etc/default/grub
    update-grub
  fi
}

nic_menu() {
  # Present NICs with interface names and PCI BDFs; return selected list
  local map_file=/tmp/nicmap.txt
  : > "$map_file"
  # Build (iface, BDF, id)
  for IF in /sys/class/net/*; do
    IF=$(basename "$IF")
    [[ "$IF" == "lo" ]] && continue
    [[ -e "/sys/class/net/$IF/device" ]] || continue
    local dev path bdf ven dev_id
    path=$(readlink -f "/sys/class/net/$IF/device")
    bdf=$(basename "$path")                   # 0000:06:00.1
    ven=$(cat "$path/vendor" | sed 's/0x//')
    dev_id=$(cat "$path/device" | sed 's/0x//')
    echo "$IF $bdf $ven:$dev_id" >> "$map_file"
  done

  local items=()
  while read -r IF BDF VPID; do
    items+=("$IF" "PCI $BDF  id=$VPID" "OFF")
  done < "$map_file"

  if ((${#items[@]}==0)); then
    echo ""
    return
  fi

  local sel
  sel=$(whiptail --title "VFIO Passthrough (NICs)" \
        --checklist "Select NICs to passthrough (Space to toggle, Enter to confirm):" \
        20 78 10 "${items[@]}" 3>&1 1>&2 2>&3) || sel=""
  echo "$sel" | tr -d '"'
}

bind_vfio_boot_all_i350() {
  # Bind by device-id (Intel I350 = 8086:1521) at boot; we will rebind host NICs later
  cat >/etc/modprobe.d/vfio.conf <<EOF
options vfio-pci ids=8086:1521 disable_vga=1
EOF
  echo "blacklist igb" >/etc/modprobe.d/blacklist-igb.conf
  update-initramfs -u
}

write_rebind_service() {
  # Create a helper that keeps selected NICs on vfio-pci and returns the rest to igb
  local passthrough_ifaces="$1"
  local map_file=/etc/babynas-nicmap.list
  mkdir -p /etc/babynas
  # snapshot current mapping (iface BDF VEN:DEV)
  : > "$map_file"
  for IF in /sys/class/net/*; do
    IF=$(basename "$IF"); [[ "$IF" == "lo" ]] && continue
    [[ -e "/sys/class/net/$IF/device" ]] || continue
    local path bdf ven dev_id
    path=$(readlink -f "/sys/class/net/$IF/device")
    bdf=$(basename "$path")
    ven=$(cat "$path/vendor" | sed 's/0x//')
    dev_id=$(cat "$path/device" | sed 's/0x//')
    echo "$IF $bdf $ven:$dev_id" >> "$map_file"
  done

  cat >/usr/local/bin/vfio-bind.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MAP=/etc/babynas-nicmap.list
PT_FILE=/etc/babynas-passthrough.list
modprobe vfio-pci || true
modprobe igb || true

declare -A WANT_PASSTHROUGH
if [[ -f "$PT_FILE" ]]; then
  while read -r IF; do
    [[ -z "$IF" ]] && continue
    WANT_PASSTHROUGH["$IF"]=1
  done < "$PT_FILE"
fi

while read -r IF BDF ID; do
  [[ -z "$IF" ]] && continue
  # Unbind from any driver first
  if [[ -e /sys/bus/pci/devices/$BDF/driver/unbind ]]; then
    echo $BDF > /sys/bus/pci/devices/$BDF/driver/unbind || true
  fi
  if [[ -n "${WANT_PASSTHROUGH[$IF]+x}" ]]; then
    echo $BDF > /sys/bus/pci/drivers/vfio-pci/bind || true
  else
    echo $BDF > /sys/bus/pci/drivers/igb/bind || true
  fi
done < "$MAP"
EOF
  chmod +x /usr/local/bin/vfio-bind.sh

  # Save selected ifaces list
  echo "$passthrough_ifaces" | tr ' ' '\n' | sed '/^$/d' > /etc/babynas-passthrough.list

  cat >/etc/systemd/system/vfio-bind.service <<'EOF'
[Unit]
Description=Bind selected NICs to vfio-pci; others to igb
After=multi-user.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vfio-bind.sh

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable vfio-bind.service
}

create_part() {
  local disk="$1"
  parted -s "$disk" mklabel gpt
  parted -s -a optimal "$disk" mkpart primary 0% 100%
}

zap_disk() {
  local d="$1"
  zpool labelclear -f "$d" 2>/dev/null || true
  sgdisk --zap-all "$d" || true
  wipefs -a "$d" || true
}

confirm_or_exit() {
  whiptail --title "Confirm" --yesno "$1" 12 70 || { echo "Cancelled."; exit 1; }
}

# ---------------- MAIN ----------------
need_root
safe_deps
enable_contrib_backports
install_zfs
enable_iommu

# Cockpit + Libvirt
systemctl enable --now cockpit.socket libvirtd

OSD=$(os_disk)
echo "Detected OS disk: $OSD"

# Disk selection menus
DISK_LIST=$(build_disks_list "$OSD")
if [[ -z "$DISK_LIST" ]]; then
  echo "No candidate data disks found. Exiting."; exit 1
fi

# Pick fastpool (single disk)
FAST=$(whiptail --title "Select disk for fastpool (NVMe 512G)" \
  --radiolist "Use ↑/↓ then Space to select the disk for fastpool" 20 78 10 \
  $DISK_LIST 3>&1 1>&2 2>&3) || { echo "Cancelled."; exit 1; }

# Pick hotpool (single disk)
HOT=$(whiptail --title "Select disk for hotpool (NVMe ~8T)" \
  --radiolist "Use ↑/↓ then Space to select the disk for hotpool" 20 78 10 \
  $DISK_LIST 3>&1 1>&2 2>&3) || { echo "Cancelled."; exit 1; }

# Pick coldpool (multi disks RAIDZ1)
COLD=$(whiptail --title "Select disks for coldpool (RAIDZ1, 4x3T)" \
  --checklist "Use ↑/↓ then Space to mark 3-8 disks for coldpool" 20 78 12 \
  $DISK_LIST 3>&1 1>&2 2>&3) || { echo "Cancelled."; exit 1; }

# Show summary
SUMMARY="This will ERASE the following disks and create ZFS pools:\n
  fastpool: $FAST
  hotpool : $HOT
  coldpool: $COLD\n\nProceed?"
confirm_or_exit "$SUMMARY"

# Wipe + partition
for d in $FAST $HOT $COLD; do
  echo "Wiping $d ..."
  zap_disk "$d"
done

partprobe || true
sleep 1

echo "Partitioning..."
create_part "$FAST"
create_part "$HOT"
for d in $COLD; do create_part "$d"; done
partprobe || true
sleep 1

# Get first partition names
FASTP="${FAST}1"
HOTP="${HOT}1"
COLDP=""
for d in $COLD; do COLDP="$COLDP ${d}1"; done

# Create pools
echo "Creating ZFS pools..."
zpool create -f \
  -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O normalization=formD \
  fastpool "$FASTP"

zfs create -o mountpoint=/mnt/fast fastpool
zfs create -o mountpoint=/mnt/fast/vms    -o recordsize=16K fastpool/vms
zfs create -o mountpoint=/mnt/fast/docker -o recordsize=8K  fastpool/docker
zfs create -o mountpoint=/mnt/fast/iso    fastpool/iso

zpool create -f \
  -o ashift=12 \
  -O compression=zstd \
  -O atime=off \
  hotpool "$HOTP"
zfs create -o mountpoint=/mnt/hot hotpool/data

zpool create -f \
  -o ashift=12 \
  -O compression=zstd \
  -O atime=off \
  coldpool raidz1 $COLDP
zfs create -o mountpoint=/mnt/cold coldpool/data
zfs create -o mountpoint=/mnt/cold/backups coldpool/backups

# Libvirt storage pools (fast/vms and fast/iso)
echo "Registering libvirt storage pools..."
virsh pool-define-as fast dir - - - - "/mnt/fast/vms" || true
virsh pool-build fast || true
virsh pool-start fast || true
virsh pool-autostart fast || true

virsh pool-define-as iso dir - - - - "/mnt/fast/iso" || true
virsh pool-build iso || true
virsh pool-start iso || true
virsh pool-autostart iso || true

# Auto snapshots (cron-based)
echo "Installing zfs-auto-snapshot (from Bookworm)..."
echo "deb http://deb.debian.org/debian bookworm main contrib non-free-firmware" > /etc/apt/sources.list.d/bookworm.list
apt-get update -y
apt-get install -y -t bookworm zfs-auto-snapshot
systemctl enable --now cron
# default cron entries are installed under /etc/cron.hourly/.daily/.weekly/.monthly

# Simple daily send/recv from fast -> cold
cat >/etc/cron.d/zfs-backup <<'EOF'
# Daily snapshot & send fastpool -> coldpool/backups
0 3 * * * root zfs snapshot -r fastpool@$(date +\%Y\%m\%d)
0 4 * * * root zfs send -Rv fastpool@$(date +\%Y\%m\%d) | zfs recv -F coldpool/backups/fastpool
EOF

# Cheat sheet + alias
cat >/root/ZFS-README.txt <<'EOF'
==============================
 BABY’S ZFS QUICK COMMANDS
==============================
# Status
zpool status
zpool list
zfs list
zfs list -t snapshot

# Snapshots
zfs snapshot -r pool@name
zfs rollback -r pool@name
zfs destroy pool@name
# Browse snapshots:  <mount>/.zfs/snapshot/

# Backup fast -> cold (example)
zfs snapshot -r fastpool@$(date +%F)
zfs send -Rv fastpool@$(date +%F) | zfs recv -F coldpool/backups/fastpool

# Libvirt pools
virsh pool-list --all
EOF
echo "alias zfshelp='cat /root/ZFS-README.txt'" >> /root/.bashrc

# VFIO selection
PT_NICS=$(nic_menu) || PT_NICS=""
if [[ -n "$PT_NICS" ]]; then
  bind_vfio_boot_all_i350
  write_rebind_service "$PT_NICS"
  echo "Selected NICs for passthrough: $PT_NICS"
else
  echo "Skipped NIC passthrough selection."
fi

# Final health echo
echo "------------ POOLS -------------"
zpool status
echo "------------ MOUNTS ------------"
zfs list
echo "--------------------------------"

whiptail --title "BabyNAS" --yesno "Install complete.\n\nReboot now to activate IOMMU/VFIO bindings?\n\nLog: $LOG" 12 70 && reboot || true

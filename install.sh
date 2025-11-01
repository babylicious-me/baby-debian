#!/bin/bash
# ============================================================
#  BabyNAS Debian 13 Setup Script (bare-metal edition)
# ============================================================
#  Author: Baby
#  System: Supermicro SSG-5028R-E1CR12L-FI005
# ============================================================

set -e
echo ">>> Updating base system..."
apt update && apt full-upgrade -y
apt install -y zfsutils-linux pciutils parted gdisk qemu-kvm libvirt-daemon-system libvirt-clients virt-manager cockpit cockpit-machines cockpit-storaged cockpit-networkmanager cron

# ------------------------------------------------------------
# Enable IOMMU for Intel (VT-d)
# ------------------------------------------------------------
echo ">>> Enabling Intel IOMMU..."
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& intel_iommu=on iommu=pt/' /etc/default/grub
update-grub

# ------------------------------------------------------------
# Configure VFIO for Intel I350 NICs (eno2, eno3)
# ------------------------------------------------------------
echo ">>> Configuring VFIO for Intel I350 NICs..."
cat >/etc/modprobe.d/vfio.conf <<'EOF'
options vfio-pci ids=8086:1521 disable_vga=1
EOF

cat >/etc/modprobe.d/blacklist-igb.conf <<'EOF'
blacklist igb
EOF

update-initramfs -u

# ------------------------------------------------------------
# Create helper script to rebind eno1/eno4 to igb
# ------------------------------------------------------------
echo ">>> Creating rebind script..."
cat >/usr/local/bin/rebind-host-nics.sh <<'EOF'
#!/bin/bash
modprobe igb
for nic in 0000:06:00.0 0000:06:00.3; do
  echo $nic > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
  echo $nic > /sys/bus/pci/drivers/igb/bind 2>/dev/null || true
done
EOF
chmod +x /usr/local/bin/rebind-host-nics.sh

# ------------------------------------------------------------
# Prepare auto snapshot scripts (cron jobs)
# ------------------------------------------------------------
echo ">>> Setting up ZFS auto snapshots..."
cat >/etc/cron.d/zfs-backup <<'EOF'
# Daily snapshot & send fastpool -> coldpool/backups
0 3 * * * root zfs snapshot -r fastpool@$(date +\%Y\%m\%d)
0 4 * * * root zfs send -Rv fastpool@$(date +\%Y\%m\%d) | zfs recv -F coldpool/backups/fastpool
EOF

systemctl enable cron

# ------------------------------------------------------------
# Add a local cheat sheet for maintenance
# ------------------------------------------------------------
echo ">>> Creating ZFS quick-reference..."
cat >/root/ZFS-README.txt <<'EOF'
==============================
 BABY’S ZFS QUICK COMMANDS
==============================
zpool status            # show pool health
zpool list              # list all pools
zfs list                # list datasets
zfs list -t snapshot    # list snapshots

zfs snapshot -r pool@name        # create snapshot
zfs rollback -r pool@name        # revert to snapshot
zfs destroy pool@name            # delete snapshot

# Backup fastpool -> coldpool
zfs send -Rv fastpool@snap | zfs recv -F coldpool/backups/fastpool

# Pools:
#   fastpool - NVMe (512G)
#   hotpool  - NVMe (8T)
#   coldpool - 4x3T HDD RAIDZ1

zfshelp - quick alias for this guide
EOF

echo "alias zfshelp='cat /root/ZFS-README.txt'" >> /root/.bashrc

# ------------------------------------------------------------
# Enable Cockpit and Libvirt
# ------------------------------------------------------------
echo ">>> Enabling Cockpit & Libvirt..."
systemctl enable --now cockpit.socket libvirtd

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
echo "============================================================"
echo "  BabyNAS setup complete!"
echo "  - Reboot required for VFIO/IOMMU"
echo "  - Access Cockpit: https://<your-IP>:9090"
echo "  - Run: zfshelp for cheat sheet"
echo "============================================================"

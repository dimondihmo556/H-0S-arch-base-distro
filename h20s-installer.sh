#!/bin/bash
# ==========================================================================
# H2OS Installer
# ==========================================================================

set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run this installer as root." >&2
    exit 1
fi
INSTALL_MOUNTED=0
SWAP_ACTIVATED=""

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
LOGFILE="/tmp/h2os-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

cleanup_on_failure() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        trap - EXIT
        echo -e "\e[31m\nInstallation failed (exit code $exit_code).\e[0m"
        echo -e "\e[33mLog saved to: $LOGFILE\e[0m"
        if [ -n "$SWAP_ACTIVATED" ]; then swapoff "$SWAP_ACTIVATED" 2>/dev/null || true; fi
        if [ "$INSTALL_MOUNTED" -eq 1 ]; then
            umount /mnt/boot 2>/dev/null || true
            umount /mnt 2>/dev/null || true
        fi
        echo "Cleanup attempted. Review the log before re-running the installer."
        exit "$exit_code"
    fi
}
trap cleanup_on_failure EXIT

show_logo() {
    clear
    echo -e "\e[36m"
    echo "  _    _ ___   ___   _____ "
    echo " | |  | |__ \ / _ \ / ____|"
    echo " | |__| |  ) | | | | (___  "
    echo " |  __  | / /| | | |\___ \ "
    echo " | |  | |/ /_| |_| |____) |"
    echo " |_|  |_|____|\___/|_____/ "
    echo -e "\e[0m"
    echo -e "\e[32m        Welcome to H²0S Installer        \e[0m\n"
}

error_exit() {
    echo -e "\e[31mError: $1\e[0m"
    exit 1
}

show_logo

if findmnt -rn -R /mnt 2>/dev/null | grep -q .; then
    error_exit "/mnt already contains mounted filesystems. Unmount them before running the installer."
fi
for cmd in lsblk findmnt parted mkfs.vfat mkfs.ext4 mkfs.btrfs mkswap swapon pacstrap genfstab arch-chroot curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || error_exit "Required command not found: $cmd"
done

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="UEFI"
else
    BOOT_MODE="BIOS"
fi
echo "Detected boot mode: $BOOT_MODE"

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
echo -e "\nAvailable drives in the system:"
lsblk -p -o NAME,SIZE,TYPE,FSTYPE
echo ""
read -p "Enter target disk for installation (e.g., /dev/sda or /dev/nvme0n1): " TARGET_DISK

[ -b "$TARGET_DISK" ] || error_exit "Device $TARGET_DISK not found."
TARGET_DISK=$(readlink -f -- "$TARGET_DISK")
[[ "$(lsblk -dnro TYPE "$TARGET_DISK")" == "disk" ]] || error_exit "$TARGET_DISK is not a whole disk. Select a device with TYPE=disk, not a partition."
if lsblk -nrpo MOUNTPOINT "$TARGET_DISK" | grep -qE '.+'; then
    error_exit "A partition on $TARGET_DISK is mounted. Unmount it before installation."
fi

echo -e "\e[31mWARNING! Disk $TARGET_DISK will be completely formatted!\e[0m"
echo "Current partition table on this disk:"
lsblk -p -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$TARGET_DISK" 2>/dev/null
read -p "Are you sure? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1

echo -e "\e[31m\nLAST CHANCE: this will PERMANENTLY destroy all data on $TARGET_DISK.\e[0m"
read -p "Type the disk path exactly ($TARGET_DISK) to confirm: " DISK_TYPED
if [ "$DISK_TYPED" != "$TARGET_DISK" ]; then
    error_exit "Confirmation text did not match. Aborting to protect your data."
fi

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
echo -e "\nSelect root filesystem:"
echo "1) ext4 (default, stable)"
echo "2) btrfs (snapshots support)"
read -p "Choice [1]: " FS_CHOICE
FS_CHOICE=${FS_CHOICE:-1}
case "$FS_CHOICE" in
    1) ROOT_FS="ext4" ;;
    2) ROOT_FS="btrfs" ;;
    *) error_exit "Invalid filesystem choice." ;;
esac
echo "Selected filesystem: $ROOT_FS"

# --------------------------------------------------------------------------
#
# --------------------------------------------------------------------------
read -p "Enter swap size in GB (0 for no swap, recommended 2-4): " SWAP_SIZE
if ! [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]]; then
    error_exit "Swap size must be a whole number of GB (0 disables swap)."
fi
(( SWAP_SIZE <= 128 )) || error_exit "Enter a swap size between 0 and 128 GB."
DISK_BYTES=$(lsblk -bdnro SIZE "$TARGET_DISK")
MIN_REQUIRED_BYTES=$(( (1025 + SWAP_SIZE * 1024 + 10240) * 1024 * 1024 ))
(( DISK_BYTES >= MIN_REQUIRED_BYTES )) || error_exit "Target disk is too small for this swap size and a 10 GiB root partition."

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
echo -e "\nSelect kernel:"
echo "1) CachyOS Kernel (adds CachyOS repo, recommended for performance)"
echo "2) Linux Zen (standard Arch repos only)"
read -p "Choice [1]: " KERNEL_CHOICE
KERNEL_CHOICE=${KERNEL_CHOICE:-1}

case "$KERNEL_CHOICE" in
    1) KERNEL_VARIANT="cachyos"; KERNEL_PKGS="linux-cachyos linux-cachyos-headers"; USE_CACHYOS_REPO=1 ;;
    2) KERNEL_VARIANT="zen"; KERNEL_PKGS="linux-zen linux-zen-headers"; USE_CACHYOS_REPO=0 ;;
    *) error_exit "Invalid kernel choice." ;;
esac
echo "Selected kernel: $KERNEL_VARIANT"

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
echo -e "\n=== Account Configuration ==="
read -r -p "Enter username (lowercase only): " NEW_USER
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || error_exit "Invalid username format."
read -r -s -p "Enter password for $NEW_USER: " USER_PASSWORD; echo ""
read -r -s -p "Confirm password for $NEW_USER: " USER_PASSWORD_CONFIRM; echo ""
[[ -n "$USER_PASSWORD" && "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]] || error_exit "User password is empty or does not match."
read -r -s -p "Enter password for root: " ROOT_PASSWORD; echo ""
read -r -s -p "Confirm password for root: " ROOT_PASSWORD_CONFIRM; echo ""
[[ -n "$ROOT_PASSWORD" && "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]] || error_exit "Root password is empty or does not match."


echo -e "\n=== GPU Detection ==="
GPU_LIST=$(lspci -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)
[[ -n "$GPU_LIST" ]] || GPU_LIST="No display controller detected by lspci."
echo "$GPU_LIST"
DETECTED_GPU="unknown"
if grep -qi 'NVIDIA' <<< "$GPU_LIST"; then DETECTED_GPU="nvidia"
elif grep -Eqi 'AMD|ATI|Radeon' <<< "$GPU_LIST"; then DETECTED_GPU="amd"
elif grep -qi 'Intel' <<< "$GPU_LIST"; then DETECTED_GPU="intel"
fi
echo "Detected GPU vendor (first match): $DETECTED_GPU"
echo "Hybrid systems can contain multiple GPUs; one selected driver set may not cover all of them."

echo "Select your GPU vendor to confirm:"
echo "1) NVIDIA"
echo "2) AMD"
echo "3) Intel"
echo "4) Other / VESA fallback"
read -p "Choice: " GPU_CHOICE

case "$GPU_CHOICE" in
    1) USER_GPU="nvidia" ;;
    2) USER_GPU="amd" ;;
    3) USER_GPU="intel" ;;
    4) USER_GPU="other" ;;
    *) error_exit "Invalid GPU choice. Enter 1, 2, 3 or 4." ;;
esac

if [ "$USER_GPU" != "$DETECTED_GPU" ] && [ "$DETECTED_GPU" != "unknown" ]; then
    echo -e "\e[31mError: the GPU you selected ($USER_GPU) does not match the hardware detected in this system.\e[0m"
    echo -e "\e[33mYour actual detected GPU is: $DETECTED_GPU\e[0m"
    read -p "Use the detected GPU ($DETECTED_GPU) instead? (Y/n): " FIX_GPU
    if [[ ! "$FIX_GPU" =~ ^[Nn]$ ]]; then
        USER_GPU="$DETECTED_GPU"
    fi
fi

case "$USER_GPU" in
    nvidia) VIDEO_DRIVERS="nvidia-open-dkms nvidia-utils mesa" ;;
    amd)    VIDEO_DRIVERS="mesa vulkan-radeon" ;;
    intel)  VIDEO_DRIVERS="mesa vulkan-intel" ;;
    *)      VIDEO_DRIVERS="xf86-video-vesa mesa" ;;
esac
echo "Video drivers to install: $VIDEO_DRIVERS"
echo -e "\e[33mGPU detection does not guarantee model compatibility. nvidia-open-dkms supports newer NVIDIA GPUs; older cards may need a legacy driver.\e[0m"
echo -e "\e[33mAfter installation, run 'lspci -k | grep -A2 VGA' to verify the correct driver is loaded,\e[0m"
echo -e "\e[33mand check the Arch Wiki page for your specific GPU model if you see graphical issues.\e[0m"

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
echo -e "\n[1/8] Partitioning the disk ($BOOT_MODE mode, $ROOT_FS)..."

if [ "$BOOT_MODE" = "UEFI" ]; then
    parted -s "$TARGET_DISK" mklabel gpt || error_exit "parted mklabel failed"
    parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 1025MiB || error_exit "parted mkpart ESP failed"
    parted -s "$TARGET_DISK" set 1 esp on || error_exit "parted set esp failed"
    if [ "$SWAP_SIZE" -gt 0 ]; then
        parted -s "$TARGET_DISK" mkpart primary linux-swap 1025MiB "$((1025 + SWAP_SIZE * 1024))MiB" || error_exit "parted mkpart swap failed"
        parted -s "$TARGET_DISK" mkpart primary "$ROOT_FS" "$((1025 + SWAP_SIZE * 1024))MiB" 100% || error_exit "parted mkpart root failed"
    else
        parted -s "$TARGET_DISK" mkpart primary "$ROOT_FS" 1025MiB 100% || error_exit "parted mkpart root failed"
    fi
else
    parted -s "$TARGET_DISK" mklabel msdos || error_exit "parted mklabel failed"
    parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 1025MiB || error_exit "parted mkpart boot failed"
    parted -s "$TARGET_DISK" set 1 boot on || error_exit "parted set boot failed"
    if [ "$SWAP_SIZE" -gt 0 ]; then
        parted -s "$TARGET_DISK" mkpart primary linux-swap 1025MiB "$((1025 + SWAP_SIZE * 1024))MiB" || error_exit "parted mkpart swap failed"
        parted -s "$TARGET_DISK" mkpart primary "$ROOT_FS" "$((1025 + SWAP_SIZE * 1024))MiB" 100% || error_exit "parted mkpart root failed"
    else
        parted -s "$TARGET_DISK" mkpart primary "$ROOT_FS" 1025MiB 100% || error_exit "parted mkpart root failed"
    fi
fi

if [[ "$TARGET_DISK" == *nvme* || "$TARGET_DISK" == *mmcblk* ]]; then
    SEP="p"
else
    SEP=""
fi

PART_BOOT="${TARGET_DISK}${SEP}1"
if [ "$SWAP_SIZE" -gt 0 ]; then
    PART_SWAP="${TARGET_DISK}${SEP}2"
    PART_ROOT="${TARGET_DISK}${SEP}3"
else
    PART_SWAP=""
    PART_ROOT="${TARGET_DISK}${SEP}2"
fi

echo "[2/8] Formatting partitions..."
if [ "$BOOT_MODE" = "UEFI" ]; then
    mkfs.vfat -F 32 "$PART_BOOT" || error_exit "formatting EFI partition failed"
else
    mkfs.ext4 -F "$PART_BOOT" || error_exit "formatting boot partition failed"
fi

if [ "$ROOT_FS" = "btrfs" ]; then
    mkfs.btrfs -f "$PART_ROOT" || error_exit "formatting root (btrfs) failed"
else
    mkfs.ext4 -F "$PART_ROOT" || error_exit "formatting root (ext4) failed"
fi

if [ -n "$PART_SWAP" ]; then
    mkswap "$PART_SWAP" || error_exit "Could not initialize swap partition."
    swapon "$PART_SWAP" || error_exit "Could not activate swap partition."
    SWAP_ACTIVATED="$PART_SWAP"
fi

mount "$PART_ROOT" /mnt || error_exit "Could not mount root partition."
INSTALL_MOUNTED=1
mkdir -p /mnt/boot
mount "$PART_BOOT" /mnt/boot || error_exit "Could not mount boot partition."

echo "==> Copying current pacman mirrorlist..."
mkdir -p /mnt/etc/pacman.d
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
CACHYOS_FAILED=0
if [ "$USE_CACHYOS_REPO" = "1" ]; then
    echo "[3/8] Adding CachyOS repository..."
    PACMAN_CONF_BACKUP=$(mktemp)
    cp /etc/pacman.conf "$PACMAN_CONF_BACKUP"
    CACHYOS_TMP=$(mktemp -d /tmp/h2os-cachyos.XXXXXX)
    if curl -fsSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o "$CACHYOS_TMP/cachyos-repo.tar.xz" \
        && tar -xf "$CACHYOS_TMP/cachyos-repo.tar.xz" -C "$CACHYOS_TMP" \
        && [[ -x "$CACHYOS_TMP/cachyos-repo/cachyos-repo.sh" ]] \
        && (cd "$CACHYOS_TMP/cachyos-repo" && ./cachyos-repo.sh); then
        echo "CachyOS repository setup completed."
    else
        echo "Warning: CachyOS setup failed; restoring pacman.conf and using Arch linux kernel."
        cp "$PACMAN_CONF_BACKUP" /etc/pacman.conf
        CACHYOS_FAILED=1
    fi
    rm -f "$PACMAN_CONF_BACKUP"
    rm -rf "$CACHYOS_TMP"

    if [ "$CACHYOS_FAILED" = "1" ]; then
        KERNEL_PKGS="linux linux-headers"
        KERNEL_VARIANT="linux (fallback)"
    else
        # Ставим keyring явно, чтобы целевая система могла доверять подписям
        # пакетов CachyOS и без ошибок делать pacman -Syu после установки.
        KERNEL_PKGS="$KERNEL_PKGS cachyos-keyring"
    fi
else
    echo "[3/8] Using standard Arch repositories (no CachyOS repo needed for Zen kernel)."
fi

# --------------------------------------------------------------------------
#
# --------------------------------------------------------------------------
echo "[4/8] Installing base system + XFCE + Firefox + fastfetch..."
if [ "$BOOT_MODE" = "UEFI" ]; then
    BOOTLOADER_PKGS="grub efibootmgr"
else
    BOOTLOADER_PKGS="grub"
fi

EXTRA_FS_PKGS=""
[ "$ROOT_FS" = "btrfs" ] && EXTRA_FS_PKGS="btrfs-progs"

pacstrap /mnt base $KERNEL_PKGS linux-firmware networkmanager nano sudo \
    xorg-server xfce4 xfce4-goodies xfce4-terminal lightdm lightdm-gtk-greeter \
    firefox git wine fastfetch $BOOTLOADER_PKGS $VIDEO_DRIVERS $EXTRA_FS_PKGS \
    || error_exit "pacstrap failed. Check internet connection and mirrorlist."

if [ "$USE_CACHYOS_REPO" = "1" ] && [ "$CACHYOS_FAILED" = "0" ]; then
    cp /etc/pacman.conf /mnt/etc/pacman.conf
    # pacman.conf may reference CachyOS mirrorlists installed only in the live environment.
    for mirror_file in /etc/pacman.d/*cachyos* /etc/pacman.d/*CachyOS*; do
        if [ -f "$mirror_file" ]; then
            cp -a "$mirror_file" /mnt/etc/pacman.d/
        fi
    done
fi

genfstab -U /mnt > /mnt/etc/fstab || error_exit "genfstab failed."

# The logo is on the live ISO, so copy it before entering the target chroot.
if [ -s /usr/share/h20s-custom/h20s-logo.txt ]; then
    install -m 0644 /usr/share/h20s-custom/h20s-logo.txt /mnt/etc/h20s-logo.txt
else
    printf 'H²0S Linux\n' > /mnt/etc/h20s-logo.txt
fi

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
echo "[5/8] Configuring system inside chroot..."
cat <<'CHROOT_SCRIPT' > /mnt/root/chroot-install.sh
#!/bin/bash
set -e

ln -sf /usr/share/zoneinfo/Asia/Almaty /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "h2os-pc" > /etc/hostname

cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   h2os-pc.localdomain h2os-pc
HOSTS

# === os-release ===
cat << 'OSRELEASE' > /etc/os-release
NAME="H²0S"
PRETTY_NAME="H²0S Linux"
ID=h2os
ID_LIKE=arch
ANSI_COLOR="0;36"
HOME_URL="https://h20s.ink/"
OSRELEASE
echo "H²0S Linux release" > /etc/issue
# Keep /etc/arch-release intact for compatibility with Arch-based tooling.

# === fastfetch ASCII logo ===
mkdir -p /etc/skel/.config/fastfetch
if [ ! -s /etc/h20s-logo.txt ]; then printf 'H²0S Linux\n' > /etc/h20s-logo.txt; fi
cat << 'FFCONFIG' > /etc/skel/.config/fastfetch/config.jsonc
{
  "logo": {
    "type": "file",
    "source": "/etc/h20s-logo.txt"
  }
}
FFCONFIG

# Read account details from stdin so passwords are not exposed in process arguments.
IFS= read -r -d '' NEW_USER || true
IFS= read -r -d '' USER_PASSWORD || true
IFS= read -r -d '' ROOT_PASSWORD || true
[[ -n "$NEW_USER" && -n "$USER_PASSWORD" && -n "$ROOT_PASSWORD" ]] || { echo "Missing account data on stdin." >&2; exit 1; }
printf '%s:%s\n' root "$ROOT_PASSWORD" | chpasswd
useradd -m -g users -G wheel,storage,power,audio,video -s /bin/bash "$NEW_USER"
printf '%s:%s\n' "$NEW_USER" "$USER_PASSWORD" | chpasswd
unset USER_PASSWORD ROOT_PASSWORD
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers >/dev/null

systemctl enable NetworkManager
systemctl enable lightdm

# === GRUB: брендинг + чистка меню ===
if grep -q '^GRUB_DISTRIBUTOR=' /etc/default/grub; then
    sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="H²0S Linux"/' /etc/default/grub
else
    printf '%s\n' 'GRUB_DISTRIBUTOR="H²0S Linux"' >> /etc/default/grub
fi
if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
else
    printf '%s\n' 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
fi
if grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub; then
    sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
else
    printf '%s\n' 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
fi

chmod -x /etc/grub.d/30_uefi-firmware 2>/dev/null || true
chmod -x /etc/grub.d/31_efi_bootnext 2>/dev/null || true

if [ "$BOOT_MODE" = "UEFI" ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=H2OS
else
    grub-install --target=i386-pc "$TARGET_DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# === Firefox ярлык на рабочем столе ===
mkdir -p /etc/skel/Desktop
cat << 'FFDESKTOP' > /etc/skel/Desktop/firefox.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
Comment=Browse the web
Exec=firefox %u
Icon=firefox
Terminal=false
Categories=Network;WebBrowser;
FFDESKTOP
chmod +x /etc/skel/Desktop/firefox.desktop


rm -rf /usr/share/backgrounds/xfce 2>/dev/null || true

exit
CHROOT_SCRIPT

chmod +x /mnt/root/chroot-install.sh
printf '%s\0%s\0%s\0' "$NEW_USER" "$USER_PASSWORD" "$ROOT_PASSWORD" | \
    arch-chroot /mnt env BOOT_MODE="$BOOT_MODE" TARGET_DISK="$TARGET_DISK" /root/chroot-install.sh
unset USER_PASSWORD USER_PASSWORD_CONFIRM ROOT_PASSWORD ROOT_PASSWORD_CONFIRM
rm -f /mnt/root/chroot-install.sh

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
echo "[6/8] Applying H2OS customization (themes, wallpapers)..."
mkdir -p /mnt/etc/skel/.config

[ -d "/usr/share/h20s-custom/xfce4" ] && cp -r /usr/share/h20s-custom/xfce4 /mnt/etc/skel/.config/
[ -d "/usr/share/h20s-custom/xfce4-terminal" ] && cp -r /usr/share/h20s-custom/xfce4-terminal /mnt/etc/skel/.config/

if [ -d "/usr/share/h20s-custom/themes" ]; then
    mkdir -p /mnt/etc/skel/.themes
    cp -r /usr/share/h20s-custom/themes/* /mnt/etc/skel/.themes/
fi
if [ -d "/usr/share/h20s-custom/icons" ]; then
    mkdir -p /mnt/etc/skel/.icons
    cp -r /usr/share/h20s-custom/icons/* /mnt/etc/skel/.icons/
fi

if [ -d "/usr/share/h20s-custom/wallpapers" ]; then
    mkdir -p /mnt/usr/share/backgrounds/h20s
    cp -r /usr/share/h20s-custom/wallpapers/* /mnt/usr/share/backgrounds/h20s/
fi

if ! grep -q '^[[:space:]]*fastfetch[[:space:]]*$' /mnt/etc/skel/.bashrc 2>/dev/null; then
    printf '\n# H²0S: Fastfetch in interactive shells\nif [[ $- == *i* ]] && command -v fastfetch >/dev/null 2>&1; then\n    fastfetch\nfi\n' >> /mnt/etc/skel/.bashrc
fi

# useradd ran before /etc/skel customization was copied, so apply it to the created user.
USER_HOME="/mnt/home/$NEW_USER"
mkdir -p "$USER_HOME/.config"
for item in xfce4 xfce4-terminal fastfetch; do
    if [ -d "/mnt/etc/skel/.config/$item" ]; then cp -a "/mnt/etc/skel/.config/$item" "$USER_HOME/.config/"; fi
done
if [ -d /mnt/etc/skel/.themes ]; then mkdir -p "$USER_HOME/.themes"; cp -a /mnt/etc/skel/.themes/. "$USER_HOME/.themes/"; fi
if [ -d /mnt/etc/skel/.icons ]; then mkdir -p "$USER_HOME/.icons"; cp -a /mnt/etc/skel/.icons/. "$USER_HOME/.icons/"; fi
if [ -f /mnt/etc/skel/Desktop/firefox.desktop ]; then mkdir -p "$USER_HOME/Desktop"; cp -a /mnt/etc/skel/Desktop/firefox.desktop "$USER_HOME/Desktop/"; fi
if ! grep -q '^[[:space:]]*fastfetch[[:space:]]*$' "$USER_HOME/.bashrc" 2>/dev/null; then
    printf '\n# H²0S: Fastfetch in interactive shells\nif [[ $- == *i* ]] && command -v fastfetch >/dev/null 2>&1; then\n    fastfetch\nfi\n' >> "$USER_HOME/.bashrc"
fi
chroot /mnt chown -R "$NEW_USER:users" "/home/$NEW_USER"
mkdir -p /mnt/root/.config
[ -d "/mnt/etc/skel/.config/fastfetch" ] && cp -a /mnt/etc/skel/.config/fastfetch /mnt/root/.config/

# --------------------------------------------------------------------------
# 
# --------------------------------------------------------------------------
echo "[7/8] Finalizing..."
sync

show_logo
echo -e "\e[32mH²0S installation completed successfully!\e[0m"
echo "Boot mode: $BOOT_MODE"
echo "Filesystem: $ROOT_FS"
echo "Kernel: $KERNEL_VARIANT"
echo "GPU drivers: $VIDEO_DRIVERS"
echo "[8/8] Please reboot, remove the installation media and log in as your new user."

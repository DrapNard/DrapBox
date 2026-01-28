#!/usr/bin/env bash
set -euo pipefail

die(){ echo "✗ $*" >&2; exit 1; }

HOSTNAME="$1"; USERNAME="$2"; USERPASS="$3"; ROOTPASS="$4"; TZ="$5"; LOCALE="$6"; KEYMAP="$7"; FS="$8"

[[ -n "${HOSTNAME:-}" ]] || die "Missing hostname"

echo "[chroot] base config..."

ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
hwclock --systohc

sed -i "s/^#\s*${LOCALE}/${LOCALE}/" /etc/locale.gen || true
sed -i 's/^#\s*en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
locale-gen

echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF_HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF_HOSTS

echo "root:$ROOTPASS" | chpasswd
id -u "$USERNAME" >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable iwd
systemctl enable bluetooth
systemctl enable drapbox-firstboot.service

bootctl install
ROOT_UUID="$(blkid -s UUID -o value "$(findmnt -no SOURCE /)")"
CMDLINE="quiet loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0"
if [[ "$FS" == "btrfs" ]]; then CMDLINE="$CMDLINE rootflags=subvol=@"; fi

mkdir -p /boot/loader/entries
cat >/boot/loader/loader.conf <<EOF_LOADER
default drapbox.conf
timeout 0
editor no
EOF_LOADER

cat >/boot/loader/entries/drapbox.conf <<EOF_ENTRY
title DrapBox
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=$ROOT_UUID rw $CMDLINE
EOF_ENTRY

echo "[chroot] fixing pacman keyring (PGP)..."
timedatectl set-ntp true >/dev/null 2>&1 || true
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
rm -f /var/cache/pacman/pkg/archlinux-keyring-*.pkg.tar.* 2>/dev/null || true
pacman -Syy --noconfirm
pacman -S --noconfirm --needed archlinux-keyring
pacman -Syu --noconfirm

mkdir -p /etc/fonts/conf.d
cat >/etc/fonts/local.conf <<'EOF_FONTS'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>JetBrainsMono Nerd Font</family>
      <family>JetBrains Mono</family>
    </prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>JetBrainsMono Nerd Font</family>
      <family>JetBrains Mono</family>
      <family>DejaVu Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>JetBrainsMono Nerd Font</family>
      <family>JetBrains Mono</family>
      <family>DejaVu Serif</family>
    </prefer>
  </alias>
</fontconfig>
EOF_FONTS

mkdir -p /etc/xdg/foot
if [[ ! -f /etc/xdg/foot/foot.ini ]]; then
  cat >/etc/xdg/foot/foot.ini <<'EOF_FOOT'
[main]
font=JetBrainsMono Nerd Font:size=12
EOF_FOOT
else
  if grep -q '^[[:space:]]*font=' /etc/xdg/foot/foot.ini; then
    sed -i 's|^[[:space:]]*font=.*|font=JetBrainsMono Nerd Font:size=12|' /etc/xdg/foot/foot.ini
  else
    printf "\n[main]\nfont=JetBrainsMono Nerd Font:size=12\n" >> /etc/xdg/foot/foot.ini
  fi
fi

if pacman -S --noconfirm --needed yay; then
  echo "[chroot] yay installed from repo."
else
  echo "[chroot] yay not in repo -> building from AUR (source) ..."
  pacman -S --noconfirm --needed git base-devel

  echo '%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/pacman-key' >/etc/sudoers.d/99-drapbox-pacman
  chmod 440 /etc/sudoers.d/99-drapbox-pacman

  BUILD_DIR="/tmp/aur-build"
  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
  chown -R "$USERNAME:$USERNAME" "$BUILD_DIR"

  su - "$USERNAME" -c "cd '$BUILD_DIR' && rm -rf yay-bin && git clone https://aur.archlinux.org/yay-bin.git"
  su - "$USERNAME" -c "cd '$BUILD_DIR/yay-bin' && makepkg -si --noconfirm --needed"
fi

command -v yay >/dev/null 2>&1 || die "yay missing"

want_repo=(uxplay gnome-network-displays)
for p in "${want_repo[@]}"; do
  if pacman -S --noconfirm --needed "$p"; then
    echo "[chroot] repo ok: $p"
  else
    echo "[chroot] repo missing -> yay: $p"
    su - "$USERNAME" -c "yay -S --noconfirm --needed $p"
  fi
done

rm -f /etc/sudoers.d/99-drapbox-pacman
echo "[chroot] done."

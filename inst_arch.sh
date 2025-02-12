#!/bin/bash
# Script d'installation Arch Linux automatisé avec LUKS + LVM
# Configuration répondant aux besoins suivants :
# - Disque de 80G, UEFI, 8G de RAM, virtualisation (VirtualBox)
# - Volume logique chiffré de 10G (monté manuellement par l'utilisateur)
# - Volume logique pour VirtualBox
# - Volume logique pour dossier partagé (5G)
# - Installation d'outils (navigateur, outils système, compilateur C, Hyprland custom, etc.)
# - Comptes utilisateurs : "pere" et "fils" (mot de passe par défaut : azerty123)

set -e  # Arrêt en cas d'erreur

#######################
# Variables globales  #
#######################
DISK="/dev/sda"              # Disque cible (à adapter si nécessaire)
PASSWORD="azerty123"         # Mot de passe par défaut
HOSTNAME="archmachine"       # Nom de la machine (à modifier si désiré)
VG_NAME="vg0"                # Nom du groupe de volumes LVM

# Schéma de partitionnement :
# - Partition 1 (EFI) : 512MiB
# - Partition 2 (chiffrée) : reste du disque (~79.5G)
#
# À l'intérieur de la partition chiffrée (via LUKS puis LVM) :
#   • lv_root   : 50G   -> système (monté sur /)
#   • lv_swap   : 4G    -> swap
#   • lv_secure : 10G   -> volume chiffré *à nouveau* par LUKS (sans point de montage)
#   • lv_vbox   : 10G   -> volume dédié à VirtualBox (monté sur /vbox)
#   • lv_shared : 5G    -> volume pour dossier partagé (monté sur /shared)

###############################
# 1. Partitionnement du disque #
###############################
echo "=== Partitionnement du disque $DISK ==="

# Création d'une table GPT
parted "$DISK" --script mklabel gpt

# Partition 1 : EFI (512MiB)
parted "$DISK" --script mkpart primary fat32 1MiB 513MiB
parted "$DISK" --script set 1 esp on

# Partition 2 : Reste du disque (sera entièrement chiffré)
parted "$DISK" --script mkpart primary ext4 513MiB 100%

###########################
# 2. Formatage et chiffrement EFI et LUKS #
###########################
echo "=== Formatage de la partition EFI ==="
mkfs.fat -F32 "${DISK}1"

echo "=== Chiffrement LUKS sur ${DISK}2 ==="
# Chiffrement de la partition principale
echo -n "$PASSWORD" | cryptsetup luksFormat "${DISK}2" -
echo -n "$PASSWORD" | cryptsetup open "${DISK}2" cryptroot

#######################
# 3. Configuration LVM #
#######################
echo "=== Création du volume physique et du groupe de volumes ==="
pvcreate /dev/mapper/cryptroot
vgcreate "$VG_NAME" /dev/mapper/cryptroot

echo "=== Création des volumes logiques ==="
lvcreate -L 50G -n lv_root "$VG_NAME"
lvcreate -L 4G  -n lv_swap "$VG_NAME"
lvcreate -L 10G -n lv_secure "$VG_NAME"
lvcreate -L 10G -n lv_vbox "$VG_NAME"
lvcreate -L 5G  -n lv_shared "$VG_NAME"

#############################
# 4. Formatage des volumes  #
#############################
echo "=== Formatage des volumes logiques ==="
mkfs.ext4 /dev/"$VG_NAME"/lv_root      # Système racine
mkfs.ext4 /dev/"$VG_NAME"/lv_vbox      # Volume VirtualBox
mkfs.ext4 /dev/"$VG_NAME"/lv_shared    # Dossier partagé
mkswap /dev/"$VG_NAME"/lv_swap         # Swap

# Pour le volume lv_secure, appliquer un chiffrement LUKS (encapsulation supplémentaire)
echo "=== Chiffrement LUKS sur le volume logique lv_secure ==="
echo -n "$PASSWORD" | cryptsetup luksFormat /dev/"$VG_NAME"/lv_secure -
echo -n "$PASSWORD" | cryptsetup open /dev/"$VG_NAME"/lv_secure secure
mkfs.ext4 /dev/mapper/secure

#############################
# 5. Montage des systèmes de fichiers #
#############################
echo "=== Montage des systèmes de fichiers ==="
# Monter la partition racine
mount /dev/"$VG_NAME"/lv_root /mnt

# Créer les points de montage
mkdir -p /mnt/boot /mnt/vbox /mnt/shared

# Monter la partition EFI
mount "${DISK}1" /mnt/boot

# Monter les volumes logiques dédiés
mount /dev/"$VG_NAME"/lv_vbox /mnt/vbox
mount /dev/"$VG_NAME"/lv_shared /mnt/shared

# Remarque : Le volume lv_secure ne sera pas monté automatiquement (l'utilisateur le fera à la main)

###################################
# 6. Installation de base d'Arch Linux #
###################################
echo "=== Installation de base avec pacstrap ==="
pacstrap /mnt base linux linux-firmware sudo nano networkmanager lvm2 cryptsetup grub efibootmgr mkinitcpio hyprland kitty firefox gcc neofetch htop base-devel virtualbox

echo "=== Génération du fichier fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab

####################################
# 7. Configuration du système en chroot #
####################################
echo "=== Chroot dans le nouveau système et configuration ==="
arch-chroot /mnt /bin/bash <<'EOF'
set -e

# --- Configuration système de base ---
echo "Configuration de la timezone et de la locale..."
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

echo "Génération de la locale..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "Définition du hostname..."
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTS_EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS_EOF

# --- Mise à jour de mkinitcpio ---
echo "Modification de /etc/mkinitcpio.conf pour intégrer les hooks 'encrypt' et 'lvm2'..."
sed -i 's/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- Comptes utilisateurs ---
echo "Définition du mot de passe root..."
echo "root:$PASSWORD" | chpasswd

echo "Création des comptes utilisateurs 'fils' et 'pere'..."
useradd -m -G wheel fils
useradd -m -G wheel pere
echo "fils:$PASSWORD" | chpasswd
echo "pere:$PASSWORD" | chpasswd

echo "Autorisation de sudo pour le groupe wheel..."
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# --- Installation du bootloader GRUB (UEFI) ---
echo "Installation et configuration de GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# --- Activation des services ---
echo "Activation de NetworkManager..."
systemctl enable NetworkManager

# --- Configuration personnalisée de Hyprland ---
echo "Création d'une configuration personnalisée pour Hyprland pour l'utilisateur 'pere'..."
mkdir -p /home/pere/.config/hypr
cat <<HYPR_EOF > /home/pere/.config/hypr/hyprland.conf
# Exemple de configuration Hyprland
monitor=,preferred
exec-once=kitty
border_size=2
gaps_out=10
gaps_in=10
HYPR_EOF
chown -R pere:pere /home/pere/.config

# --- Activation du swap ---
echo "Activation du swap..."
swapon /dev/$VG_NAME/lv_swap

# --- Rapport d'installation ---
echo "Création d'un rapport d'installation dans /root/installation_report.txt..."
cat <<REPORT_EOF > /root/installation_report.txt
=== lsblk -f ===
$(lsblk -f)

=== Contenu de /etc/passwd ===
$(cat /etc/passwd)

=== Contenu de /etc/group ===
$(cat /etc/group)

=== Contenu de /etc/fstab ===
$(cat /etc/fstab)

=== Contenu de /etc/mtab ===
$(cat /etc/mtab)

=== Hostname ===
$(cat /etc/hostname)

=== Log de pacman (installations) ===
$(grep -i installed /var/log/pacman.log)
REPORT_EOF

EOF

#########################################
# 8. Fin de l'installation et nettoyage #
#########################################
echo "=== Fin de l'installation, démontage et fermeture des conteneurs LUKS ==="
umount -R /mnt
swapoff /dev/"$VG_NAME"/lv_swap
cryptsetup close cryptroot
cryptsetup close secure

echo "=== Installation terminée ! Vous pouvez redémarrer. ==="

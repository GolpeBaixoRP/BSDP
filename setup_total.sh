#!/bin/bash

set -e

echo "===== FIX DNS ====="
mkdir -p /etc/systemd
cat > /etc/systemd/resolved.conf << EOL
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=8.8.4.4
EOL

systemctl enable systemd-resolved || true
systemctl restart systemd-resolved || true
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

echo "===== UPDATE ====="
apt update
apt upgrade -y
apt dist-upgrade -y

echo "===== PACOTES ====="
apt install -y \
openssh-server \
isc-dhcp-client \
isc-dhcp-server \
tftpd-hpa \
network-manager \
net-tools \
curl \
wget \
htop \
git \
dnsutils \
tcpdump \
nmap

echo "===== ATIVAR SERVICOS ====="
systemctl enable ssh
systemctl start ssh

systemctl enable NetworkManager
systemctl restart NetworkManager

echo "===== REDE ====="
ip link set enp3s0 up || true
dhclient enp3s0 || true

echo "===== PXE / TFTP ====="
mkdir -p /srv/tftp
chmod -R 755 /srv/tftp

cat > /etc/default/tftpd-hpa << EOL
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure"
EOL

systemctl enable tftpd-hpa
systemctl restart tftpd-hpa

echo "===== DHCP ====="
cat > /etc/dhcp/dhcpd.conf << EOL
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.1.0 netmask 255.255.255.0 {
 range 192.168.1.100 192.168.1.150;
 option routers 192.168.1.1;
 option subnet-mask 255.255.255.0;

 filename "bootx64.efi";
 next-server 192.168.1.200;
}
EOL

echo 'INTERFACESv4="enp3s0"' > /etc/default/isc-dhcp-server

systemctl enable isc-dhcp-server
systemctl restart isc-dhcp-server

echo "===== PXE BASE ====="
apt install -y grub-efi-amd64-bin

mkdir -p /srv/tftp/EFI/BOOT

cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi /srv/tftp/EFI/BOOT/bootx64.efi || true

echo "===== STATUS FINAL ====="
ip a

echo "===== TESTE REDE ====="
ping -c 2 8.8.8.8 || true
ping -c 2 google.com || true

echo "===== PORTAS ====="
ss -tulnp

echo "===== OK FINALIZADO ====="

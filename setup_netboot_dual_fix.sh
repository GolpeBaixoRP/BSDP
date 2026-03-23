#!/usr/bin/env bash
set -euo pipefail

BOOT_IF="${BOOT_IF:-enp3s0}"
SERVER_IP="${SERVER_IP:-192.168.50.1}"
LEASE_IP="${LEASE_IP:-192.168.50.100}"

TFTP_ROOT="/srv/tftp"
NETBOOT_ROOT="${TFTP_ROOT}/NetBoot/NetBootSP0"

# Imagem 1: manutenção via NFS
MAINT_ID=1
MAINT_NAME="Maintenance NFS"
MAINT_BOOT_FILE="NetBoot/NetBootSP0/tiger.nbi/booter"
MAINT_NBI_DIR="${NETBOOT_ROOT}/tiger.nbi"
MAINT_NFS_ROOT="/srv/netboot/maintenance-root"

# Imagem 2: instalação via HTTP/DMG
INSTALL_ID=2
INSTALL_NAME="Install DMG"
INSTALL_NBI_DIR="${NETBOOT_ROOT}/install.nbi"
INSTALL_BOOT_FILE="NetBoot/NetBootSP0/install.nbi/booter"
INSTALL_DMG="${INSTALL_NBI_DIR}/NetInstall.dmg"

BSDP_FILE="/opt/bsdpy/bsdpserver.py"
BSDP_SERVICE="/etc/systemd/system/bsdpserver.service"
HTTP_SERVICE="/etc/systemd/system/netboot-http.service"
EXPORTS_FILE="/etc/exports.d/netboot.exports"

mkdir -p /opt/bsdpy /etc/exports.d "${TFTP_ROOT}" "${NETBOOT_ROOT}" /srv/netboot

echo "==> 1) Instalando pacotes base"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 nfs-kernel-server rpcbind dnsmasq curl

echo
echo "==> 2) Garantindo IP da interface de boot"
ip link set "${BOOT_IF}" up
ip addr flush dev "${BOOT_IF}" || true
ip addr add "${SERVER_IP}/24" dev "${BOOT_IF}" || true
ip -br a show dev "${BOOT_IF}"

echo
echo "==> 3) Detectando payloads reais"
MAINT_ENABLED=0
INSTALL_ENABLED=0

if [[ -f "${MAINT_NBI_DIR}/booter" && -d "${MAINT_NFS_ROOT}" ]] && find "${MAINT_NFS_ROOT}" -mindepth 1 -maxdepth 1 >/dev/null 2>&1; then
  MAINT_ENABLED=1
fi

if [[ -f "${INSTALL_NBI_DIR}/booter" && -f "${INSTALL_DMG}" ]]; then
  INSTALL_ENABLED=1
fi

echo "Maintenance NFS enabled: ${MAINT_ENABLED}"
echo "Install DMG enabled: ${INSTALL_ENABLED}"

echo
echo "==> 4) Configurando NFS"
if [[ "${MAINT_ENABLED}" -eq 1 ]]; then
  cat > "${EXPORTS_FILE}" <<EOF
${MAINT_NFS_ROOT} *(ro,sync,no_subtree_check,no_root_squash,insecure)
EOF
else
  : > "${EXPORTS_FILE}"
fi

exportfs -ra
systemctl enable rpcbind nfs-kernel-server >/dev/null 2>&1 || true
systemctl restart rpcbind nfs-kernel-server

echo
echo "==> 5) Criando serviço HTTP"
cat > "${HTTP_SERVICE}" <<EOF
[Unit]
Description=NetBoot HTTP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${TFTP_ROOT}
ExecStart=/usr/bin/python3 -m http.server 80 --bind ${SERVER_IP}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable netboot-http >/dev/null 2>&1 || true
systemctl restart netboot-http

echo
echo "==> 6) Gerando BSDP server dual"
PY27="/usr/local/bin/python2.7"
if [[ ! -x "${PY27}" ]]; then
  PY27="$(command -v python2.7 || true)"
fi
if [[ -z "${PY27}" ]]; then
  echo "ERRO: python2.7 nao encontrado."
  exit 1
fi

python3 - <<PY
from pathlib import Path

SERVER_IP = ${SERVER_IP@Q}
LEASE_IP = ${LEASE_IP@Q}
BOOT_IF = ${BOOT_IF@Q}

MAINT_ENABLED = int(${MAINT_ENABLED})
INSTALL_ENABLED = int(${INSTALL_ENABLED})

MAINT_ID = int(${MAINT_ID})
MAINT_NAME = ${MAINT_NAME@Q}
MAINT_BOOT_FILE = ${MAINT_BOOT_FILE@Q}
MAINT_NFS_ROOT = ${MAINT_NFS_ROOT@Q}

INSTALL_ID = int(${INSTALL_ID})
INSTALL_NAME = ${INSTALL_NAME@Q}
INSTALL_BOOT_FILE = ${INSTALL_BOOT_FILE@Q}

images = []
if MAINT_ENABLED:
    images.append({
        "id": MAINT_ID,
        "name": MAINT_NAME,
        "boot_file": MAINT_BOOT_FILE,
        "root_path": "nfs:%s:%s" % (SERVER_IP, MAINT_NFS_ROOT),
        "mode": "nfs",
    })

if INSTALL_ENABLED:
    images.append({
        "id": INSTALL_ID,
        "name": INSTALL_NAME,
        "boot_file": INSTALL_BOOT_FILE,
        "root_path": "http://%s/NetBoot/NetBootSP0/install.nbi/NetInstall.dmg" % SERVER_IP,
        "mode": "http",
    })

content = """#!/usr/bin/env python2
from pydhcplib.dhcp_packet import *
from pydhcplib.dhcp_network import *
import logging
import socket

LISTEN_IP = "0.0.0.0"
SERVER_IP = %(server_ip)r
LEASE_IP  = %(lease_ip)r
IFACE     = %(iface)r

logging.basicConfig(
    level=logging.DEBUG,
    filename='/var/log/bsdpserver.log'
)

def ip_to_bytes(ip):
    return [int(x) for x in ip.split('.')]

def str_to_list(s):
    return [ord(c) for c in s]

def padded_list(s, n):
    raw = str_to_list(s)
    if len(raw) < n:
        raw += [0] * (n - len(raw))
    return raw[:n]

def image_id_bytes(image_id):
    hx = "%%04X" %% int(image_id)
    return [0x81, 0x00, int(hx[0:2], 16), int(hx[2:4], 16)]

IMAGES = %(images)r

if not IMAGES:
    logging.debug("Nenhuma imagem bootavel habilitada. Servidor vai responder DHCP, mas nao BSDP util.")

def get_image_by_id(image_id):
    for img in IMAGES:
        if int(img["id"]) == int(image_id):
            return img
    return None

def parse_selected_image_id(veo):
    i = 0
    while i + 1 < len(veo):
        tag = veo[i]
        ln = veo[i+1]
        data = veo[i+2:i+2+ln]
        if tag == 8 and ln == 4 and len(data) == 4:
            return (data[2] << 8) | data[3]
        i += 2 + ln
    return None

def build_bsdp_list_payload():
    payload = [1,1,1, 4,2,128,128]

    if IMAGES:
        default_img = image_id_bytes(IMAGES[0]["id"])
        payload += [7, 4] + default_img

    image_entries = []
    for img in IMAGES:
        img_id = image_id_bytes(img["id"])
        name_bytes = str_to_list(img["name"])
        entry = img_id + [len(name_bytes)] + name_bytes
        image_entries += entry

    payload += [9, len(image_entries)] + image_entries
    return payload

def build_bsdp_select_payload(image_id):
    img = image_id_bytes(image_id)
    return [1,1,2, 8,4] + img

class Server(DhcpNetwork):
    def __init__(self):
        DhcpNetwork.__init__(self, LISTEN_IP, 67, 68)
        self.EnableBroadcast()
        self.CreateSocket()

        bound = False
        for attr in ('dhcp_socket', 'socket'):
            try:
                s = getattr(self, attr)
                s.setsockopt(socket.SOL_SOCKET, 25, IFACE + "\\0")
                logging.debug("SO_BINDTODEVICE aplicado em %%s para %%s" %% (attr, IFACE))
                bound = True
                break
            except Exception:
                pass

        if not bound:
            logging.debug("SO_BINDTODEVICE nao aplicado em nenhum socket conhecido")

        self.BindToAddress()

    def common_reply(self, pkt):
        p = DhcpPacket()
        p.SetOption("op", [2])
        p.SetOption("htype", pkt.GetOption('htype'))
        p.SetOption("hlen", pkt.GetOption('hlen'))
        p.SetOption("xid", pkt.GetOption('xid'))
        p.SetOption("chaddr", pkt.GetOption('chaddr'))
        p.SetOption("siaddr", ip_to_bytes(SERVER_IP))
        p.SetOption("server_identifier", ip_to_bytes(SERVER_IP))
        return p

    def offer(self, pkt):
        p = self.common_reply(pkt)
        p.SetOption("yiaddr", ip_to_bytes(LEASE_IP))
        p.SetOption("dhcp_message_type", [2])
        logging.debug("OFFER %%s" %% LEASE_IP)
        return p, "255.255.255.255", 68

    def ack(self, pkt):
        p = self.common_reply(pkt)
        p.SetOption("yiaddr", ip_to_bytes(LEASE_IP))
        p.SetOption("dhcp_message_type", [5])
        logging.debug("ACK %%s" %% LEASE_IP)
        return p, "255.255.255.255", 68

    def inform(self, pkt):
        try:
            veo = pkt.GetOption('vendor_encapsulated_options')
        except Exception:
            veo = []

        try:
            vci = pkt.GetOption('vendor_class_identifier')
        except Exception:
            vci = []

        logging.debug("INFORM recebido")
        logging.debug("vendor_class_identifier=%%r" %% (vci,))
        logging.debug("vendor_encapsulated_options=%%r" %% (veo,))

        if not IMAGES:
            logging.debug("Sem imagens habilitadas para responder BSDP")
            return None

        p = self.common_reply(pkt)
        p.SetOption("yiaddr", [0,0,0,0])
        p.SetOption("ciaddr", pkt.GetOption('ciaddr'))
        p.SetOption("dhcp_message_type", [5])
        p.SetOption("vendor_class_identifier", str_to_list("AAPLBSDPC"))

        if len(veo) > 2 and veo[2] == 1:
            payload = build_bsdp_list_payload()
            p.SetOption("vendor_encapsulated_options", payload)
            logging.debug("BSDP LIST respondido com %%d imagens" %% len(IMAGES))

            target_ip = "255.255.255.255"
            try:
                ci = pkt.GetOption('ciaddr')
                if ci and ci != [0,0,0,0]:
                    target_ip = ".".join([str(x) for x in ci])
            except Exception:
                pass

            return p, target_ip, 68

        if len(veo) > 2 and veo[2] == 2:
            selected = parse_selected_image_id(veo)
            img = get_image_by_id(selected) if selected is not None else IMAGES[0]
            if img is None:
                logging.debug("BSDP SELECT pediu imagem inexistente: %%r" %% (selected,))
                return None

            payload = build_bsdp_select_payload(img["id"])
            p.SetOption("vendor_encapsulated_options", payload)
            p.SetOption("file", padded_list(img["boot_file"], 128))
            p.SetOption("root_path", str_to_list(img["root_path"]))

            logging.debug("BSDP SELECT respondido id=%%s name=%%s mode=%%s root=%%s" %% (
                img["id"], img["name"], img["mode"], img["root_path"]
            ))

            target_ip = "255.255.255.255"
            try:
                ci = pkt.GetOption('ciaddr')
                if ci and ci != [0,0,0,0]:
                    target_ip = ".".join([str(x) for x in ci])
            except Exception:
                pass

            return p, target_ip, 68

        logging.debug("INFORM sem tipo BSDP reconhecido")
        return None

    def handle(self, pkt):
        try:
            raw = pkt.GetOption('dhcp_message_type')
            logging.debug("dhcp_message_type raw=%%r" %% (raw,))
            msg = raw[0]

            if msg == 1:
                logging.debug("DISCOVER recebido")
                return self.offer(pkt)

            if msg == 3:
                logging.debug("REQUEST recebido")
                return self.ack(pkt)

            if msg == 8:
                return self.inform(pkt)

            logging.debug("Tipo DHCP nao tratado: %%r" %% (msg,))
            return None
        except Exception:
            logging.exception("Falha em handle()")
            return None

def main():
    logging.debug("=== BSDP DUAL START ===")
    logging.debug("LISTEN_IP=%%s SERVER_IP=%%s LEASE_IP=%%s IFACE=%%s" %% (LISTEN_IP, SERVER_IP, LEASE_IP, IFACE))
    logging.debug("IMAGES=%%r" %% (IMAGES,))

    s = Server()

    while True:
        try:
            pkt = s.GetNextDhcpPacket()
            logging.debug("GetNextDhcpPacket() retornou: %%r" %% (pkt,))
            if pkt:
                r = s.handle(pkt)
                if r:
                    p, ip, port = r
                    logging.debug("Enviando resposta para %%s:%%s via %%s" %% (ip, port, IFACE))
                    s.SendDhcpPacketTo(p, ip, port)
        except Exception:
            logging.exception("Falha no loop principal")

if __name__ == "__main__":
    main()
""" % {
    "server_ip": SERVER_IP,
    "lease_ip": LEASE_IP,
    "iface": BOOT_IF,
    "images": images,
}

Path("/opt/bsdpy/bsdpserver.py").write_text(content)
PY

chmod +x "${BSDP_FILE}"

echo
echo "==> 7) Criando serviço do BSDP"
cat > "${BSDP_SERVICE}" <<EOF
[Unit]
Description=Custom BSDP server
After=network-online.target
Wants=network-online.target netboot-http.service

[Service]
Type=simple
ExecStart=${PY27} ${BSDP_FILE}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bsdpserver >/dev/null 2>&1 || true
systemctl restart bsdpserver

echo
echo "==> 8) Status final"
echo "--- Interface"
ip -br a show dev "${BOOT_IF}"
echo
echo "--- HTTP"
systemctl --no-pager --full status netboot-http | sed -n '1,20p' || true
echo
echo "--- NFS"
systemctl --no-pager --full status nfs-kernel-server | sed -n '1,20p' || true
echo
echo "--- BSDP"
systemctl --no-pager --full status bsdpserver | sed -n '1,30p' || true
echo
echo "--- Portas"
ss -ltnp | grep ':80' || true
ss -lunp | egrep ':67|:69|:111|:2049' || true
echo
echo "--- Exports"
exportfs -v || true
echo
echo "--- Logs BSDP"
tail -n 40 /var/log/bsdpserver.log || true

echo
echo "==> 9) Resumo"
if [[ "${MAINT_ENABLED}" -eq 1 ]]; then
  echo "Imagem NFS habilitada: ${MAINT_NAME}"
  echo "  booter : ${MAINT_BOOT_FILE}"
  echo "  root   : nfs:${SERVER_IP}:${MAINT_NFS_ROOT}"
else
  echo "Imagem NFS DESABILITADA"
  echo "  Para habilitar, coloque um root filesystem macOS completo em:"
  echo "  ${MAINT_NFS_ROOT}"
fi

if [[ "${INSTALL_ENABLED}" -eq 1 ]]; then
  echo "Imagem DMG habilitada: ${INSTALL_NAME}"
  echo "  booter : ${INSTALL_BOOT_FILE}"
  echo "  dmg    : http://${SERVER_IP}/NetBoot/NetBootSP0/install.nbi/NetInstall.dmg"
else
  echo "Imagem DMG DESABILITADA"
  echo "  Para habilitar, coloque estes arquivos:"
  echo "  ${INSTALL_NBI_DIR}/booter"
  echo "  ${INSTALL_DMG}"
fi

echo
echo "Pronto."

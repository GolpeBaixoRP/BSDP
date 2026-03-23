#!/usr/bin/env python2
from pydhcplib.dhcp_packet import *
from pydhcplib.dhcp_network import *
import logging
import socket

LISTEN_IP = "0.0.0.0"
SERVER_IP = "192.168.50.1"
LEASE_IP  = "192.168.50.100"
IFACE     = "enp3s0"

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
    hx = "%04X" % int(image_id)
    return [0x81, 0x00, int(hx[0:2], 16), int(hx[2:4], 16)]

IMAGE_ID = 1
IMAGE_NAME = "Tiger PPC NetBoot"
BOOT_FILE = "NetBoot/NetBootSP0/tiger.nbi/booter"
ROOT_PATH = "nfs:192.168.50.1:/srv/tftp/NetBoot/NetBootSP0/tiger.nbi"

def build_bsdp_list_payload():
    name_bytes = str_to_list(IMAGE_NAME)
    img = image_id_bytes(IMAGE_ID)
    image_entry = img + [len(name_bytes)] + name_bytes
    img_list = [9, len(image_entry)] + image_entry
    default_img = [7, 4] + img
    payload = [1,1,1, 4,2,128,128] + default_img + img_list
    return payload

def build_bsdp_select_payload():
    img = image_id_bytes(IMAGE_ID)
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
                s.setsockopt(socket.SOL_SOCKET, 25, IFACE + "\0")
                logging.debug("SO_BINDTODEVICE aplicado em %s para %s" % (attr, IFACE))
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
        logging.debug("OFFER %s" % LEASE_IP)
        return p, "255.255.255.255", 68

    def ack(self, pkt):
        p = self.common_reply(pkt)
        p.SetOption("yiaddr", ip_to_bytes(LEASE_IP))
        p.SetOption("dhcp_message_type", [5])
        logging.debug("ACK %s" % LEASE_IP)
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
        logging.debug("vendor_class_identifier=%r" % (vci,))
        logging.debug("vendor_encapsulated_options=%r" % (veo,))

        p = self.common_reply(pkt)
        p.SetOption("yiaddr", [0,0,0,0])
        p.SetOption("ciaddr", pkt.GetOption('ciaddr'))
        p.SetOption("dhcp_message_type", [5])
        p.SetOption("vendor_class_identifier", str_to_list("AAPLBSDPC"))

        if len(veo) > 2 and veo[2] == 1:
            payload = build_bsdp_list_payload()
            p.SetOption("vendor_encapsulated_options", payload)
            logging.debug("BSDP LIST respondido")

            target_ip = "255.255.255.255"
            try:
                ci = pkt.GetOption('ciaddr')
                if ci and ci != [0,0,0,0]:
                    target_ip = ".".join([str(x) for x in ci])
            except Exception:
                pass

            return p, target_ip, 68

        if len(veo) > 2 and veo[2] == 2:
            payload = build_bsdp_select_payload()
            p.SetOption("vendor_encapsulated_options", payload)
            p.SetOption("file", padded_list(BOOT_FILE, 128))
            p.SetOption("root_path", str_to_list(ROOT_PATH))
            logging.debug("BSDP SELECT respondido com BOOT_FILE=%s ROOT_PATH=%s" % (BOOT_FILE, ROOT_PATH))

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
            logging.debug("dhcp_message_type raw=%r" % (raw,))
            msg = raw[0]

            if msg == 1:
                logging.debug("DISCOVER recebido")
                return self.offer(pkt)

            if msg == 3:
                logging.debug("REQUEST recebido")
                return self.ack(pkt)

            if msg == 8:
                return self.inform(pkt)

            logging.debug("Tipo DHCP nao tratado: %r" % (msg,))
            return None
        except Exception:
            logging.exception("Falha em handle()")
            return None

def main():
    logging.debug("=== BSDP RESTORE START ===")
    s = Server()

    while True:
        try:
            pkt = s.GetNextDhcpPacket()
            logging.debug("GetNextDhcpPacket() retornou: %r" % (pkt,))
            if pkt:
                r = s.handle(pkt)
                if r:
                    p, ip, port = r
                    logging.debug("Enviando resposta para %s:%s via %s" % (ip, port, IFACE))
                    s.SendDhcpPacketTo(p, ip, port)
        except Exception:
            logging.exception("Falha no loop principal")

if __name__ == "__main__":
    main()

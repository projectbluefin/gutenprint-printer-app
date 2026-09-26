#!/usr/bin/env python3
"""Browse a DNS-SD service type on the local link with plain mDNS.

Joins the mDNS group and sends multicast PTR queries from port 5353 for the
requested service type, then resolves each instance with SRV and TXT queries.
Responders answer by multicast with full-size packets, so this observes what
any other host on the LAN would see, without an Avahi client library. If port
5353 cannot be shared, it falls back to legacy-unicast queries (RFC 6762
section 6.7), whose replies Avahi truncates to 512 bytes.

Usage: mdns-browse.py <service type, e.g. _ipp._tcp> [seconds per query]

Prints one JSON object per line: {"name", "type", "port", "target", "txt"}.
"""
import json
import socket
import struct
import sys
import time

MDNS_GROUP = "224.0.0.251"
MDNS_PORT = 5353
TYPE_PTR = 12
TYPE_TXT = 16
TYPE_SRV = 33
TYPE_ANY = 255
CLASS_IN = 1
QUERY_ROUNDS = 3


def encode_name(name):
    out = b""
    for label in name.strip(".").split("."):
        raw = label.encode()
        out += struct.pack("B", len(raw)) + raw
    return out + b"\0"


def build_query(name, qtype):
    header = struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0)
    return header + encode_name(name) + struct.pack(">HH", qtype, CLASS_IN)


def decode_name(packet, offset):
    labels = []
    jumped = False
    end = offset
    hops = 0
    while True:
        length = packet[offset]
        if length & 0xC0 == 0xC0:
            pointer = struct.unpack(">H", packet[offset : offset + 2])[0] & 0x3FFF
            if not jumped:
                end = offset + 2
            jumped = True
            offset = pointer
            hops += 1
            if hops > 64:
                raise ValueError("compression loop")
            continue
        offset += 1
        if length == 0:
            if not jumped:
                end = offset
            break
        labels.append(packet[offset : offset + length].decode("utf-8", "replace"))
        offset += length
    return ".".join(labels), end


def parse_records(packet):
    """Yield (name, type, rdata) for every answer/authority/additional record."""
    _id, _flags, qdcount, ancount, nscount, arcount = struct.unpack(">HHHHHH", packet[:12])
    offset = 12
    for _ in range(qdcount):
        _name, offset = decode_name(packet, offset)
        offset += 4
    for _ in range(ancount + nscount + arcount):
        name, offset = decode_name(packet, offset)
        rtype, _rclass, _ttl, rdlength = struct.unpack(">HHIH", packet[offset : offset + 10])
        offset += 10
        rdata_offset = offset
        offset += rdlength
        if rtype == TYPE_PTR:
            target, _ = decode_name(packet, rdata_offset)
            yield name, rtype, target
        elif rtype == TYPE_SRV:
            _priority, _weight, port = struct.unpack(">HHH", packet[rdata_offset : rdata_offset + 6])
            target, _ = decode_name(packet, rdata_offset + 6)
            yield name, rtype, (port, target)
        elif rtype == TYPE_TXT:
            txt = []
            cursor = rdata_offset
            while cursor < rdata_offset + rdlength:
                length = packet[cursor]
                cursor += 1
                txt.append(packet[cursor : cursor + length].decode("utf-8", "replace"))
                cursor += length
            yield name, rtype, txt


def query(sock, name, qtype, seconds):
    """Send one query and collect every record from the replies."""
    records = []
    sock.sendto(build_query(name, qtype), (MDNS_GROUP, MDNS_PORT))
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        sock.settimeout(remaining)
        try:
            packet, _peer = sock.recvfrom(65535)
        except socket.timeout:
            break
        try:
            records.extend(parse_records(packet))
        except (ValueError, IndexError, struct.error):
            continue
    return records


def open_socket():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
    try:
        sock.bind(("0.0.0.0", MDNS_PORT))
        membership = socket.inet_aton(MDNS_GROUP) + socket.inet_aton("0.0.0.0")
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
    except OSError as error:
        print(f"mdns-browse: multicast port unavailable ({error}); using legacy unicast", file=sys.stderr)
        sock.bind(("0.0.0.0", 0))
    return sock


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    service_type = sys.argv[1].strip(".")
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
    ptr_name = f"{service_type}.local"

    instances = set()
    srv = {}
    txt = {}
    with open_socket() as sock:
        for _ in range(QUERY_ROUNDS):
            for name, rtype, rdata in query(sock, ptr_name, TYPE_PTR, seconds):
                if rtype == TYPE_PTR and name.lower() == ptr_name.lower():
                    instances.add(rdata)
                elif rtype == TYPE_SRV:
                    srv.setdefault(name, set()).add(rdata)
                elif rtype == TYPE_TXT:
                    txt.setdefault(name, set()).add(tuple(rdata))
        for instance in sorted(instances):
            if instance in srv and instance in txt:
                continue
            for name, rtype, rdata in query(sock, instance, TYPE_ANY, seconds):
                if rtype == TYPE_SRV:
                    srv.setdefault(name, set()).add(rdata)
                elif rtype == TYPE_TXT:
                    txt.setdefault(name, set()).add(tuple(rdata))

    for instance in sorted(instances):
        suffix = f".{ptr_name}"
        name = instance[: -len(suffix)] if instance.lower().endswith(suffix.lower()) else instance
        for port, target in sorted(srv.get(instance, {(None, None)})):
            for entries in sorted(txt.get(instance, {()})):
                print(
                    json.dumps(
                        {"name": name, "type": service_type, "port": port, "target": target, "txt": list(entries)}
                    )
                )


if __name__ == "__main__":
    main()

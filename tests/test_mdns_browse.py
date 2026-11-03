"""Unit coverage for the dependency-free mDNS resolver used by coexistence.sh.

tests/coexistence.sh decides whether two instances keep their DNS-SD
advertisements isolated purely from what mdns-browse.py prints, and
mdns-browse.query() swallows every parse error, so a decoding regression
silently removes records instead of failing. These cases drive the wire
decoders directly with hand-built packets, and query() and main() through a
fake socket that answers with such packets: no network, no image, no Avahi.
"""
import contextlib
import importlib.util
import io
import json
import signal
import socket
import struct
import unittest
from unittest import mock
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "mdns_browse", Path(__file__).resolve().parent / "mdns-browse.py")
mdns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mdns)


def _alarm(_signum, _frame):
    raise AssertionError("decode_name did not terminate: the compression hop guard is gone")


def header(qdcount=0, ancount=0, nscount=0, arcount=0):
    return struct.pack(">HHHHHH", 0, 0, qdcount, ancount, nscount, arcount)


def record(name, rtype, rdata):
    return name + struct.pack(">HHIH", rtype, mdns.CLASS_IN, 120, len(rdata)) + rdata


def srv_rdata(port, target):
    return struct.pack(">HHH", 0, 0, port) + mdns.encode_name(target)


def txt_rdata(*strings):
    out = b""
    for string in strings:
        raw = string.encode()
        out += struct.pack("B", len(raw)) + raw
    return out


class EncodeNameTests(unittest.TestCase):
    def test_labels_are_length_prefixed_and_root_terminated(self):
        self.assertEqual(mdns.encode_name("_ipp._tcp.local"),
                         b"\x04_ipp\x04_tcp\x05local\x00")

    def test_trailing_dot_does_not_add_an_empty_label(self):
        self.assertEqual(mdns.encode_name("_ipp._tcp.local."),
                         mdns.encode_name("_ipp._tcp.local"))

    def test_instance_labels_may_contain_spaces_and_dashes(self):
        self.assertEqual(mdns.encode_name("gutenprint a._ipp._tcp.local"),
                         b"\x0cgutenprint a\x04_ipp\x04_tcp\x05local\x00")


class BuildQueryTests(unittest.TestCase):
    def test_one_question_with_the_requested_type_and_class(self):
        packet = mdns.build_query("_ipp._tcp.local", mdns.TYPE_PTR)
        self.assertEqual(struct.unpack(">HHHHHH", packet[:12]), (0, 0, 1, 0, 0, 0))
        name, end = mdns.decode_name(packet, 12)
        self.assertEqual(name, "_ipp._tcp.local")
        self.assertEqual(struct.unpack(">HH", packet[end:end + 4]),
                         (mdns.TYPE_PTR, mdns.CLASS_IN))

    def test_any_query_is_used_to_resolve_an_instance(self):
        packet = mdns.build_query("a._ipp._tcp.local", mdns.TYPE_ANY)
        _name, end = mdns.decode_name(packet, 12)
        self.assertEqual(struct.unpack(">H", packet[end:end + 2])[0], mdns.TYPE_ANY)


class DecodeNameTests(unittest.TestCase):
    def test_uncompressed_name_reports_the_offset_after_the_root_label(self):
        packet = b"\x00" * 12 + mdns.encode_name("_ipp._tcp.local")
        self.assertEqual(mdns.decode_name(packet, 12), ("_ipp._tcp.local", len(packet)))

    def test_pointer_resolves_and_consumes_only_the_two_pointer_bytes(self):
        packet = b"\x00" * 12 + mdns.encode_name("_ipp._tcp.local")
        suffix = len(packet)
        packet += b"\x01a" + struct.pack(">H", 0xC000 | 12) + b"\xff"
        self.assertEqual(mdns.decode_name(packet, suffix), ("a._ipp._tcp.local", suffix + 4))

    def test_pointer_chain_is_followed(self):
        packet = b"\x00" * 12 + mdns.encode_name("local")
        first = len(packet)
        packet += b"\x04_tcp" + struct.pack(">H", 0xC000 | 12)
        second = len(packet)
        packet += b"\x04_ipp" + struct.pack(">H", 0xC000 | first)
        self.assertEqual(mdns.decode_name(packet, second), ("_ipp._tcp.local", second + 7))

    def test_compression_loop_is_rejected_rather_than_hanging(self):
        packet = b"\x00" * 12 + struct.pack(">H", 0xC000 | 12)
        # Without the hop guard this loops forever, which would hang the job
        # instead of reporting it; the alarm turns that into a failure.
        previous = signal.signal(signal.SIGALRM, _alarm)
        signal.alarm(10)
        try:
            with self.assertRaises(ValueError):
                mdns.decode_name(packet, 12)
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous)

    def test_truncated_name_raises_so_query_can_drop_the_packet(self):
        with self.assertRaises(IndexError):
            mdns.decode_name(b"\x00" * 12 + b"\x05loc", 12)


class ParseRecordsTests(unittest.TestCase):
    def test_questions_are_skipped_before_the_answers(self):
        name = mdns.encode_name("_ipp._tcp.local")
        packet = (header(qdcount=1, ancount=1) + name + struct.pack(">HH", mdns.TYPE_PTR, mdns.CLASS_IN)
                  + record(name, mdns.TYPE_PTR, mdns.encode_name("a._ipp._tcp.local")))
        self.assertEqual(list(mdns.parse_records(packet)),
                         [("_ipp._tcp.local", mdns.TYPE_PTR, "a._ipp._tcp.local")])

    def test_srv_yields_the_advertised_port_and_target(self):
        name = mdns.encode_name("a._ipp._tcp.local")
        packet = header(ancount=1) + record(name, mdns.TYPE_SRV, srv_rdata(18401, "host.local"))
        self.assertEqual(list(mdns.parse_records(packet)),
                         [("a._ipp._tcp.local", mdns.TYPE_SRV, (18401, "host.local"))])

    def test_txt_splits_every_character_string(self):
        name = mdns.encode_name("a._ipp._tcp.local")
        packet = header(ancount=1) + record(
            name, mdns.TYPE_TXT, txt_rdata("txtvers=1", "rp=ipp/print/a", "ty=Synthetic"))
        self.assertEqual(list(mdns.parse_records(packet))[0][2],
                         ["txtvers=1", "rp=ipp/print/a", "ty=Synthetic"])

    def test_authority_and_additional_sections_are_parsed(self):
        ptr = mdns.encode_name("_ipp._tcp.local")
        instance = mdns.encode_name("a._ipp._tcp.local")
        packet = (header(ancount=1, nscount=1, arcount=1)
                  + record(ptr, mdns.TYPE_PTR, mdns.encode_name("a._ipp._tcp.local"))
                  + record(instance, mdns.TYPE_SRV, srv_rdata(18400, "host.local"))
                  + record(instance, mdns.TYPE_TXT, txt_rdata("rp=ipp/print/a")))
        self.assertEqual([rtype for _name, rtype, _rdata in mdns.parse_records(packet)],
                         [mdns.TYPE_PTR, mdns.TYPE_SRV, mdns.TYPE_TXT])

    def test_unknown_record_types_are_skipped_without_losing_alignment(self):
        instance = mdns.encode_name("a._ipp._tcp.local")
        packet = (header(ancount=2)
                  + record(mdns.encode_name("host.local"), 1, b"\xc0\xa8\x01\x05")
                  + record(instance, mdns.TYPE_SRV, srv_rdata(18400, "host.local")))
        self.assertEqual(list(mdns.parse_records(packet)),
                         [("a._ipp._tcp.local", mdns.TYPE_SRV, (18400, "host.local"))])

    def test_compressed_record_owner_and_srv_target_decode(self):
        ptr_name_offset = 12
        packet = (header(ancount=2)
                  + record(mdns.encode_name("_ipp._tcp.local"), mdns.TYPE_PTR,
                           b"\x01a" + struct.pack(">H", 0xC000 | ptr_name_offset)))
        instance_offset = len(packet) - 4
        packet += record(struct.pack(">H", 0xC000 | instance_offset), mdns.TYPE_SRV,
                         srv_rdata(18400, "host.local"))
        self.assertEqual(list(mdns.parse_records(packet)),
                         [("_ipp._tcp.local", mdns.TYPE_PTR, "a._ipp._tcp.local"),
                          ("a._ipp._tcp.local", mdns.TYPE_SRV, (18400, "host.local"))])

    def test_truncated_reply_raises_a_type_query_swallows(self):
        name = mdns.encode_name("a._ipp._tcp.local")
        packet = header(ancount=1) + name + struct.pack(">HHIH", mdns.TYPE_TXT, mdns.CLASS_IN, 120, 40)
        with self.assertRaises((IndexError, struct.error)):
            list(mdns.parse_records(packet))


class FakeSocket:
    """Answers each query with the packets responder(name, qtype) returns."""

    def __init__(self, responder):
        self.responder = responder
        self.sent = []
        self.pending = []

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False

    def settimeout(self, _seconds):
        pass

    def sendto(self, data, address):
        name, offset = mdns.decode_name(data, 12)
        qtype, _qclass = struct.unpack(">HH", data[offset:offset + 4])
        self.sent.append((name, qtype, address))
        self.pending.extend(self.responder(name, qtype))

    def recvfrom(self, _size):
        if not self.pending:
            raise socket.timeout
        return self.pending.pop(0), ("192.0.2.1", mdns.MDNS_PORT)


def reply(*records):
    return header(ancount=len(records)) + b"".join(records)


def ptr(service, instance):
    return record(mdns.encode_name(service), mdns.TYPE_PTR, mdns.encode_name(instance))


def srv(instance, port, target="host.local"):
    return record(mdns.encode_name(instance), mdns.TYPE_SRV, srv_rdata(port, target))


def txt(instance, *strings):
    return record(mdns.encode_name(instance), mdns.TYPE_TXT, txt_rdata(*strings))


class QueryTests(unittest.TestCase):
    def test_sends_one_multicast_question_for_the_name_and_type(self):
        sock = FakeSocket(lambda _name, _qtype: [])
        self.assertEqual(mdns.query(sock, "_ipp._tcp.local", mdns.TYPE_PTR, 0.1), [])
        self.assertEqual(sock.sent, [("_ipp._tcp.local", mdns.TYPE_PTR,
                                      (mdns.MDNS_GROUP, mdns.MDNS_PORT))])

    def test_a_malformed_reply_is_dropped_and_later_replies_still_count(self):
        truncated = header(ancount=1) + mdns.encode_name("x._ipp._tcp.local")
        looping = header(ancount=1) + struct.pack(">H", 0xC000 | 12)
        good = reply(ptr("_ipp._tcp.local", "a._ipp._tcp.local"))
        sock = FakeSocket(lambda _name, _qtype: [truncated, looping, good])
        self.assertEqual(mdns.query(sock, "_ipp._tcp.local", mdns.TYPE_PTR, 0.1),
                         [("_ipp._tcp.local", mdns.TYPE_PTR, "a._ipp._tcp.local")])


class MainTests(unittest.TestCase):
    def browse(self, responder, *args):
        sock = FakeSocket(responder)
        out = io.StringIO()
        with mock.patch.object(mdns, "open_socket", return_value=sock), \
                mock.patch("sys.argv", ["mdns-browse.py", *args]), \
                contextlib.redirect_stdout(out):
            mdns.main()
        return [json.loads(line) for line in out.getvalue().splitlines()], sock

    def test_usage_is_printed_without_a_service_type(self):
        with mock.patch("sys.argv", ["mdns-browse.py"]):
            with self.assertRaises(SystemExit) as raised:
                mdns.main()
        self.assertEqual(raised.exception.code, mdns.__doc__)

    def test_instances_resolve_from_the_browse_reply_or_an_any_query(self):
        service = "_ipp._tcp.local"
        a, b = "Printer A._ipp._tcp.local", "Printer B._ipp._tcp.local"

        def responder(name, qtype):
            if qtype == mdns.TYPE_PTR:
                return [reply(ptr("_IPP._tcp.local", a), ptr(service, b),
                              ptr("_ipps._tcp.local", "Other._ipps._tcp.local"),
                              srv(a, 18400), txt(a, "rp=ipp/print/a", "ty=A"))]
            if qtype == mdns.TYPE_ANY and name == b:
                return [reply(srv(b, 18401, "other.local"), txt(b, "rp=ipp/print/b"))]
            return []

        records, sock = self.browse(responder, "_ipp._tcp.", "0.1")
        self.assertEqual(records, [
            {"name": "Printer A", "type": "_ipp._tcp", "port": 18400,
             "target": "host.local", "txt": ["rp=ipp/print/a", "ty=A"]},
            {"name": "Printer B", "type": "_ipp._tcp", "port": 18401,
             "target": "other.local", "txt": ["rp=ipp/print/b"]},
        ])
        self.assertEqual([q[:2] for q in sock.sent],
                         [(service, mdns.TYPE_PTR)] * mdns.QUERY_ROUNDS + [(b, mdns.TYPE_ANY)])

    def test_every_conflicting_srv_and_txt_is_reported_not_just_the_first(self):
        a = "a._ipp._tcp.local"

        def responder(_name, qtype):
            if qtype != mdns.TYPE_PTR:
                return []
            return [reply(ptr("_ipp._tcp.local", a), srv(a, 18400), txt(a, "rp=ipp/print/a")),
                    reply(srv(a, 18401), txt(a, "rp=ipp/print/b"))]

        records, _sock = self.browse(responder, "_ipp._tcp", "0.1")
        self.assertEqual(sorted((r["port"], tuple(r["txt"])) for r in records),
                         [(18400, ("rp=ipp/print/a",)), (18400, ("rp=ipp/print/b",)),
                          (18401, ("rp=ipp/print/a",)), (18401, ("rp=ipp/print/b",))])

    def test_an_instance_that_never_resolves_is_still_printed(self):
        a = "a._ipp._tcp.local"

        def responder(_name, qtype):
            return [reply(ptr("_ipp._tcp.local", a))] if qtype == mdns.TYPE_PTR else []

        records, _sock = self.browse(responder, "_ipp._tcp", "0.1")
        self.assertEqual(records, [{"name": "a", "type": "_ipp._tcp", "port": None,
                                    "target": None, "txt": []}])


if __name__ == "__main__":
    unittest.main()

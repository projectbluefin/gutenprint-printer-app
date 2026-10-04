"""Unit coverage for the dependency-free mDNS resolver used by coexistence.sh.

tests/coexistence.sh decides whether two instances keep their DNS-SD
advertisements isolated purely from what mdns-browse.py prints, and
mdns-browse.query() swallows every parse error, so a decoding regression
silently removes records instead of failing. These cases drive the wire
decoders directly with hand-built packets: no socket, no image, no Avahi.
"""
import importlib.util
import signal
import struct
import unittest
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


if __name__ == "__main__":
    unittest.main()

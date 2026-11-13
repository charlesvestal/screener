#!/usr/bin/env python3
"""Reference fixture generator for Screener.

Drives the vendored iShareScreen reference (Reference/iShareScreen, pinned at
commit 9ab40d3a3151524f954cff9d6239d891197c1705) with fixed inputs and writes
known-answer JSON fixtures to ScreenerTests/Fixtures/*.json for the Swift
test suite to compare against.

Run with:
    cd Tools/fixtures && uv run --python 3.12 --with cryptography \
        --with pycryptodome --with numpy python make_fixtures.py

See Tools/fixtures/README.md for a field-by-field rundown of each fixture
file and provenance notes (which values came from direct reference calls
vs. replicated expressions).
"""
from __future__ import annotations

import hashlib
import importlib
import json
import struct
import sys
import time as time_mod
import uuid as uuid_mod
import zlib
from pathlib import Path

# ── Step 1: import strategy ────────────────────────────────────────────
HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
REF_SRC = REPO_ROOT / "Reference" / "iShareScreen" / "src"
if not REF_SRC.is_dir():
    sys.exit(f"reference source not found at {REF_SRC} (submodule not checked out?)")
sys.path.insert(0, str(REF_SRC))

from isharescreen.proxy.protocol import (  # noqa: E402
    apple,
    auth,
    clipboard,
    enc1103,
    negotiation,
    offers,
    rfb,
    rtcp,
    srtp,
)
from isharescreen.proxy import input as input_mod  # noqa: E402
from isharescreen.proxy.media import nalu  # noqa: E402

OUT_DIR = REPO_ROOT / "ScreenerTests" / "Fixtures"
OUT_DIR.mkdir(parents=True, exist_ok=True)


def h(data: bytes) -> str:
    return data.hex()


def write_json(name: str, obj) -> None:
    path = OUT_DIR / f"{name}.json"
    # sort_keys + fixed separators -> byte-identical across runs.
    text = json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    path.write_text(text)
    print(f"wrote {path.relative_to(REPO_ROOT)} ({len(text)} bytes)")


class MonkeyPatch:
    """Tiny context-manager-free monkeypatch helper; call .undo() when done."""

    def __init__(self):
        self._restores = []

    def set(self, obj, name, value):
        self._restores.append((obj, name, getattr(obj, name)))
        setattr(obj, name, value)

    def undo(self):
        for obj, name, value in reversed(self._restores):
            setattr(obj, name, value)
        self._restores.clear()


# ════════════════════════════════════════════════════════════════════
# record_layer.json — enc1103.StreamCipher
# ════════════════════════════════════════════════════════════════════

def build_record_layer_fixture():
    ecb_key = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    # 36-byte 1103 blob: 4 bytes prefix (unused by StreamCipher) + 16 bytes
    # ECB ciphertext (-> cbc_key) + 16 bytes ECB ciphertext (-> cbc_iv).
    key_blob_36 = (
        bytes.fromhex("deadbeef")
        + bytes.fromhex("11" * 16)
        + bytes.fromhex("22" * 16)
    )
    assert len(key_blob_36) == 36

    cipher = enc1103.StreamCipher(key_blob_36, ecb_key=ecb_key)
    cbc_key = cipher.cbc_key

    plaintexts = [
        rfb.build_virtual_display(width=1376, height=1032),
        rfb.build_set_encodings(),
        negotiation.build_fbu_request(incremental=False),
    ]
    assert plaintexts[0][0] == 0x1D and plaintexts[0][1] == 0x00
    assert plaintexts[1][0] == 0x02 and plaintexts[1][1] == 0x00
    assert plaintexts[2][0] == 0x03 and plaintexts[2][1] == 0x00

    client_records = []
    for pt in plaintexts:
        wire = cipher.encrypt_message(pt)
        client_records.append({"plaintext": h(pt), "wire": h(wire)})

    return {
        "_provenance": (
            "ecb_key and key_blob_36 are fixed test inputs (not reference "
            "output); cbc_key is read from enc1103.StreamCipher.cbc_key "
            "after construction; client_records come from 3 consecutive "
            "enc1103.StreamCipher.encrypt_message() calls on the plaintexts "
            "produced by rfb.build_virtual_display/build_set_encodings and "
            "negotiation.build_fbu_request (chosen so the bodies start with "
            "0x1d00/0x0200/0x0300 as called out in the plan)."
        ),
        "args": {
            "ecb_key": h(ecb_key),
            "key_blob_36": h(key_blob_36),
            "virtual_display_args": {"width": 1376, "height": 1032},
        },
        "ecb_key": h(ecb_key),
        "key_blob_36": h(key_blob_36),
        "cbc_key": h(cbc_key),
        "client_records": client_records,
    }


# ════════════════════════════════════════════════════════════════════
# srp.json — auth._derive_x / auth._solve_srp / auth._parse_apple_srp_challenge
# ════════════════════════════════════════════════════════════════════

# RFC 5054 Appendix A.5 / RFC 3526 group 16: the well-known 4096-bit MODP
# safe prime. Fetched verbatim from https://www.rfc-editor.org/rfc/rfc5054.txt
# Appendix A, section 5.
_N_4096_HEX = (
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08"
    "8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B"
    "302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9"
    "A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6"
    "49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8"
    "FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D"
    "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C"
    "180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"
    "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D"
    "04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7D"
    "B3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D226"
    "1AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C"
    "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFC"
    "E0FD108E4B82D120A9210801 1A723C12A787E6D788719A10BDBA5B26"
    "99C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB"
    "04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2"
    "233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127"
    "D5B05AA993B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199"
    "FFFFFFFFFFFFFFFF"
).replace(" ", "")
_N_4096 = int(_N_4096_HEX, 16)
_G = 5


def build_srp_fixture():
    N = _N_4096
    Nb = N.to_bytes(512, "big")
    g = _G
    g_padded = g.to_bytes(512, "big")

    salt = hashlib.sha256(b"screener-fixture-salt").digest()  # 32 bytes, fixed
    iterations = 1000
    password = "test-password"

    # 64 bytes of "entropy" _solve_srp draws via os.urandom(64) for its
    # ephemeral `a`. Monkeypatch os.urandom (as seen from the auth module)
    # to return this fixed value regardless of requested length, so both
    # `a` (via _solve_srp) and `civ` (via _send_srp_proof, unused here) are
    # deterministic. Note: the plan says "if _solve_srp draws a from
    # secrets, monkeypatch that source" -- the actual reference draws it
    # from os.urandom, not the secrets module; adapted accordingly (see
    # README deviations).
    a_entropy = hashlib.sha512(b"screener-fixture-a-entropy").digest()
    assert len(a_entropy) == 64

    patch = MonkeyPatch()
    patch.set(auth.os, "urandom", lambda n: a_entropy[:n])
    try:
        # x: direct reference call.
        x = auth._derive_x(salt, iterations, password) % N

        # Server-side math (the one reference-free re-implementation the
        # plan allows, since the reference has no server). Mirrors the
        # exact expressions inside auth._solve_srp for k and S.
        b = int.from_bytes(bytes.fromhex("0b" * 64), "big") % (N - 1) + 1
        v = pow(g, x, N)
        k = int.from_bytes(hashlib.sha512(Nb + g_padded).digest(), "big")
        B = (k * v + pow(g, b, N)) % N
        Bb = B.to_bytes(512, "big")

        cap = b"mda=SHA-512,replay_detection,confidentiality,integrity"

        # Build challenge_wire per RFC Sec 4.2.4.4 / auth._parse_apple_srp_challenge
        # layout. The 12-byte TLV header's content is unvalidated by the
        # parser (it only checks byte[12] == 0x00), so we use a fixed,
        # documented placeholder.
        header12 = bytes.fromhex("00" * 12)
        challenge_wire = (
            header12
            + b"\x00"  # DER positive-int marker
            + Nb
            + struct.pack(">H", 1) + bytes([g])
            + bytes([len(salt)]) + salt
            + struct.pack(">H", len(Bb)) + Bb
            + struct.pack(">Q", iterations)
            + struct.pack(">H", len(cap)) + cap
        )

        challenge = auth._parse_apple_srp_challenge(challenge_wire)
        proof = auth._solve_srp(challenge, password)

        # u, S: _solve_srp doesn't return these intermediates. Recomputed
        # here with the exact same expressions used inside _solve_srp,
        # from inputs we already have in hand (challenge.Bb, proof.Ab,
        # the fixed `a` derived from the same monkeypatched entropy). See
        # README for why this is the allowed second re-implementation.
        a = int.from_bytes(a_entropy, "big") % (N - 1) + 1
        u = int.from_bytes(hashlib.sha512(proof.Ab + challenge.Bb).digest(), "big")
        S = pow((B - k * pow(g, x, N)) % N, a + u * x, N)
        K_check = hashlib.sha512(S.to_bytes(512, "big")).digest()
        assert K_check == proof.K, "replicated S does not match reference K"

        # M2: not computed anywhere in the reference (do_srp_auth never
        # verifies it -- see auth.py's _read_srp_result comment). Computed
        # here per the RFC doc's own stated formula
        # (docs/apple_vnc_rfc.md Sec 7: "M2 = H(PAD(A) || M1 || K)").
        M2 = hashlib.sha512(proof.Ab + proof.M1 + proof.K).digest()

        wrap_key = hashlib.sha256(proof.K).digest()[:16]
    finally:
        patch.undo()

    return {
        "_provenance": (
            "x comes from auth._derive_x(). A, M1, K come from "
            "auth._solve_srp() with os.urandom monkeypatched to a_entropy. "
            "B is computed server-side in this script (the one "
            "reference-free computation the plan explicitly allows, since "
            "the reference has no server role). u and S are not returned "
            "by _solve_srp, so they are recomputed here with the identical "
            "expressions found in auth.py, then cross-checked against K. "
            "M2 is not produced anywhere in the reference; computed per "
            "the RFC doc's stated M2 formula. wrap_key reapplies the "
            "one-line SHA-256 truncation auth.do_srp_auth performs on "
            "proof.K (do_srp_auth itself needs a live socket so cannot be "
            "called directly)."
        ),
        "group": {"N": _N_4096_HEX, "g": _G, "n_bits": N.bit_length()},
        "args": {
            "salt": h(salt),
            "iterations": iterations,
            "password": password,
            "a_entropy_64B": h(a_entropy),
            "b_server_secret": format(b, "x"),
        },
        "challenge_wire": h(challenge_wire),
        "parsed_challenge": {
            "N": h(challenge.Nb),
            "g": challenge.g,
            "salt": h(challenge.salt),
            "B": h(challenge.Bb),
            "iterations": challenge.iterations,
            "cap": challenge.cap.decode("latin-1"),
        },
        "x": format(x, "x"),
        "A": h(proof.Ab),
        "B": h(Bb),
        "u": format(u, "x"),
        "S": format(S, "x"),
        "K": h(proof.K),
        "M1": h(proof.M1),
        "M2": h(M2),
        "wrap_key": h(wrap_key),
    }


# ════════════════════════════════════════════════════════════════════
# srtp.json — srtp.py
# ════════════════════════════════════════════════════════════════════

def build_srtp_fixture():
    blob = hashlib.sha512(b"screener-srtp-fixture-blob").digest()[:46]
    assert len(blob) == srtp.SRTP_KEY_BLOB_LEN

    ssrc = 0x11223344
    pt = 100

    enc = srtp.SRTPEncryptor.from_blob(blob, ssrc)
    cipher_key = enc._cipher_key
    auth_key = enc._auth_key
    salt = enc._salt

    enc._seq = 65534  # drive the wraparound sequence the plan asks for
    plaintexts = [
        b"hevc-rtp-fixture-payload-0",
        b"hevc-rtp-fixture-payload-1",
        b"hevc-rtp-fixture-payload-2",
    ]
    packets = []
    for pt_bytes in plaintexts:
        seq_before = enc._seq & 0xFFFF
        wire = enc.encrypt(pt_bytes, pt=pt)
        packets.append({
            "seq": seq_before,
            "plaintext": h(pt_bytes),
            "wire": h(wire),
        })

    rtcp_pkt = rtcp.build_fir(1, ssrc, 7)
    srtcp_enc = srtp.SRTCPEncryptor.from_blob(blob)
    srtcp_wire = srtcp_enc.protect(rtcp_pkt)

    return {
        "_provenance": (
            "blob is a fixed 46-byte test input. cipher_key/auth_key/salt "
            "are read off SRTPEncryptor.from_blob()'s private attributes, "
            "which are produced by srtp._srtp_kdf() (labels 0/1/2) inside "
            "the constructor -- not re-derived in this script. The 3 "
            "packets come from SRTPEncryptor.encrypt() with the internal "
            "_seq counter primed to 65534 before the first call so the "
            "natural wraparound produces seqs 65534, 65535, 0. The SRTCP "
            "sample wraps rtcp.build_fir(1, ssrc, 7) with "
            "SRTCPEncryptor.protect()."
        ),
        "args": {
            "blob": h(blob),
            "ssrc": ssrc,
            "pt": pt,
            "plaintexts": [h(p) for p in plaintexts],
            "rtcp_pkt_for_srtcp_sample": h(rtcp_pkt),
        },
        "blob": h(blob),
        "cipher_key": h(cipher_key),
        "auth_key": h(auth_key),
        "salt": h(salt),
        "packets": packets,
        "srtcp_sample": {
            "ssrc": ssrc,
            "plaintext_rtcp": h(rtcp_pkt),
            "wire": h(srtcp_wire),
        },
    }


# ════════════════════════════════════════════════════════════════════
# messages.json — rfb.py, negotiation.py, input.py, apple.py
# ════════════════════════════════════════════════════════════════════

def build_display_layout_payload():
    """Synthesize a 0x451 AppleDisplayLayout body: 1 display, 1920x1080
    scaled / 3840x2160 backing, per RFC Sec 8.4 / rfb.parse_apple_display_layout."""
    header = (
        struct.pack(">H", 1)             # ver
        + struct.pack(">HHHH", 1920, 1080, 3840, 2160)  # sw, sh, bw, bh
        + b"\xff\xff\xff\xff"             # fixed marker
        + struct.pack(">I", 0)            # field
        + struct.pack(">H", 1)            # display_count
    )
    assert len(header) == 20
    entry = (
        struct.pack(">d", 2.0)            # hscale
        + struct.pack(">d", 2.0)          # vscale
        + struct.pack(">I", 1)            # display_id
        + struct.pack(">HHHH", 0, 0, 1080, 1920)  # virtual(point) rect y0,x0,y1,x1
        + struct.pack(">HHHH", 0, 0, 2160, 3840)  # pixel(backing) rect y0,x0,y1,x1
        + bytes(20)                       # trailing, ignored
    )
    assert len(entry) == 56
    return header + entry


def build_messages_fixture():
    out = {}

    out["build_set_encodings"] = {
        "args": {},
        "result": h(rfb.build_set_encodings()),
    }
    out["build_post_encryption_toggle"] = {
        "args": {},
        "result": h(rfb.build_post_encryption_toggle()),
    }
    out["build_key_event"] = {
        "args": {"down": True, "keysym": 0x61},
        "result": h(rfb.build_key_event(down=True, keysym=0x61)),
    }
    out["build_pointer_event"] = {
        "args": {"buttons": 1, "x": 100, "y": 200},
        "result": h(rfb.build_pointer_event(buttons=1, x=100, y=200)),
    }
    out["build_viewer_info"] = {
        "args": {"command_mask": h(apple.APPLE_VIEWER_COMMAND_MASK)},
        "result": h(rfb.build_viewer_info(command_mask=apple.APPLE_VIEWER_COMMAND_MASK)),
    }
    out["build_virtual_display"] = {
        "args": {"width": 1376, "height": 1032, "hidpi_scale": 2.0},
        "note": (
            "width/height are the function's LOGICAL (point) target per "
            "its own docstring; with the default hidpi_scale=2.0 the mode "
            "table advertises a 2752x2064 backing pixel size."
        ),
        "result": h(rfb.build_virtual_display(width=1376, height=1032)),
    }
    out["build_fbu_request"] = {
        "args": {"incremental": False},
        "result": h(negotiation.build_fbu_request(incremental=False)),
    }
    out["build_auto_framebuffer_update"] = {
        "args": {"width": 2752, "height": 2064},
        "result": h(negotiation.build_auto_framebuffer_update(2752, 2064)),
    }
    fixed_ecb_key = bytes.fromhex("aa" * 16)
    out["_build_msg10_pointer"] = {
        "args": {"cbc_key": h(fixed_ecb_key), "buttons": 1, "x": 100, "y": 200},
        "source": "proxy/input.py (not proxy/protocol/input.py; see README deviations)",
        "result": h(input_mod._build_msg10_pointer(fixed_ecb_key, 1, 100, 200)),
    }
    out["_build_apple_viewer_command_mask"] = {
        "args": {},
        "result": h(apple._build_apple_viewer_command_mask()),
    }

    layout_payload = build_display_layout_payload()
    parsed = rfb.parse_apple_display_layout(layout_payload)
    bw, bh, rects = parsed
    out["parse_apple_display_layout"] = {
        "args": {
            "payload": h(layout_payload),
            "note": "synthesized per RFC Sec 8.4: 1 display, 1920x1080 scaled / 3840x2160 backing",
        },
        "result": {
            "backing_w": bw,
            "backing_h": bh,
            "displays": [
                {"display_id": r.display_id, "x": r.x, "y": r.y, "w": r.w, "h": r.h}
                for r in rects
            ],
        },
    }
    return out


# ════════════════════════════════════════════════════════════════════
# media_offer.json — offers.py, negotiation.py
# ════════════════════════════════════════════════════════════════════

def build_media_offer_fixture():
    fixed_session_id = 0x12345678
    fixed_timestamp = 1700000000000000000
    fixed_uuid = uuid_mod.UUID("00000000-0000-0000-0000-000000000001")

    patch = MonkeyPatch()
    patch.set(offers.secrets, "randbits", lambda n: fixed_session_id)
    patch.set(offers.time, "time_ns", lambda: fixed_timestamp)
    patch.set(offers.uuid, "uuid4", lambda: fixed_uuid)
    patch.set(negotiation.uuid, "uuid4", lambda: fixed_uuid)
    try:
        video_offer, audio_offer = offers.create_offers(audio_enabled=True)

        def fixed_blob(label: str) -> bytes:
            return hashlib.sha512(label.encode()).digest()[:46]

        keys = negotiation.NegotiationKeys(
            audio_key_v=fixed_blob("akv"),
            audio_key_s=fixed_blob("aks"),
            video_key_v=fixed_blob("vkv"),
            video_key_s=fixed_blob("vks"),
        )
        msg_1c = negotiation.build_0x1c(audio_offer, video_offer, keys, alt_session=False)
    finally:
        patch.undo()

    # Synthesized 0x1c answer carrying canvas dims, for extract_canvas_dims.
    cw, ch, ct = 3840, 2160, 4
    sub = offers._field_varint(4, cw) + offers._field_varint(5, ch) + offers._field_varint(6, ct)
    answer_blob = offers._field_bytes(5, sub)
    import plistlib
    answer_plist = plistlib.dumps(
        {"avcMediaStreamNegotiatorMediaBlob": zlib.compress(answer_blob)},
        fmt=plistlib.FMT_BINARY,
    )
    answer_msg = b"\x00" + answer_plist
    extracted = offers.extract_canvas_dims(answer_msg)
    assert extracted == (cw, ch, ct), extracted

    return {
        "_provenance": (
            "video_offer/audio_offer come from offers.create_offers() with "
            "offers.secrets.randbits, offers.time.time_ns and "
            "offers.uuid.uuid4 monkeypatched to fixed values. msg_1c comes "
            "from negotiation.build_0x1c() with fixed NegotiationKeys and "
            "negotiation.uuid.uuid4 (same global uuid module) also "
            "monkeypatched. The 0x1c answer fed to extract_canvas_dims is "
            "synthesized (per plan) using offers' own private protobuf "
            "helpers (_field_varint/_field_bytes) to build the input only "
            "-- extract_canvas_dims itself is the real reference function "
            "under test and is called unmodified."
        ),
        "args": {
            "audio_enabled": True,
            "fixed_session_id": fixed_session_id,
            "fixed_timestamp_ns": fixed_timestamp,
            "fixed_call_id_uuid": str(fixed_uuid),
            "keys": {
                "audio_key_v": h(keys.audio_key_v),
                "audio_key_s": h(keys.audio_key_s),
                "video_key_v": h(keys.video_key_v),
                "video_key_s": h(keys.video_key_s),
            },
            "answer_canvas": {"cw": cw, "ch": ch, "ct": ct},
        },
        "video_offer": h(video_offer),
        "audio_offer": h(audio_offer),
        "msg_1c": h(msg_1c),
        "answer_msg": h(answer_msg),
        "extract_canvas_dims_result": {"cw": extracted[0], "ch": extracted[1], "ct": extracted[2]},
    }


# ════════════════════════════════════════════════════════════════════
# clipboard.json — clipboard.py
# ════════════════════════════════════════════════════════════════════

def build_clipboard_fixture():
    text = "héllo 👋"
    send_wire = clipboard.build_clipboard_send(text)
    auto_wire = clipboard.build_auto_pasteboard_msg()
    req_wire = clipboard.build_clipboard_request()

    header = clipboard.parse_clipboard_send_header(send_wire)
    promise, reserved, uncompressed, compressed_len = header
    compressed_payload = send_wire[16:16 + compressed_len]
    decompressed = clipboard.decompress_clipboard_payload(compressed_payload)
    items = clipboard.parse_clipboard_items(decompressed)

    return {
        "_provenance": (
            "All byte strings come directly from clipboard.build_* "
            "functions. The round-trip calls "
            "clipboard.parse_clipboard_send_header, "
            "clipboard.decompress_clipboard_payload and "
            "clipboard.parse_clipboard_items on the output of "
            "build_clipboard_send() for the same text."
        ),
        "args": {"text": text},
        "build_clipboard_send": h(send_wire),
        "build_auto_pasteboard_msg": h(auto_wire),
        "build_clipboard_request": h(req_wire),
        "roundtrip": {
            "header": {
                "promise": promise,
                "reserved": reserved,
                "uncompressed_size": uncompressed,
                "compressed_size": compressed_len,
            },
            "decompressed": h(decompressed),
            "items": [
                {
                    "primary_uti": it.primary_uti,
                    "primary_data": h(it.primary_data),
                    "aliases": [[name, h(val)] for name, val in it.aliases],
                }
                for it in items
            ],
        },
    }


# ════════════════════════════════════════════════════════════════════
# rtcp.json — rtcp.py
# ════════════════════════════════════════════════════════════════════

def build_rtcp_fixture():
    return {
        "_provenance": "All byte strings come directly from rtcp.build_* functions.",
        "build_fir_legacy": {
            "args": {"target_ssrc": "0x11223344"},
            "result": h(rtcp.build_fir_legacy(0x11223344)),
        },
        "build_fir": {
            "args": {"sender_ssrc": 1, "target_ssrc": "0x11223344", "seq_nr": 7},
            "result": h(rtcp.build_fir(1, 0x11223344, 7)),
        },
        "build_pli": {
            "args": {"sender_ssrc": 1, "media_ssrc": "0x11223344"},
            "result": h(rtcp.build_pli(1, 0x11223344)),
        },
        "build_nack": {
            "args": {"sender_ssrc": 1, "media_ssrc": "0x11223344", "lost_seqs": [10, 11, 13]},
            "result": h(rtcp.build_nack(1, 0x11223344, [10, 11, 13])),
        },
        "build_rr": {
            "args": {
                "sender_ssrc": 1,
                "source_ssrcs": ["0x11223344"],
                "ssrc_stats": {"0x11223344": {"max_seq": 100, "roc": 2}},
                "note": "sr_data omitted to keep the result independent of time.time()",
            },
            "result": h(rtcp.build_rr(
                1, [0x11223344], {0x11223344: {"max_seq": 100, "roc": 2}},
            )),
        },
        "build_rtcp_app_ltrp": {
            "args": {"sender_ssrc": 1, "ltr_id": 5},
            "result": h(rtcp.build_rtcp_app_ltrp(1, 5)),
        },
    }


# ════════════════════════════════════════════════════════════════════
# hevc_rtp.json — synthesized per RFC Sec 10.6, cross-checked against
# the real (and, contrary to the plan's assumption, callable-in-isolation)
# media/nalu.py reassemble_group()/first_donl().
# ════════════════════════════════════════════════════════════════════

def nal_header(nal_type: int, layer_tid_byte: int = 0x01) -> bytes:
    return bytes([(nal_type << 1) & 0xFE, layer_tid_byte])


def build_hevc_rtp_fixture():
    out = {"_provenance": (
        "RTP payloads are hand-built per RFC Sec 10.6. Despite the plan's "
        "note that the depacketizer lives inside session.py/hevc.py and "
        "isn't callable in isolation, the actual NAL-reassembly logic is "
        "in isharescreen.proxy.media.nalu (reassemble_group/first_donl), "
        "which imports only stdlib and *is* callable standalone -- so the "
        "expected de-DONL'd NAL units here are the real output of that "
        "reference function, not hand-computed (see README deviations)."
    )}

    # 1. Single NAL (type 1) with DONL.
    single_header = nal_header(1)
    single_donl = struct.pack(">H", 0x0007)
    single_payload = b"\xaa\xbb\xcc\xdd"
    single_pkt = single_header + single_donl + single_payload
    single_expected = nalu.reassemble_group([single_pkt])
    out["single_nal"] = {
        "args": {"nal_type": 1, "donl": 0x0007, "payload": h(single_payload)},
        "rtp_payload": h(single_pkt),
        "expected_nalus": [h(n) for n in single_expected],
    }

    # 2. Aggregation Packet (type 48) carrying VPS/SPS/PPS.
    vps_nal = nal_header(32) + b"VPSDATA"
    sps_nal = nal_header(33) + b"SPSDATA"
    pps_nal = nal_header(34) + b"PPSDATA"
    ap_header = nal_header(48)
    ap_donl = struct.pack(">H", 0x002A)
    ap_body = b"".join(struct.pack(">H", len(n)) + n for n in (vps_nal, sps_nal, pps_nal))
    ap_pkt = ap_header + ap_donl + ap_body
    ap_expected = nalu.reassemble_group([ap_pkt])
    out["aggregation_packet"] = {
        "args": {"donl": 0x002A, "nals": {"vps": h(vps_nal), "sps": h(sps_nal), "pps": h(pps_nal)}},
        "rtp_payload": h(ap_pkt),
        "expected_nalus": [h(n) for n in ap_expected],
    }

    # 3. Fragmentation Unit (type 49) start/middle/end of one IDR slice (type 19).
    inner_type = 19
    fu_donl = struct.pack(">H", 0x0031)
    frag1, frag2, frag3 = b"IDRPARTONE", b"IDRPARTTWO", b"IDRPARTTHREE"

    def fu_packet(start: bool, end: bool, fragment: bytes) -> bytes:
        fu_hdr = (0x80 if start else 0x00) | (0x40 if end else 0x00) | inner_type
        return nal_header(49) + bytes([fu_hdr]) + fu_donl + fragment

    fu_start = fu_packet(True, False, frag1)
    fu_mid = fu_packet(False, False, frag2)
    fu_end = fu_packet(False, True, frag3)
    fu_expected = nalu.reassemble_group([fu_start, fu_mid, fu_end])
    out["fragmentation_unit"] = {
        "args": {
            "inner_nal_type": inner_type,
            "donl": 0x0031,
            "fragments": [h(frag1), h(frag2), h(frag3)],
        },
        "rtp_payloads": {"start": h(fu_start), "middle": h(fu_mid), "end": h(fu_end)},
        "expected_nalus": [h(n) for n in fu_expected],
    }

    for key, group in (
        ("single_nal", [single_pkt]),
        ("aggregation_packet", [ap_pkt]),
        ("fragmentation_unit", [fu_start, fu_mid, fu_end]),
    ):
        donl = nalu.first_donl(group)
        out[key]["first_donl"] = donl

    return out


# ════════════════════════════════════════════════════════════════════

def main() -> int:
    write_json("record_layer", build_record_layer_fixture())
    write_json("srp", build_srp_fixture())
    write_json("srtp", build_srtp_fixture())
    write_json("messages", build_messages_fixture())
    write_json("media_offer", build_media_offer_fixture())
    write_json("clipboard", build_clipboard_fixture())
    write_json("rtcp", build_rtcp_fixture())
    write_json("hevc_rtp", build_hevc_rtp_fixture())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

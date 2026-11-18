# Reference fixture generator

`make_fixtures.py` drives the vendored AGPL Python reference, **iShareScreen**
(`Reference/iShareScreen`, git submodule pinned at commit
`9ab40d3a3151524f954cff9d6239d891197c1705`), with fixed inputs and writes
known-answer JSON fixtures to `ScreenerTests/Fixtures/*.json`. Future Swift
unit tests load these fixtures and assert that the ported Swift
implementation produces byte-identical output.

## Run

```bash
cd Tools/fixtures
uv run --python 3.12 --with cryptography --with pycryptodome --with numpy python make_fixtures.py
```

Exits 0 and writes all 9 files to `../../ScreenerTests/Fixtures/`. Re-running
produces byte-identical files — verified with:

```bash
shasum ScreenerTests/Fixtures/*.json   # run before and after a second invocation, diff the output
```

All JSON is written with `sort_keys=True` and a fixed indent so output is
stable across runs; every source of randomness/time/uuid in the reference
code paths exercised here is either monkeypatched to a fixed value or
avoided (e.g. `rtcp.build_rr` is called without `sr_data` so it never
touches `time.time()`).

## Files and provenance

Every fixture file carries its own `"_provenance"` key (and often an
`"args"` sub-object recording exactly what was passed to each builder) so
the JSON is self-describing; this file summarizes the same information.

- **`record_layer.json`** — `enc1103.StreamCipher`. `ecb_key` and
  `key_blob_36` are fixed test inputs; `cbc_key` is read off
  `StreamCipher.cbc_key` after construction (derived internally by AES-ECB
  decrypting slices of `key_blob_36`, not recomputed here). `client_records`
  are 3 consecutive `encrypt_message()` calls on one cipher instance, with
  plaintexts taken from `rfb.build_virtual_display()`,
  `rfb.build_set_encodings()` and `negotiation.build_fbu_request()` — chosen
  because their first two bytes are `1d00`/`0200`/`0300` as called out in
  the plan.

- **`srp.json`** — `auth._derive_x`, `auth._solve_srp`,
  `auth._parse_apple_srp_challenge`. Includes the RFC 5054 Appendix A 4096-
  bit group's `N` (hex, fetched verbatim from
  `https://www.rfc-editor.org/rfc/rfc5054.txt` §Appendix A.5) and `g=5` so
  the fixture is self-contained. `x`, `A`, `M1`, `K` come directly from
  calling `auth._derive_x` / `auth._solve_srp` with `auth.os.urandom`
  monkeypatched to a fixed 64-byte value (see **Deviations** below for why
  `os.urandom`, not `secrets`). `B` is computed server-side in the script —
  the one reference-free re-implementation the plan explicitly allows,
  since the reference has no server role; it mirrors `_solve_srp`'s own `k`
  and modexp expressions exactly. `u` and `S` are **not** returned by
  `_solve_srp`, so they are recomputed here using the identical expressions
  found in `auth.py` from values already in hand (`challenge.Bb`,
  `proof.Ab`, the same fixed `a` derived from the monkeypatched entropy);
  the recomputed `S` is cross-checked against `proof.K` in the script
  (`SHA-512(S) == K`, asserted) before being written out. `M2` is **not**
  produced anywhere in the reference (`auth.py`'s `_read_srp_result` reads
  M2 off the wire but never computes or verifies it) — it is computed here
  per the RFC doc's own stated formula
  (`Reference/iShareScreen/docs/apple_vnc_rfc.md` §4.2.4.6: "M2 = H(PAD(A) || M1
  || K)"). `wrap_key` reapplies the one-line `SHA-256(K)[:16]` truncation
  that `auth.do_srp_auth`'s final line performs on `proof.K`; `do_srp_auth`
  itself needs a live socket so cannot be called directly, but the
  transform applied to its reference-derived `K` is copied verbatim.
  `challenge_wire` is built per the RFC §4.2.4.4 / `_parse_apple_srp_challenge`
  docstring layout; the 12-byte TLV header is a placeholder of zero bytes
  since the parser only checks that byte 12 is the DER zero marker and
  never validates the header bytes themselves.

- **`srtp.json`** — `srtp.py`. `blob` is a fixed 46-byte test input.
  `cipher_key`/`auth_key`/`salt` are read off `SRTPEncryptor.from_blob()`'s
  private attributes, which are populated by `srtp._srtp_kdf()` (labels
  0/1/2) inside the constructor — not re-derived in the script. The 3
  packets come from `SRTPEncryptor.encrypt()` with the encryptor's internal
  `_seq` counter primed to `65534` before the first call, so the class's
  own wraparound logic naturally produces seqs `65534, 65535, 0` (and bumps
  its ROC) across the three calls — no sequence-number math was
  reimplemented. The SRTCP sample wraps `rtcp.build_fir(1, ssrc, 7)` with
  `SRTCPEncryptor.protect()`.

- **`messages.json`** — `rfb.py`, `negotiation.py`, `proxy/input.py`,
  `apple.py`. Each entry records the exact `args` passed and the builder's
  raw output. `_build_msg10_pointer` lives in `proxy/input.py` (not
  `proxy/protocol/input.py` as the plan's file list implies — there is no
  `protocol/input.py` in this reference checkout; see **Deviations**).
  `parse_apple_display_layout` is exercised against a synthesized 0x451
  body (1 display, 1920×1080 scaled / 3840×2160 backing, per RFC §8.4) and
  the fixture records both the synthesized input and the real parsed
  output. `build_virtual_display_dynamic_resize` is the same builder as
  `session.send_dynamic_resolution` calls it for a mid-session resize
  (RFC §7.3 / §10.9), over three `args.cases` (portrait, a ×0.8 landscape
  size, a half-width window at scale 1.25); `result` is the list of outputs.

- **`media_offer.json`** — `offers.py`, `negotiation.py`. `video_offer`/
  `audio_offer` come from `offers.create_offers(audio_enabled=True)` with
  `offers.secrets.randbits`, `offers.time.time_ns` and `offers.uuid.uuid4`
  monkeypatched to fixed values. `msg_1c` comes from
  `negotiation.build_0x1c()` with a fixed `NegotiationKeys` (four distinct
  46-byte blobs derived from SHA-512 of fixed labels) and
  `negotiation.uuid.uuid4` (the same global `uuid` module object, so one
  monkeypatch covers both call sites) also fixed. The answer fed to
  `extract_canvas_dims` is synthesized per the plan (a `bplist` wrapping a
  protobuf blob with fields 4/5/6 = canvas width/height/tile-count), built
  using `offers`' own private protobuf helpers (`_field_varint`/
  `_field_bytes`) purely to construct the *input* bytes — `extract_canvas_dims`
  itself is the unmodified reference function under test, and its result is
  asserted against the chosen (3840, 2160, 4) before being written out.

  **Byte order note on `msg_1c`'s config/flags word (body +0x06):**
  `apple_vnc_rfc.md` §10.3 documents this `u32` as host/little-endian,
  i.e. a conforming client writes `07 00 00 00` for `config_flags = 7`.
  `negotiation.build_0x1c()` deliberately writes it **big-endian**
  (`00 00 00 07`) instead — its own comment explains why: the host loads
  the word at body+0x06 un-byteswapped and forwards it to the streaming
  agent across an IPC/NDR boundary that byte-swaps it again, so the
  *effective* byte order the agent's `do_not_send_cursor` (`& 4`) check
  sees is the inverse of the host's raw load; empirically, big-endian
  `00 00 00 07` is what makes the host honor `do_not_send_cursor`, while
  little-endian `07 00 00 00` leaves it clear and reintroduces the
  double-cursor regression the comment describes. `msg_1c` in this
  fixture therefore encodes the flags word big-endian, contradicting
  §10.3's stated byte order — this is intentional and verified-by-the-
  reference-author behavior, not a bug in the fixture. The ported Swift
  `MediaOffer.swift` MUST follow the fixture (big-endian) here, not the
  RFC doc's stated convention.

- **`clipboard.json`** — `clipboard.py`. All byte strings come directly
  from `build_clipboard_send("héllo 👋")`, `build_auto_pasteboard_msg()`,
  `build_clipboard_request()`. The round-trip calls
  `parse_clipboard_send_header`, `decompress_clipboard_payload` and
  `parse_clipboard_items` on the compressed payload sliced out of
  `build_clipboard_send`'s own output for the same text.

- **`rtcp.json`** — `rtcp.py`. All byte strings come directly from
  `build_fir_legacy`, `build_fir`, `build_pli`, `build_nack`, `build_rr`
  (without `sr_data`, so the result never depends on `time.time()`) and
  `build_rtcp_app_ltrp`, called with the fixed args recorded per entry.

- **`hevc_rtp.json`** — synthesized per RFC §10.6 (single NAL with DONL, an
  AP carrying VPS/SPS/PPS, and FU start/middle/end fragments of one IDR
  slice), as the plan allows. See **Deviations** for why the "expected
  de-DONL'd NAL units" are *not* hand-computed here but come from directly
  calling the real reference reassembler.

- **`input.json`** — `proxy/input.py` `InputController`. Each entry drives a
  real `InputController` (fixed 16-byte `cbc_key` = `00..0f`, server
  1920×1080) whose cipher is a capturing stand-in: InputController only reads
  `cipher.cbc_key` (for msg 0x10) and calls `cipher.encrypt_and_send(sock,
  payload)`, so the stand-in records each plaintext `payload` in order —
  exactly what the reference hands its record layer. Covers a left click
  (move/down/up), a right click, coordinate clamping, `set_server_dims`,
  `scroll_event` (dy=+2 → two bit4 press/release pairs; dy=-1 → one bit3
  pair; dx-only → nothing) and `key_event` (incl. keysym 0 → dropped).
  AES-ECB is deterministic, so the msg 0x10 bytes are stable.

## Deviations from the plan

- **`_build_msg10_pointer` lives in `proxy/input.py`, not
  `proxy/protocol/input.py`.** The plan's file table cites `input.py`
  without a path and groups it with the `protocol/*` sources in prose; in
  this checkout there is no `isharescreen/proxy/protocol/input.py` — the
  function lives in `isharescreen/proxy/input.py` (imported here as
  `input_mod` to avoid shadowing the `input` builtin). No functional change,
  just the correct import path.

- **The HEVC RTP depacketizer *is* callable in isolation.** The plan's step
  for `hevc_rtp.json` says "the reference parser for this lives inside
  `session.py`/`hevc.py` and is not callable in isolation, so cross-check
  the layout by reading those functions." In fact the NAL-reassembly logic
  — `reassemble_group()` and `first_donl()` — lives in a separate module,
  `isharescreen/proxy/media/nalu.py`, which imports only `struct` and
  `typing` (no `av`/`glfw`/`wgpu`). The script imports it directly and calls
  it on each synthesized RTP payload, so the `expected_nalus` values in
  `hevc_rtp.json` are the real reference function's output rather than a
  hand-computed cross-check. This is a stronger guarantee than the plan
  asked for, not a weaker one.

- **`_solve_srp` draws its ephemeral `a` from `os.urandom`, not
  `secrets`.** The plan's `srp.json` step says "if `_solve_srp` draws `a`
  from `secrets`, monkeypatch that source." Reading `auth.py`, `_solve_srp`
  actually does `a = int.from_bytes(os.urandom(64), "big") % (N - 1) + 1`.
  The script monkeypatches `auth.os.urandom` instead, to a fixed 64-byte
  value, which is the actual entropy source.

- **`M2` is not produced by any reference function.** `do_srp_auth` reads
  the server's M2 off the wire but, per its own docstring/comment in
  `auth.py`, never computes or verifies it — there is no `_compute_m2` or
  similar to call. The plan still lists `M2` as an expected fixture value,
  so the script computes it from the RFC doc's own stated SRP-6a formula
  (`apple_vnc_rfc.md` §4.2.4.6) using `proof.Ab`, `proof.M1`, `proof.K` — all of
  which *do* come from the reference `_solve_srp` call. This is a second
  allowed re-implementation beyond the plan's explicit "server-side `B`"
  exception, called out here for visibility.

- **`u` and `S` are recomputed, not returned by `_solve_srp`.** The
  reference's `_SrpProof` dataclass only carries `(A, Ab, M1, K)`; `u` and
  `S` are local variables inside `_solve_srp` that never leave the
  function. The script recomputes them with the exact same expressions
  used inside `auth.py` (same `k`, same `x` from `auth._derive_x`, same
  fixed `a`) and cross-checks the recomputed `S` against the real `K` via
  `SHA-512(S) == K` before writing the fixture, so a copy-paste error in
  the replicated expression would fail the generator rather than silently
  producing a wrong fixture.

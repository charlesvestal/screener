# Native Screen Sharing feedback vs Screener (2026-11-18)

Measured on the Mac mini host (192.0.2.54) while the user's laptop (192.0.2.121) used Apple's Screen Sharing.app in HP mode.

## Bitrate (nettop on avconferenced, the process that owns UDP 5900/5901)
- Video out while dragging a window: 33–53 Mbps. Static screen: ~2–5 Mbps.
- Client feedback into the video port: ~50–65 kbps.
- Screener measured earlier: ~17–19 Mbps, flat, with ~2 kbps of feedback.

## Packet headers (tcpdump, 96-byte snaplen, 11 s; SRTCP first 8 bytes are cleartext)
| Dir | Port | Type | Rate | UDP payload size |
|---|---|---|---|---|
| C→S | 5901 | RTCP APP PT=204, subtype 0 in the header | ~94/s | avg 33, min 30 (=16 B APP + SRTCP trailer, the iShareScreen LTR shape), max 46 (=32 B APP variant) |
| C→S | 5901 | RTCP RR PT=201 RC=1 | 1/s | 58 |
| C→S | 5900 | RTCP RR PT=201 RC=1 | 1/s | 58 |
| S→C | 5901 | RTP PT=100 video | — | 162–1379 |
| S→C | 5900 | RTP PT=101 audio | 100/s | 26 |
| S→C | 5900, 5901 | SR PT=200 | 1/s each | 78 |

## Screener today
- RR every 0.5 s to port P (5900) only. The video SSRCs are reported there too (reference behaviour).
- LTR ack APP subtype 5 only behind `SCREENER_LTR_ACK=1`, tile 0 only, ~50/s.
- No 32-byte APP variant.

## Hypotheses
1. The Mac's AVConference rate control needs per-frame APP feedback on the video port, and probably the 32-byte variant (a receiver bandwidth estimate?), to raise the target.
2. RRs for video must arrive on 5901.

## Findings (deeper capture analysis + AVConference RE, same day)

### Native feedback pattern, precisely
From `native-rtcp.pcap` (11 s, mostly static screen) and a second 19 s capture of the same native session with no video flowing:
- **One 30-byte APP per tile marker packet.** 821 APPs for 822 video RTP packets with M=1, across all four tile SSRCs (not tile 0 only), each 1–3 ms after that tile's marker (i.e. after the tile decodes). Body is 16 B: `80cc0003 <ssrc> <name> <id>`; AVConference's RTCP parser accepts APP name 5 with one u32 (the LTR ack the reference sends) and name 6 with a u32 + u16.
- **One 46-byte APP every 50 ms (20.0/s), independent of video.** It keeps coming at exactly 20/s when no video arrives at all. This is AVConference's receiver rate-control feedback: APP name `RCTL` (0x5243544C) + a 20-byte VCMediaControlInfo blob (see below).
- **RR on each port, 1/s, 58 bytes**: `81c90007` (RR, one report block) + 12 more bytes (SDES per the RFC notes). Port 5900 uses a second client SSRC (the audio one) and its own SRTCP index; port 5901 uses the video SSRC and shares the SRTCP index with the APPs (index +1 per packet, E=1, so bodies are encrypted).
- **Legacy FIR (PT 192) every 5 s while no video arrives**, from the client's video SSRC.
- Client SSRCs differ per port (5900 audio SSRC, 5901 video SSRC). The video RTP header extension (profile 0x9311, 1 word) is `u16 packets-in-this-tile-frame, u16 frame counter`; it carries no sender timestamp.

### RCTL layout (AVConference, macOS 27 build)
`-[VCVideoStreamRateAdaptationFeedbackOnly sendRateControlFeedback]` fills a VCMediaControlInfo (type 2, flags `02 01 01 01 00 00`), `VCMediaControlInfoSerializeWithData` packs it into 20 bytes, `RTPSendRateControlPacket` → `RTPSendRTCP` (flag 0x20) → `_RTCPAddCustomReportPacket` emits APP name `RCTL`:
```
80cc0007 <video ssrc> 5243544c
85 XX 0004  echo(u16)  0000 0000  echoDelayMs(u16)  now(u16, 1/1024 s)  owrd(u16)  burstyLoss<<12|loss(u16)  BWE(u16)
```
Screener sends: XX = 0, echo = low 16 bits of the newest video RTP timestamp, echoDelayMs = ms since that packet arrived, owrd = 0, loss = 0, BWE = 60000.

**BWE is the host's encoder target, in kbps**: with BWE = 60000 the host's video send rate sits flat at 60–61 Mbps while dragging; without RCTL it sits flat at ~20 Mbps.

### A/B (live, simulator on this Mac, 192.0.2.33 → .54; same motion source: a 60%-of-screen textured window sliding on a 4 s period for 26 s)
Host→Screener video rate from a host-side packet capture (UDP to .33:5901, IP+UDP+payload), during the motion window; app columns from Screener's own log. The user's laptop stayed connected as a second viewer throughout (it received 10–26 Mbps of its own stream during most runs).

| Variant | Host → Screener during drag | App payload kbps / fps |
|---|---|---|
| Baseline (reference feedback) | flat ~20 Mbps | 19–27 Mbps / 40–52 fps |
| SCREENER_FB_RR=1 (RRs per port) | flat ~20–21 Mbps | 5–20 Mbps / 18–60 fps (startup stall, 48 FIRs) |
| RCTL only (BWE 60000) | 41–49 Mbps | ~40 Mbps / ~39 fps |
| RCTL + per-tile acks | 35–57 Mbps, but decode stalls (fps 1.5–18), 57 FIRs | 12–37 Mbps |
| RCTL + RRs per port | 60–61 Mbps flat | ~60 fps |
| all three | 21–34 Mbps (stalls at start) | 25–30 Mbps |
| **New default (RCTL on, nothing else)** | **60–61 Mbps flat** | **55–60 Mbps / ~60 fps** |

### Decision
- RCTL ON by default (`SCREENER_FB_RCTL=0` turns it off, `SCREENER_RCTL_BWE=<kbps>` pins the estimate, `0` = measured receive rate; adaptive otherwise, see below).
- Per-port RRs (`SCREENER_FB_RR=1`) and per-tile acks (`SCREENER_FB_ACKALL=1`) stay opt-in: neither raised the bitrate on its own, and the per-tile acks coincided with decode stalls.

### Open
- ~~BWE is a fixed 60 Mbps~~ → adaptive since the next commit (below).

## Adaptive BWE + real RR loss (same day, unit-tested only)
- `BandwidthEstimator` (Screener/Transport/BandwidthEstimator.swift), ticked by every RCTL (50 ms): starts at 30 Mbps (the native captures show no start ramp: the RCTL body is encrypted and the sessions were static), +6 %/s toward 65 Mbps (u16 wire limit) while windowed loss (1 s) < 2 %, the host fills ≥ 60 % of the estimate and no recovery event in 2 s; ×0.85 (or 0.85 × receive rate, at most halving) when loss > 10 % (1 s hold-off) or on an assembler keyframe request / video-consumer backlog (3 s hold-off); 2–10 % holds; idle screen (receive rate < 60 % of the estimate, or too few packets) holds; 1 %/s within ±10 % of the last cut point; floor 4 Mbps; 1 s startup grace.
- Loss = expected − received per tile SSRC (RFC 3550 A.1 `RTPReceptionStats`), summed over the window so late/reordered packets cancel.
- RCTL loss fields: top nibble = the longest run of consecutive missing packets this tick (cap 15; AVConference names it burstyLoss and AFRC ramps down on it); low 12 bits = windowed loss in whole percent. **Unknown:** the 12-bit field's unit (it comes from VCRateControlGetStatistics type 7, offset 0x24; percent is the conservative reading). owrd stays 0: the video RTP extension carries no send timestamp.
- RRs now carry RFC 3550 A.3 fraction lost / cumulative lost (jitter still 0).
- Env: `SCREENER_RCTL_BWE=<kbps>` pins (0 = measured), `SCREENER_RCTL_INIT/MIN/MAX`, `SCREENER_RCTL_LOSS=0`, `SCREENER_FB_RR_LOSS=0`, `SCREENER_FB_RCTL=0`. Log every 2 s: `rctl bwe=… (adaptive; est=…) loss%=… rx_kbps=… state=increase|decrease|hold|hold-app|hold-off|hold-idle decreases=… sent_loss=…%/burst…`.
- The simulator drops packets at these rates: the host capture has ~15–40% more video datagrams than the app reads (worst with per-tile acks). The kernel socket buffer is the likely place; worth checking on the iPad.
- The echo field's exact source (RTP timestamp, low vs high precision) is unverified; the host accepted it either way.

## Loss recovery, LTR acks, QoS (same day, later)

### What the stream looks like (decrypted captures, slice headers via hevc_rps.py)
- The four tiles are ONE HEVC sequence: shared POC space (tile k of frame n ≈ POC 4n + k), one DPB, IDR only on tile 0 (the other tiles' first pictures are P slices with no used references). SPS: log2_max_poc_lsb 11, 16 short-term RPS sets (keep up to 15 previous POCs), no long-term refs.
- References cross tiles: tiles 2/3 often use tile 0's picture of the same frame (delta -1/-2); every picture also keeps one old "anchor" picture as a used reference (e.g. delta -119 … -472), refreshed every few seconds.
- So a lost picture breaks exactly the later pictures whose RPS marks it used — on any tile — and often nothing at all (e.g. a lost tile-2 picture that only tile 2's next picture would have used, when that next picture predicts from tile 0 instead).

### LTR ack semantics (AVConference, macOS 27)
- `_VideoReceiver_ProcessRtcpLTRAck` logs "Received APP_LTRP_ACK timestamp=%u"; `VideoTransmitter_ACKLTRFrame` matches the value against a ring (≤ 100) of the keys of frames it sent; `__VCVideoReceiverDefault_sendLTRAckWithTS` / `VideoTransmitter_SendLTRACK` on the viewer side queue the same. ~~The APP name-5 u32 is the picture's RTP timestamp~~ — wrong for the multi-tile screen stream, see "LTR acks carry the DONL" below.
- With timestamp acks on every tile picture (SCREENER_FB_ACKALL=1), the host still answered every FIR or PLI (SCREENER_KF_MODE=pli) with an IDR, and with the FIR held back 1.5 s (SCREENER_FIR_DELAY_MS) it never repaired on its own. iPad A/B under induced loss: IDRs 20 / 30 with acks vs 24 / 17 without — noise. Acks stay opt-in.

### Reference recovery (HEVCReferenceTracker + HEVCAssembler, default on)
Release every picture whose used references were decoded (also on a tile that just lost one), drop any picture that needs a lost/broken one (any tile) and request a keyframe then, or 300 ms after a loss that left the tile with nothing decodable. Replay check: the Swift tracker's broken-picture count equals hevc_rps.py's on three captures (1423, 817, 123).

Keyframe requests no longer cut the BWE (SCREENER_KF_CUTS_BWE=1 restores it): sustained loss already cuts through the loss rate, and the per-request ×0.9 steps held the estimate far below the link.

### iPad Pro M5 (Wi-Fi, host 192.0.2.54, textured window dragged full-screen; Debug -O builds; 2 s windows after startup)
| Run | Mbps (median) | BWE median / min | loss events | keyframe req | IDRs | recovered by refs | decode errors |
|---|---|---|---|---|---|---|---|
| old bfd7940, 60 s | 37 | 44 / 26 | 7 | 4 | 2 | – | 0 |
| old bfd7940, 120 s | 58 | 65 / 35 | 10 | 7 | 4 | – | 0 |
| new, 60 s | 57 | 65 / 49 | 7 (all at start) | 4 | 2 | 0 | 0 |
| new, 120 s | 58 | 65 / 58 | 0 | 0 | 1 | 0 | 0 |
| new, 120 s | 58 | 65 / 56 | 5 | 4 | 2 | 0 | 0 |
| new, SO_NET_SERVICE_TYPE off, 120 s | 57 | 65 / 55 | 5 | 0 | 1 | 3 | 0 |
| induced loss (4 datagrams / 2 s), refs OFF, KF cuts BWE | 21 | 19 / 6 | 78 | 126 | 47 | – | 11 |
| induced loss, refs ON, KF cuts BWE | 31 | 36 / 20 | 79 | 70 | 27 | 31 | 0 |
| induced loss, refs ON (new default) | 50 | 65 / 54 | 76 | 78 | 24 | 20 | 0 |

The Wi-Fi was much cleaner than in the user's earlier session (rx_gaps50 ≈ 2 per 2 s vs 7–12): 0–10 loss events per 2 minutes at ~58 Mbps, so no evidence for capping the BWE below 65 Mbps, and none for or against NET_SERVICE_TYPE_VI (SO_NETSVC_MARKING_LEVEL reads 0 = unknown on the iPad).

## LTR acks carry the DONL: the cause of the per-keypress flash (2026-11-19)

### Symptom
Decrypted captures of our stream: tile 0 predicts from its own previous picture and is tiny when static; tiles 1–3 always predict from tile 0's pictures (used deltas (-1,-5), (-2,-6), (-3,-7)). Their RPS keeps only tile-0 pictures (`-1 -5 -9 … -59` for tile 1): tiles 1–3 are never kept as references. So every unchanged strip is re-encoded from the wrong strip at 10–140 KB per picture, quality ramps up and steps down (the "flash"), and the host never skips an unchanged tile. Decoding the capture confirms the strips really are unchanged (median per-pixel difference to the tile's previous picture ≈ 0). The host's encoder stats (`[VCPEncStatsMonitor]` in avconferenced's log, readable with `log show --predicate 'process == "avconferenced"'`) show it: ours drop_fps ≈ 0 and Tx_fps ≈ 160–240 at 40–60 Mbps; the native viewer's session drop_fps ≈ 110–160 and Tx_fps ≈ 30–90 at 0.04–6 Mbps. Every VCPEnc property is identical between the two sessions (the native NegotiationDetails has an extra `SW:0`; adding it to our offer changed nothing in a controlled A/B).

### Cause
In multi-tile screen mode (`tilesPerFrame ≥ 2`, `VideoTransmitter_CreateHandle` sets `tx+0x5ee4 = 1`), `_videoTransmitter_HandleLTRFrame` keys the LTR ring by a 16-bit per-tile-picture id (`tx+0x5ee6` = `hwrandom16()` + the sample's TileID / decoding order), which the packetizer sends as the RFC 7798 **DONL**. The receiver side (`VideoPacketBuffer_GetNextFrame`) acks the frame's DON in that mode and the RTP timestamp otherwise. Our acks carried the RTP timestamp, which the four tiles share and which matches nothing in this mode, so the host never saw an acknowledged picture: the encoder kept tile 0's history as references and could not keep the other tiles'.

### Fix
One APP name-5 ack per decoded tile picture, u32 = the picture's DONL (first NAL's DON), sent right after it decodes, as the native viewer does (one 30-byte SRTCP APP per tile marker). ON by default; `SCREENER_LTR_ACK=0` turns it off. The old `SCREENER_LTR_ACK=1` (tile 0, timestamp) and `SCREENER_FB_ACKALL=1` modes are gone.

Ruled out on the way (live A/B, simulator → this Mac): acks per tile marker carrying the RTP timestamp, the extension's frame counter, the whole extension word, the first or the marker RTP sequence number; `SW:0`/`SW:4` in the offer's feature strings (with and without the bitfield bit); a Mac hardware model in RemoteEndpointInfo; RCTL off, per-port RRs, zero-loss RRs (2026-11-19 morning).

### A/B (simulator, host 192.0.2.54 from 192.0.2.33, a Terminal printing a line every 0.5 s; steady state after startup; per tile: pictures/s, median KB, share of pictures predicting from the tile's own previous picture)
| Variant | tile 0 | tile 1 | tile 2 | tile 3 | total | host encoder (drop/s, tx/s) |
|---|---|---|---|---|---|---|
| acks off (old behaviour) | 44/s 0.13 KB 98 % | 44/s 44.8 KB 34 % | 44/s 35.3 KB 5 % | 43/s 19.5 KB 3 % | 41.6 Mbps | 0–14, 170–190; 37–52 Mbps |
| acks off, second run | 40/s 0.13 KB 100 % | 40/s 0.43 KB 67 % | 39/s 41.1 KB 2 % | 39/s 20.0 KB 1 % | 61.4 Mbps | 0–11, 140–160; 10–124 Mbps |
| DONL acks (new default) | 3.7/s 0.39 KB 100 % | 2.3/s 0.13 KB 100 % | 2.3/s 0.13 KB 100 % | 10/s 0.30 KB 100 % | 0.07 Mbps | 126–164, 0–55; 0–4 Mbps |
| DONL acks per marker (pre-decode) | 19/s 0.15 KB 100 % | 9/s 0.13 KB 100 % | 45/s 0.16 KB 100 % | 6/s 0.13 KB 100 % | 0.19 Mbps | 92–138, 18–92; 0.1–7 Mbps |

A sliding textured window (60 % of the screen) with DONL acks: tiles 1–3 at 60 pictures/s, 5–8 KB median, 100 % own-reference, 7–35 Mbps, 0 decode errors. Keyframe requests per 25 s run: 0–6 with acks vs 30 without.

### Open
- Acks are sent for every decoded picture; the native receiver acks only pictures with the LTR flag (VideoPacketBuffer frame flags bit 0, wire source unidentified — possibly the 0x93xx extension profile's low byte). Acking every picture works on this host.
- Several runs today needed a 0x1c re-query (media answer after ~8 s instead of ~2–3 s) with or without the change.

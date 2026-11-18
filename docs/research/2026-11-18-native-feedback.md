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

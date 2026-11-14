# Screener — handoff (paused 2026-11-14)

Branch `feat/screener-v1`. Resume with `/superpowers-extended-cc:executing-plans docs/superpowers/plans/2026-11-13-screener-ipad-hp-client.md`. `*.tasks.json` holds per-task status, evidence, followUps and pendingFixes.

## Working on a real iPad (verified)
- Auth (SRP), encrypted control channel, media negotiation.
- HEVC 4:4:4 at ~60 fps, hardware decode, full-res 2752×2064.
- Input: pointer, keys, touch, cursor. Key repeat. Background → clean close → auto-reconnect. Friendly errors.

## Done since the last device test (not yet tried on the iPad; build installed 2026-11-14)
- Strip-tear fix (9a5cce5).
- Floating menu: Task 20 (07fd458, 5772a5b). Not code-reviewed yet. Device checklist is in tasks.json.

## Remaining tasks
- 21: display modes. High value: the Mac caps video at ~17–19 Mbps, so full-res looks soft. Offer a sharper lower-res mode.
- 16: audio.
- 17: clipboard.
- 18: saved hosts + Bonjour + Keychain.
- 19: TCP-only fallback.
- 22–24: polish.

User suggested a lighter process to save quota: one review per task, smaller models for simple tasks, defer 22–24 if needed.

## Testing rules
See memory: `screener-remote-testing`, `testflight-deploy-method`.
- User home → ask before any live run.
- User away → simulator runs OK: `SCREENER_LOCAL_ADDR=192.0.2.33 Tools/sim-connect.sh 192.0.2.54 25`.
- iPad: `Tools/ipad-connect.sh` (DEBUG auto-connect).
- Never read `~/.screener-test.env`.
- Known flaky test: `SessionCoordinatorTests.testAMediaChannelFailureFailsTheSession` (timing).

# DeepBide-Telemetry changelog

## v1.1.0 — 2026-11-27

- Add optional `context_renewal_0_1` for genuine current menu, combat, quest
  and objective readings at a nominal 0.5-second cadence in verified
  expanded-profile gameplay. Default false; schema 0.03 and other behavior
  unchanged with the option off.
- Preserve native reader modules, the base TCP receiver and RedSocket 0.5.2
  dependency byte-for-byte; no new network destination or data family.
- Add an optional standalone expanded CET log follower (`--follow`,
  `follow_cet`) with witnessed archive/sequence continuity, explicit
  loss reporting, bounded reads and no network or log writes. Existing
  offline capture API remains supported. Source archive only; no extra
  runtime file or Python installation needed for players.
- Focused offline delta validation: retained renewal tests, explicit
  configuration/default-off and Journal interoperability checks, plus
  receiver/replay crosscheck, rotation-specific Windows filesystem tests
  and 449-row offline reproduction. Prior physical evidence is retained; no
  new exact-build ingame/FPS claim. See README and PROTOCOL.

## v1.0.0 — 2026-11-26 (stable)

- Official baseline and expanded profiles, with optional Journal and live-target contracts.
- Exact four Lua files and disabled template from v0.1.0-rc.1, no runtime changes.
- Standalone expanded reader, validator, replay and tests; no private database or assistant dependency.
- Attended physical validation of expanded + optional contracts, controlled EOF,
  reload, progression, stash, reference-gap accounting and ordinary shutdown.
- Requires the stable 0.5.2 RedSocket distribution (unchanged RC3 runtime).
- Earlier A/B evidence retained, no FPS claim for the final revision. See README
  for scoped evidence and limits. The historical pre-release entry follows.

## v0.1.0-rc.1 — 2026-11-26

First standalone pre-release candidate for Cyberpunk 2077 2.5.

- Read-only baseline observations, loopback TCP schema 0.03, correlated
  ACKs, bounded outstanding frames, inventory snapshot/delta recovery and
  explicit loading/disconnect invalidation.
- Exact DeepBide-RedSocket 0.5.2-rc.3 integration, individual socket
  ownership, bounded rebind after retirement and explicit send refusal.
- Standalone reference receiver, protocol guide, tests and reproducible
  source-to-mod packaging.
- Default configuration remains disabled; select baseline rather than
  expanded when intentionally enabling. No active local identities.
- All four Lua files are byte-identical to the physical baseline pairing
  tested on 26 November 2026. The template and documentation/package
  metadata changed, not the Lua implementation.
- Expanded diagnostics and optional stronger Journal/target extensions
  remain experimental; no extended soak, comparative FPS or other runtime
  compatibility guarantee. See README for evidence and privacy limits.

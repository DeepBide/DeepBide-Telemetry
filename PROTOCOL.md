# DeepBide-Telemetry wire guide

Version 1.1.0 for Cyberpunk 2077 2.5. The game producer
does not depend on a particular consumer, assistant, database or HUD. No game
version, dependency binary or producer identity is authenticated by this
protocol alone. The example is for a local developer, not an approved deployment.

## TCP stream (schema 0.03)

Listen on IPv4 loopback only. The default port is 20770 and the producer's
configuration can select another local port. Use UTF-8 JSON objects separated
by LF, optionally preceded by CR. Handle split/coalesced TCP reads. RedSocket
provides framing on the producer side; do not append CR/LF inside SendCommand.
Bound a frame to at most 1 MiB. No TLS, authentication, encryption, remote
control, or commands into the game are supplied. Restrict access to the host;
any local process may imitate an endpoint. Treat input and output as untrusted.
Do not log raw frames, UUIDs, item/entity identifiers or game text by default.

Each observation has these fields:

- schema_version: "0.03"; game_id: "cyberpunk-2077"; game_version: "2.5"
- message_id, session_id, user_id, run_id: canonical lowercase UUID strings.
  A message ID identifies the offered frame; session_id identifies a TCP epoch.
  User/run IDs are local correlation labels, not accounts or credentials.
- source: "chumpilot.cet"; historical wire literal, not a dependency.
- observation_type: one of the types below; timestamp: UTC YYYY-MM-DDTHH:MM:SSZ.
- payload: a JSON object; provenance: object with sensor "cyberpunk_runtime",
  adapter "chumpilot_cet", method describing the native read. Optional
  journal_reference_contract or live_contract carry sample sequencing.
- confidence: producer's confidence value, not proof of receiver identity,
  causality, or independently verified native state.

Reply once per accepted observation with
`{"status":"accepted","message_id":"<the exact received UUID>"}` followed by LF.
An ACK means the receiving application processed/accepted the offered frame
according to its stated scope. Never issue it for a frame you rejected. For
malformed or unacceptable input, send
`{"status":"rejected","error":"invalid_frame"}` and close the connection. The
producer rejects unknown, duplicate or prior-epoch ACK IDs, oversized/malformed
responses (limit 4096 bytes), resets the TCP epoch, and offers fresh baselines.
It tracks at most 256 outstanding observation ACKs; unanswered observations
time out after 15 seconds of elapsed updates (checked at most once per second).
Inventory sync/change frames are serialized on their correlated ACK. This
is not exactly-once delivery, end-to-end authentication, or persistence.

Heartbeat is a separate control object:

```json
{"control_type":"heartbeat","schema_version":"0.03","session_id":"12345678-1234-4234-8234-123456789abc","timestamp":"2026-11-25T00:00:00Z"}
```

Reply `{"status":"heartbeat","session_id":"<the received session UUID>"}`
followed by LF. Heartbeat is transport liveness, never renewal of an observation.
Use a new connection/window on reconnect; pin the UUID and user/run labels to
the connection and never merge state across connections. A UUID change inside
an existing stream is not evidence of a new native session.

### Base types

| Type | Payload and scope |
|---|---|
| MENU_STATE | is_menu, is_loading, normalized_category; optional raw_menu_scenario/raw_menu_item. Loading invalidates world facts; ordinary menus are not necessarily detached. |
| PLAYER_POSITION | x, y, z native world coordinates. |
| COMBAT_STATE | in_combat boolean from player. |
| PLAYER_LIFE_STATE | health_current, health_max, life_state alive/dead; no cause of death inferred. |
| ACTIVE_QUEST | active; quest_hash and quest_title for a resolved active quest. |
| ACTIVE_OBJECTIVE | active; objective_hash and objective_text for a resolved tracked objective. |
| JOURNAL_UNAVAILABLE | optional verification mode: reason, generation, terminal, last_sample_seq. Revoke quest/objective; not active=false. |
| CURRENT_WEAPON | equipped; item_id when equipped. |
| VEHICLE_STATE | mounted, role driver/unknown; vehicle_id when mounted, optional record_id and vehicle_type. |
| CURRENT_DISTRICT | current_district_id; native_hierarchy root to leaf, up to eight levels, optional localized names. |
| TARGETED_ENTITY | present; entity_id when present, optional class_name, record_id, world_position and distance_m. No action or identity of a human inferred. |
| INVENTORY_SNAPSHOT | STATE_SYNC, scope player_transaction_inventory, entries, entry_count, source_entry_count, excluded_entry_count, max_entries, truncated. |
| INVENTORY_DELTA | STATE_CHANGE, same scope, changes, change_count, affected_entry_count. |

Optional target and Journal extensions retain their existing sample sequence,
baseline and (Journal) generation fields. Their stronger ordering and any
consumer-specific admission policy are not implemented by the small example.
Read the supplied Lua for exact native calls and optional fields.

Inventory: maintain a multiset of (item_id, record_id or empty, item_type or
empty, quantity), not a map keyed only by item_id. IDs are strings; do not
convert native uint64 to floating-point numbers. Each entry's quantity is a
positive integer. A snapshot is a usable complete baseline only when
truncated=false, excluded_entry_count=0 and counts agree. An empty Lua table
may be encoded as an empty object for zero entries. Do not treat a missing
read as an empty inventory. Deltas carry change_type (added, removed,
quantity_changed), before_quantity, after_quantity, quantity_delta,
occurrences, identity_ambiguous and the same identity fields. Quantity zero
marks the side absent from that change, not an inventory entry. Subtract the
before tuples and add after tuples with their multiplicity; reject a removal
that the prior baseline cannot support. Never invent an instance pairing from
duplicate identities or attribute a delta to a particular loot/craft action.
Partial/expired/missing baselines remain unknown until a fresh complete sync.
The source is the player's transaction inventory, not a census of all storage.

### Freshness and loss

The producer offers world facts only when its current attachment, lifecycle,
menu and loading witnesses permit them. A verified MENU_STATE loading revokes
old world facts. Ambiguous readiness after world observations retires the TCP
epoch. Do not infer absence from silence, deduplication or disconnected
transport. Clear all facts on disconnect/reject/new epoch; revoke world facts
on loading and Journal facts on JOURNAL_UNAVAILABLE. Explicit positive or
negative payloads describe the particular successful native read. Never use
a previous fact as evidence that a new read succeeded.

Choose an expiry policy independently for each fact. The example uses a
conservative ten-second receive-age window (configurable); no unchanged fact
is renewed by heartbeat. That can deliberately expire an unchanged fact even
while the connection is healthy. The receiver's monotonic clock only bounds
receipt age, not game/source freshness, and sender timestamp is not trusted
as an authenticated clock. A fresh row can renew only the fact it actually
reports. A later delta does not renew an expired full inventory baseline.
The example retains a loading boundary until an explicit nonloading menu
witness and requires a menu witness before world data. It is not an advice
engine or a complete product admission implementation.

### Opt-in current-context renewal 0.1

Introduced in mod version 1.1.0; schema_version remains 0.03.
The new optional boolean config field `context_renewal_0_1` defaults to
false (missing is also false). With native_candidate_25 enabled, true
requires native_candidate_profile="expanded" and poll_interval_seconds=0.5
(the existing default if omitted). Non-boolean values or incompatible
enabled configurations are refused before registration/socket creation.
An omitted or false option keeps existing deduplication and the independent
Journal/target contracts unchanged. It does not enable the producer itself.

In a verified, connected gameplay poll (current UI says not in menu,
attached player, not pregame, no unresolved loading state), the existing
native reads for MENU_STATE, COMBAT_STATE, ACTIVE_QUEST and ACTIVE_OBJECTIVE
may bypass same-value deduplication. Each emitted observation is a fresh
successful read, with a new message ID and ordinary producer timestamp;
timestamp resolution is unchanged and consecutive samples may have equal
timestamp strings. No cached or failed read is relabeled. A successful
explicit negative read is valid; unknown is not absence. Combat=true is a
valid current reading. No other type, payload schema or provenance field
is changed by this option. The Journal 0.2 sample_seq/generation/baseline
and invalidation contract, if enabled separately, remains intact: its
existing renewals and the new bypass do not emit duplicate observations
for one read. Without Journal verification, failed Journal reads remain
suppressed; the consumer must expire them. No synthetic invalidation or
positive value is invented.

The nominal interval is 0.5 s of update time while eligible; no guaranteed
wall-clock, receive or delivery deadline. A delayed update does not emit
catch-up samples, and the existing ACK window/refusal behavior remains.
No new periodic renewal during ordinary menus/loading/unknown readiness,
or when disconnected. Existing transitions and independently enabled
Journal/target renewal continue as before. Fresh entry or new TCP epoch
rearms the four-read renewal; loading revokes old world state and existing
native generation/Journal lifecycle remains authoritative. Consumers must
discard/expire on loss, session changes and generation boundaries, never
treat heartbeat or same-value dedup silence as fresh evidence, and require
the next eligible current observations after recovery. A nominal rate
does not justify expanding any consumer freshness limit. No consumer
should infer game semantics, a connected process identity, or advice
eligibility from cadence alone.

### Optional native budget recovery fence 0.1

Set `native_budget_fence_0_1=true` only with `context_renewal_0_1=true`,
`native_candidate_25=true`, expanded profile and 0.5-second polling.
Missing/false preserves existing behavior; incompatible/invalid configs
are refused before socket/observer registration. This is an optional
producer-side provenance extension, not a new sensor, wire type or
consumer policy. Schema remains 0.03; expanded row contract remains 0.3.

The native budget remains 24 offered rows per elapsed-second bucket.
After loss the producer suppresses further correlated state until an
explicit `SOURCE_GAP` (`source=Producer.budget`,
`reason=EVENTS_DROPPED`) is offered. The barrier is prioritized at
replenishment; the existing bounded lifecycle close path reserves a
close and reports pending loss. Counts are aggregate attempted emission/
callback/scheduler loss indicators, not an exact census of distinct
native actions or their kinds. A gap invalidates native correlations,
including pending device/root/stash state; future snapshots cannot repair
the historical loss. Budget loss is not a TCP epoch break by itself.

The independent BASE poll uses current UI, attachment, lifecycle and
Journal/combat reads, not the optional native replay or its dedup cache.
For each genuinely renewed MENU_STATE, ACTIVE_OBJECTIVE, ACTIVE_QUEST
and COMBAT_STATE, the optional provenance object may be offered:

```json
{"native_budget_fence":{"version":"0.1","generation":3,"barrier_sequence":166,"poll_sequence":42}}
```

Integers are positive and at most 2147483647. The envelope session_id
identifies the TCP epoch and matches the expanded row producer_session.
generation and barrier_sequence identify the exact successfully offered
native budget gap in that epoch. poll_sequence is increasing per TCP
epoch, never reused, and does not count missed polls or promise timing.
The marker is read at each frame's offer boundary; absent before any
barrier, while loss is pending, on inactive native generation, or on
an unavailable marker. There is no tag on cached facts, heartbeat or
other observation types. MENU_STATE is offered before the native tick:
if a barrier occurs mid-poll, the four offers cannot all match its
tuple. Wait for an actual later matching set, never assemble one from
adjacent polls.

For a consumer requiring a post-gap BASE-only recovery:

1. Independently validate exact approved producer/configuration, game
   process/TCP peer and connection, session/run scope, native sequence
   and generation opening. Process native data through the existing
   validator and retain each actual budget barrier; revoke prior context
   and keep native-domain loss sticky. An unmatched marker is not a
   barrier receipt. Reject native source discontinuity, malformed rows,
   close, reconnect, ambiguous lifecycle and other unresolved SOURCE_GAPs.
2. After the latest validated budget barrier, discard old cached BASE
   data and fence receiver ingress by its actual monotonic arrival/frame
   watermark. Require distinct accepted message IDs and exactly one of
   each of the four genuine rows, in MENU_STATE, ACTIVE_OBJECTIVE,
   ACTIVE_QUEST, COMBAT_STATE order, matching the same session, generation,
   barrier_sequence and strictly new poll_sequence. Refuse duplicates,
   missing/wrong marker, skipped/changed generation, older barrier,
   mixed polls/peers, backlog, loading, menu, invalid Journal or transport
   boundary. Require all four to be fresh under the consumer's existing
   tighter age/receive-order/source-age gates; no TTL extension, no
   treating second-resolution timestamps as causal order.
3. Recheck current peer/lifecycle, latest observed barrier and freshness
   before any use. A new gap/close, loss of identity, stale/partial set
   or other invalidating boundary revokes the scope. Only BASE facts
   in the fresh set are supported. This is not native READY, restoration
   of lost events, proof of death/resurrection/mission completion or
   entitlement to an advice/action. Leave native-dependent correlations,
   learning and terminal inference UNKNOWN until their own evidence.
   A consumer may choose to remain silent. No cross-stream authenticity
   or lossless capture guarantee is claimed.

The legacy reference receiver accepts the additional provenance object
but does not implement this stronger recovery policy. Consumers must
opt in deliberately and test it. The original source-only follower
retains ordinary rotation and integrity limits. No capture or gameplay
data is uploaded by these tools.

## Expanded profile: supported local observation stream (not TCP)

Both profiles were physically tested on the documented runtime pairing. Expanded is opt-in; see README for scope, evidence and configuration.

With native_candidate_25 enabled and native_candidate_profile=expanded, the
producer writes separate CET log records prefixed
`[DeepBideTelemetry] READY_CANDIDATE_CONTRACT=cp25-native-candidate/0.3` and
`[DeepBideTelemetry] CANDIDATE_JSON=` followed by one JSON object. Baseline
profile uses only TCP. Do not route these rows into the base TCP receiver.

Diagnostic envelope: contract, producer_session (UUID), generation (positive
integer), sequence (positive integer), elapsed_ms (nonnegative integer),
kind, source, availability, data; reason is present for UNKNOWN/UNAVAILABLE.
OBSERVED describes a scoped native witness; ABSENT is explicit absence within
that read. UNKNOWN and UNAVAILABLE are not ABSENT. Nested field availability
is independent. A numeric enum or raw callback is not a gameplay conclusion.
A fresh generation opens with SESSION data.ready=true, sequence=1,
elapsed_ms=0; close with data.ready=false and reason/dropped_events as
applicable. Require contiguous sequence and nondecreasing elapsed time.
Missing closes, real gaps, dropped events, unoffered references, incomplete
stash snapshots and source discontinuity prevent completeness claims.
A new opening can rearm diagnostics but cannot erase prior missing evidence.
After rotation, do not certify bytes already present as a new live session.
A registration marker is not process identity.

### Optional external CET follower (1.1.0)

The source-only Python example offers bounded, opt-in `--follow` and an
importable `follow_cet` callback API. It begins at the witnessed EOF and
requires a future valid SESSION opening. A pre-opening file replacement
rebases at EOF and requires a future registration/opening. Native rows
are validated through the existing expanded contract and replay; no new
wire type, sensor, runtime writer or transport is introduced.

A normal post-opening rotation can bridge only the immediate `scripting.1.log`
with the same old file identity, full consumed-prefix SHA-256 and matching
tail, stable retained file boundary and complete archived lines. The unread
archive suffix is validated before accepting the successor. Its first native
row must continue the current generation's exact next sequence, or start
an admissible new generation after the prior explicit close. Missing,
ambiguous or overwritten archives, incomplete cross-file rows, skipped
rotations and invalid successor order fail closed. No automatic replay of
historical files, hidden resynchronization, or merging of unverified bytes.

Receipt fields:

- `source_continuity`: `APPEND_SCOPE`, `ROTATION_VERIFIED_SCOPE`,
  `LOST_AFTER_OPEN`, `UNVERIFIED_BEFORE_OPEN` or `WAITING_FOR_FRESH_OPEN`.
- `source_rotations_observed` counts detected changes; `source_rotations_verified`
  counts only boundaries with a validated successor native row.
- `source_rotation_recovered_rows` counts validated rows recovered from
  archived tails; `source_continuity_error` reports a bounded reason or null.
- `current_producer_attested` is always false. `capture_integrity` describes
  the observed scope, not complete field semantics. `CLOSED_NO_RECORDED_LOSS`
  does not erase UNKNOWN/UNAVAILABLE or interrupted stash snapshots.

The follower caps each raw source file at 64 MiB, newly scanned bytes at
128 MiB, lines at 65536 bytes and accepted rows at 200000; the native row
byte/shape budgets still apply. It reads the log only; there are no writes,
network calls or external services. Default duration 900 seconds, explicit
1..3600 seconds or supervised until-stop with the same caps; poll 0.05..2
seconds (default 0.5). A missing current file after opening is allowed a
bounded retry (max of 1 second or three polls), then stops incomplete.
A stop with a pending boundary or partial line is incomplete. The consumer
must revoke context on invalidation or continuity loss and enforce its own
process identity, freshness and lifecycle gates. The cursor is designed
for ordinary CET rotation, not authentication against malicious log edits.
The summary covers only observed input up to stop, not an exhaustive EOF
attestation or empirical FPS claim.

Families and kind names (read the accompanying modules for
the exact data fields and native source names):

- SESSION, SOURCE_GAP and STATIC_RECORD_REFERENCES.
- SCANNED_TARGET, SCANNER_STATE, SCANNED_TYPE, QUICKHACK_OPTIONS,
  QUICKHACK_SELECTED, QUICKHACK_REQUEST, DEVICE_COMPLETION, DEVICE_READBACK.
- DIALOGUE_ATTEMPT, DIALOGUE_HUBS, DIALOGUE_SELECTED_INDEX,
  INTERACTION_CONTEXT, INTERACTION_WITNESS, JOURNAL_WITNESS,
  TRACKED_ROOT_STATE, ROOT_JOURNAL_READBACK, JOURNAL_VISIT.
- SELECTED_MAPPIN, MANUAL_MAPPIN, SHARD_STATE, SHARD_POPUP,
  RELIC_DEVICE_WITNESS, RELIC_PROGRESS, TAROT_WITNESS, TAROT_COLLECTION.
- PLAYER_DEATH, PLAYER_RESURRECT, STATUS_EFFECT_WITNESS, STATUS_EFFECTS,
  FAST_TRAVEL_REQUEST, FAST_TRAVEL_LOAD.
- BRAINDANCE_ACTIVE, BRAINDANCE_LAYER, BRAINDANCE_DIRECTION, BRAINDANCE_SPEED,
  BRAINDANCE_FPP, BRAINDANCE_END, BRAINDANCE_PROGRESS_RAW, BRAINDANCE_TIME_RAW,
  BRAINDANCE_CLUES.
- EQUIPMENT_AREA, EQUIPMENT_ITEM, STASH_SNAPSHOT, STASH_SNAPSHOT_CHUNK,
  POLICE_PHASE, PROXIMITY, PROGRESSION, VEHICLE_NATIVE.

Rows are limited to 32768 encoded bytes; budgets are explicit in the Lua.
Correlate DEVICE_READBACK only with its completion in the same generation
and bounded readback window. ROOT_JOURNAL_READBACK requires its prior active
root witness. Dropped events revoke pending correlations. STASH_SNAPSHOT
headers and ordered contiguous chunks describe one scoped snapshot, not all
storage; require final chunk and count agreement. Progression complete covers
perks; attributes_complete is separate, and points/skills have independent
availability. Static record references may be unresolved; no static value
certifies dynamic instance properties or mod overrides. The base TCP example does not parse these rows. The included expanded reader
validates and replays bounded, chronological JSONL or CET log captures,
reassembles stash snapshots and reports gaps, offers and interrupted snapshots.
It does not include a static metadata catalog or prove live process identity.
A CLOSED_NO_RECORDED_LOSS report is scoped to stream closure and reported loss;
inspect interrupted stash counts and field availability separately. No exhaustive
semantic guarantee is implied for every field or gameplay state.

## Local development example

The source-review archive contains examples/receiver.py (Python 3.11 or
later, standard library only) and examples/test_receiver.py. Run the tests
without the game:

```sh
python examples/test_receiver.py
python examples/receiver.py --help
```

For a separately approved, compatible installation only, start the receiver
with the matching configured port (e.g. --port 20770). The example opens
127.0.0.1, accepts one connection at a time and only prints aggregate counts.
Stop with Ctrl+C. Configure idle-timeout above the producer heartbeat period.
Use newly generated local UUIDs; do not paste existing personal config into
reports. This is a review package, not an instruction to activate it now.

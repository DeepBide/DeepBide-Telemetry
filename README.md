# DeepBide-Telemetry for Cyberpunk 2077

**v1.1.0 · MIT · Windows x64**

Read-only, opt-in game-state observations for local applications. Build your
own tools, companion applications, experiments or integrations using a
documented TCP JSONL protocol. No particular assistant, account, cloud
service, database or HUD is required.

## What it provides

The baseline profile observes position, life/health, combat, menu/loading,
active quest and tracked objective, current weapon, vehicle, district,
targeted entity, and player inventory snapshots/deltas. These are scoped
native reads, not a complete model of the game or proof of action causality.
Unchanged values may be deduplicated; silence does not imply absence.
See [PROTOCOL.md](PROTOCOL.md) for the exact schema 0.03, ACK contract and
freshness rules.

Both profiles are supported, opt-in and functional. Baseline is the default
when intentionally enabled. Expanded additionally observes scanning,
quickhacks, dialogues, interactions, Journal, map, shards, Relic, tarot,
status effects, fast travel, braindance, equipment, stash, police,
proximity, progression and vehicle witnesses. These rows are a separate
local CET log stream; they are not additional TCP observations. Optional
Journal and live-target TCP contracts are also supported. Version 1.1.0 adds
an opt-in current-context renewal contract for consumers that need fresh
unchanged gameplay readings. See PROTOCOL.md for scoped meaning, explicit
availability and freshness rules.
This mod does not play the game, write saves, give advice or display a HUD.

## Requirements — exact tested combination

| Component | Version |
| --- | --- |
| Cyberpunk 2077, Windows x64 | 2.5 (file version 3.0.88.46235) |
| [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks/releases/tag/v1.38.1) | 1.38.1 |
| [RED4ext](https://github.com/WopsS/RED4ext/releases/tag/v1.31.1) | 1.31.1 |
| [redscript](https://github.com/jac3km4/redscript/releases/tag/v0.5.32) | 0.5.32 |
| [DeepBide-RedSocket](https://github.com/DeepBide/DeepBide-RedSocket/releases/tag/v0.5.2) | 0.5.2 (RC3 runtime build) |
| [Microsoft Visual C++ v14 x64 runtime](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) | compatible runtime for the transport |
| [Python](https://www.python.org/) | 3.11+ only for the optional example and packer |

Install dependencies separately. This release does not bundle them.
Use the stable 0.5.2 transport mod ZIP (SHA-256
3ff795b8ab8e0e3d56912955349c07a47e7112e056be6128f22e8a15c4e4fbb3). It contains the same four runtime files as 0.5.2-rc.3.
Its tested DLL SHA-256 is
40c76ec43cf56f16ca40d7441e8bdd108d1794b4d52cca00110b57328ec9a245.
Verify all four transport runtime files against its release manifest.
The original RedSocket and arbitrary other versions are not interchangeable.
A matching wrapper version string is not proof of DLL identity.

## Install and run locally

1. Close the game and launcher. Back up your existing mod files/configuration
   and follow the RedSocket release instructions. Never load two versions of
   the same transport or two competing telemetry producers at once.
2. Extract the mod ZIP separately and copy its **bin/** tree into the game
   root. The target is
   `bin/x64/plugins/cyber_engine_tweaks/mods/DeepBideTelemetry/`.
   Keep the release manifest and documents outside the game directory.
   Do not overwrite unrelated files. The example receiver is in the
   separate source archive, not in the installable mod ZIP.
3. Choose an unused IPv4 loopback port (default 20770). Extract the source
   ZIP and start the included local example from its root:
   `python examples/receiver.py --port 20770`.
   It listens on 127.0.0.1 only, accepts a single connection at a time, keeps
   temporary state in memory and prints aggregate counts when a connection
   ends. Stop it with Ctrl+C. If the port is in use, use another port and set
   the same value in the configuration; never stop an unrelated service.
4. In the installed mod directory, copy config.example.json to config.json.
   The template is disabled by default. Replace both UUID placeholders with
   valid canonical lowercase UUIDs; choose a persistent local user label and
   a logical run label (PowerShell: `[guid]::NewGuid().ToString()`, twice).
   These are local correlation IDs, not credentials. Keep host 127.0.0.1,
   native_candidate_profile "baseline" and optional flags false for the
    baseline profile. For the advanced profile, set native_candidate_profile
    to "expanded". The final attended advanced test also set
    journal_verification_0_1 and target_live_contract_0_1 to true and
    target_renewal_seconds to 1.0. Keep the remaining timing defaults. Set
   native_candidate_25 to true only when ready to share observations with
   your trusted local receiver. No active config.json is shipped.
5. Start Cyberpunk normally and load a game. The example acknowledges valid
   frames. It is a developer demonstration, not a dashboard or certified
   consumer. Its default receive-age TTL is ten seconds, independently of
   the sender's poll interval; an unchanged fact can legitimately expire.
   See PROTOCOL.md to build your own consumer. Use port values 1-65535 and
   supported optional timing values 0.1-300 seconds. Arbitrary settings
   have not been physically qualified.

To disable, close the game and set native_candidate_25 to false (or remove
the active configuration). To uninstall, close the game and launcher,
stop only your own receiver, remove only the DeepBideTelemetry directory,
and restore your prior backups if needed. Remove RedSocket separately only
if no other installed mod needs it, following its own instructions.

### Opt-in current-context renewal (v1.1.0)

For a consumer that expires unchanged context quickly, configure the following
in the active config.json, keeping the required local identity, game/schema,
host/port and other settings from the template:

```json
{
  "native_candidate_25": true,
  "native_candidate_profile": "expanded",
  "poll_interval_seconds": 0.5,
  "context_renewal_0_1": true,
  "journal_verification_0_1": false,
  "target_live_contract_0_1": false
}
```

This is a fragment, not a complete configuration file. The new boolean is
false by default; omission is equivalent to false. The enabled option
requires expanded and a 0.5-second poll (omitting the poll uses 0.5).
Invalid combinations are rejected before socket creation or registration.
Keep Journal and target-live options at your consumer's supported settings;
the existing Journal verification contract can also coexist with renewal.

During positively witnessed gameplay, the option renews MENU_STATE,
COMBAT_STATE, ACTIVE_QUEST and ACTIVE_OBJECTIVE from genuine current reads,
even when the values are unchanged, at a nominal 0.5-second cadence. It
does not relabel cached values, change schema 0.03, expand a consumer's TTL,
or claim a maximum delivery interval. At most one renewal per type per
eligible poll (nominally up to eight observations/s across these four).
Normal changes, other observations and heartbeat retain their own behavior.
No catch-up burst after a stall. Unknown or failed reads are not refreshed;
ordinary menus, loading and disconnected epochs do not receive the new
periodic gameplay renewal. Combat=true is still a real observation, not
permission to intervene. See [PROTOCOL.md](PROTOCOL.md#opt-in-current-context-renewal-01)
for the safety boundaries and receiver responsibilities.

## Privacy and security

When enabled, baseline sends game-state observations to the configured
IPv4 loopback receiver; non-loopback destinations are refused. Observations
can contain game text, quest/objective hashes, item/entity identifiers,
inventory, world coordinates, timestamps and local UUIDs. The included
example does not transmit them elsewhere or persist raw frames. It retains
bounded in-memory state; another receiver can have different behavior.
There is no TLS or peer authentication. Any local process may impersonate
a peer; do not expose, tunnel or forward the port to untrusted parties.
Do not use for sensitive personal data or security-critical decisions.

CET and its dependencies can create ordinary logs and local framework files.
The expanded profile writes additional CANDIDATE_JSON rows to
local CET logs and may expose detailed gameplay information. Do not publish
raw logs, configs, identifiers, saves, screenshots or game data. Do not
interpret a heartbeat as proof of fresh world state. UNKNOWN/UNAVAILABLE
are not ABSENT. The producer has no built-in remote analytics service,
updater or game-control command interface.

## Evidence and limitations

### Development and validation history

This release is the culmination of months of iterative development and
validation, not the result of a single short gameplay test. Throughout
development we performed hundreds of automated test-case executions and
regression checks, including repeated runs against successive revisions,
as well as hands-on in-game investigations, integration tests, controlled
connection failures, independent source reviews, and corrections followed
by targeted retesting. For example, selected earlier regression runs
recorded 144/144, 101/101 and 135/135 passing checks. These counts describe
test executions, not a count of unique test cases or gameplay sessions.

Earlier in-game investigation covered selected scenarios in 20 families
of telemetry observations, with two further advanced investigations closed
within their defined scope. The final release qualification runs described
below are representative checks of the exact v1.0.0 runtime files,
building on that longer body of evidence. Earlier tests covered the
revisions and scenarios exercised at the time; they do not imply universal
coverage of every game state.

### v1.0.0 final release qualification (historical evidence)

On 26 November 2026, the exact four Lua files in v1.0.0 were tested
in a short, attended real gameplay session with the above transport/runtime
and enabled baseline configuration (local trial UUIDs). A receiver using
the included reference consumer accepted 673 frames: 518 observations and
155 heartbeats, zero rejections/invalid frames/transport errors. A controlled
EOF recovered in 5 seconds with a new producer epoch and complete inventory
baseline while a separate HUD connection remained bound. An ordinary save
reload changed transport epochs, revoked old world facts and recovered a
fresh world/inventory baseline. Normal shutdown unloaded the transport;
test installation was restored. The trial used a 300-second consumer TTL,
not the example default. This is scoped protocol/lifecycle evidence, not an
independent audit of every native value, HUD pixel proof, or an FPS/soak test.

The same four Lua files and the same RedSocket runtime were also tested
in an approximately 13-minute attended gameplay session on 26 November,
with expanded enabled and the optional Journal/target contracts active.
The bounded receiver accepted 1,682 frames (1,329 observations, 353
heartbeats), with no invalid frames, rejections or transport errors during
reception. Controlled EOF recovered in 5.032 seconds; ordinary reload
revoked the old world state and recovered inventory and Journal baselines
in fresh connection epochs. The separate HUD route answered five binding
challenges (not visual HUD verification). Ordinary terminal cleanup and
loader unload were observed after the receiver's bounded window ended;
eight subsequent connection-failure warnings were expected with no receiver.

The two protected capture segments and retained rotated CET logs were
reconciled after exit: 1,545 native records, three opened and closed
generations, no missing sequence numbers or conflicting duplicates. The
standalone reader and original replay accepted those records; 40 complete
93-perk reads and 11 complete stash snapshots were observed. Seven
unoffered references were explicitly reported on the controlled disconnect;
two stash snapshots were interrupted at lifecycle boundaries. The overall
reader correctly reports an incomplete capture when source loss is present;
later generations closed without reported loss. This does not establish
continuous live capture, lossless delivery, or the correctness of every
possible native value.

Existing ingame family validation and independent source review with
remediation were retained. Nine focused LuaJIT integration cases and the
standalone base/expanded tests support this release. An earlier attended
75-second-per-profile A/B on a prior revision observed 144.49 vs 146.78
mean displayed FPS (baseline vs expanded). One comparison does not establish
a general performance effect. The final build's new FPS capture did not
run because of measurement-tool errors; no final-build FPS or soak claim
is made. Other game versions, arbitrary dependency combinations and
non-Windows systems are outside the tested scope. No acquisition causality,
exact weapon-wall binding or universal consumer/advice guarantee.

### v1.1.0 focused renewal validation

Version 1.1.0 retains the three exact v1.0.0 native reader modules, the
reference readers, the wire schema and RedSocket dependency. Only init.lua
and the disabled configuration template change at runtime. The renewal
algorithm reuses earlier, scoped current-read work; the new option and
validation make that behavior explicitly opt-in for public consumers.

Ten focused synthetic LuaJIT tests against the exact candidate Lua and
published CET wrappers passed: six retained renewal cases and four additional
checks for configuration refusal, unchanged behavior with the option off
or omitted, genuine native reads and the optional Journal contract.
Cases include unchanged samples, delayed updates without bursts, failed
reads, menus, combat, loading, new native generations and TCP reconnect.
A focused existing receiver crosscheck accepted 219 distinct observations
across two synthetic TCP epochs (five cases including the heartbeat control,
with and without synthetic peer witnesses). The exact public expanded reader
also accepted 77 native rows, three opened and closed generations, no reported
loss or rejection. These are offline/synthetic results, not a new native
gameplay, performance, or end-to-end consumer acceptance claim.

Earlier v1.0.0 physical and historical performance evidence is retained
for the unchanged components and prior tested revisions; v1.1.0 does not
claim that its changed init.lua has been physically qualified. Actual
renewal intervals and frame-time in a real session remain unmeasured.
Consumers must enforce their own freshness and lifecycle gates; if their
budget is exceeded they must fail closed, not extend the budget because
renewal is enabled. No new game version or dependency support is claimed.

## Verify and reproduce

The source ZIP contains canonical editable Lua, the Python reference
receiver, expanded reader, tests, documentation and a standard-library packer. The source and
mod manifests pin file hashes, the runtime tree and the four Lua file hashes.
This repository's main-branch README may receive documentation-only updates
after a release. For exact verification and reproduction, use the canonical
source ZIP from the matching release or its frozen version tag, not a later
main-branch checkout. Repository-only branding assets are not part of the
canonical source or mod manifest.
From the extracted source root:

- `python -B examples/test_receiver.py` — base synthetic tests.
- `python -B examples/test_expanded_reader.py` — expanded synthetic tests.
- `python -B tools/pack.py` — verify exact release source.
- `python -B tools/pack.py --output path/to/new-mod.zip` — reproduce
  the exact mod-layout ZIP (output must not already exist).

The packer rejects changed/noncanonical bytes rather than silently fixing
them. Modified source requires its own manifest/version. GitHub-generated
ZIPs have different archive metadata; compare the provided release ZIP
checksums. This is not a cryptographic signature or malware certification.

## Independent expanded reader

The expanded profile emits the documented local structured stream. The source archive includes examples/expanded_reader.py and examples/expanded_contract.py, using the original native validation/replay and stash reassembly, with no private cache or assistant dependency. Read a complete local JSONL capture with python examples/expanded_reader.py capture.jsonl; use --format cet for an explicit completed CET log. Aggregate output only; no network or writes. The importable ExpandedReader.accept / accept_json API returns validated rows. Do not interpret an offline capture as current process identity or fresh live facts. Reference offers are distinct from missing references or resolved metadata. A closed stream is not proof of all field semantics; incomplete snapshots are separately counted.

The reader reports explicit gaps and interrupted snapshots separately. Keep each completed capture in its own chronological scope; do not concatenate rotated or unrelated logs and treat them as a continuous live session. CET may rotate logs; preserve files locally if you need later reconciliation. See PROTOCOL.md for limits.

## License and acknowledgments

MIT for our original code and documentation; see [LICENSE](LICENSE).
Third-party dependencies are installed separately and retain their own
licenses. See [THIRD_PARTY.md](THIRD_PARTY.md) for the pinned dependency
inventory, scope and references.

Our sincere thanks to Louis Poirier (rayshader), yamashi and the CET
community, Octavian Dima and RED4ext/SDK contributors, jac3km4 and the
redscript team, NativeDB, Pavel Siberx and the RedLib/cet-kit community,
Christopher Kohlhoff and Asio, Daniil Goncharov and nameof, the AMD D3D12
Memory Allocator contributors, rxi, Python, LuaJIT, Lupa, Microsoft,
CD Projekt Red and the wider Cyberpunk modding community. Their work made
this independent project possible. No affiliation or endorsement is implied.

Development and documentation involved substantial generative AI assistance
under human-led design, review and testing. This mod is the result of months
of sustained human effort, careful engineering and close supervision
throughout the development process. Its maintainer defined the requirements
and scope, guided the technical decisions, reviewed the work at each stage,
carried out hands-on in-game tests, assessed the evidence, and made the final
acceptance decisions.

AI was a valuable collaborator in implementation, analysis and documentation,
not a substitute for that human responsibility. DeepBide-Telemetry was not
created from a single prompt: it grew through repeated investigation,
iteration, correction and verification until the result met the intended
requirements within the documented scope.

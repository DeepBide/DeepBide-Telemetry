# DeepBide-Telemetry for Cyberpunk 2077

**v0.1.0-rc.1 — pre-release · MIT · Windows x64**

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

The expanded local diagnostic profile and optional Journal/target-live
extensions are **experimental and not qualified in this release pairing**.
Select baseline and keep both optional extensions disabled for the tested
configuration. Expanded rows are separate local CET logs, not additional
TCP observations. This mod does not play the game, write saves, give advice
or display a HUD.

## Requirements — exact tested combination

| Component | Version |
| --- | --- |
| Cyberpunk 2077, Windows x64 | 2.5 (file version 3.0.88.46235) |
| [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks/releases/tag/v1.38.1) | 1.38.1 |
| [RED4ext](https://github.com/WopsS/RED4ext/releases/tag/v1.31.1) | 1.31.1 |
| [redscript](https://github.com/jac3km4/redscript/releases/tag/v0.5.32) | 0.5.32 |
| [DeepBide-RedSocket](https://github.com/DeepBide/DeepBide-RedSocket/releases/tag/v0.5.2-rc.3) | 0.5.2-rc.3 |
| [Microsoft Visual C++ v14 x64 runtime](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) | compatible runtime for the transport |
| [Python](https://www.python.org/) | 3.11+ only for the optional example and packer |

Install dependencies separately. This release does not bundle them.
Use the public RC3 transport mod ZIP (SHA-256
e788af8a3d440b50df6551bb0d777d77268a91c5f0d105623ab42da08d35d297).
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
   native_candidate_profile "baseline", journal_verification_0_1 false,
   target_live_contract_0_1 false and the supplied timing defaults. Set
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
The expanded diagnostic profile writes additional CANDIDATE_JSON rows to
local CET logs and may expose detailed gameplay information. Do not publish
raw logs, configs, identifiers, saves, screenshots or game data. Do not
interpret a heartbeat as proof of fresh world state. UNKNOWN/UNAVAILABLE
are not ABSENT. The producer has no built-in remote analytics service,
updater or game-control command interface.

## Evidence and limitations

On 26 November 2026, the exact four Lua files in this release were tested
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

Nine focused synthetic LuaJIT integration cases with the actual public CET
wrapper passed, including same-epoch loading recovery and ownership/refusal
handling. The example's standalone synthetic suite is included. Advanced
native reads, full gameplay coverage, extended soak, comparative frame-time,
arbitrary dependencies, other game versions and other operating systems
remain unqualified. No acquisition causality, exact weapon-wall binding,
or universal consumer/advice guarantee.

## Verify and reproduce

The source ZIP contains canonical editable Lua, the Python reference
receiver/tests, documentation and a standard-library packer. The source and
mod manifests pin file hashes, the runtime tree and the four Lua file hashes.
From the extracted source root:

- `python -B examples/test_receiver.py` — independent synthetic tests.
- `python -B tools/pack.py` — verify exact release source.
- `python -B tools/pack.py --output path/to/new-mod.zip` — reproduce
  the exact mod-layout ZIP (output must not already exist).

The packer rejects changed/noncanonical bytes rather than silently fixing
them. Modified source requires its own manifest/version. GitHub-generated
ZIPs have different archive metadata; compare the provided release ZIP
checksums. This is not a cryptographic signature or malware certification.

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
under human-led design, review and testing.

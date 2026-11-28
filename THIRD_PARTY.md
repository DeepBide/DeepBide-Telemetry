# Third-party references, provenance and acknowledgments

Copyright (c) 2026 DeepBide, MIT: original Lua, configuration template,
independent Python example/tests, packaging tool and documentation. See
LICENSE. This notice is a scoped technical source-history review, not a
legal opinion or clearance of rights held by other parties.

## Separately installed dependencies

| Component | Exact tested/required version and use | License and original notice |
| --- | --- | --- |
| [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks/releases/tag/v1.38.1) | 1.38.1; Lua/RTTI/observer APIs | MIT, yamashi and contributors; official ZIP bin/x64/LICENSE and ThirdParty_LICENSES; its separately installed JSON module includes rxi's MIT notice |
| [RED4ext](https://github.com/WopsS/RED4ext/releases/tag/v1.31.1) | 1.31.1; native plugin loader | MIT, Octavian Dima and contributors; official ZIP red4ext/LICENSE.txt and THIRD_PARTY_LICENSES.txt |
| [redscript](https://github.com/jac3km4/redscript/releases/tag/v0.5.32) | 0.5.32; transport script toolchain | [MIT, jac3km4](https://github.com/jac3km4/redscript/blob/v0.5.32/LICENSE) |
| [DeepBide-RedSocket](https://github.com/DeepBide/DeepBide-RedSocket/releases/tag/v0.5.2) | 0.5.2 (0.5.2-rc.3 runtime build); exact CET wrapper API and native transport | [MIT, Louis Poirier; DeepBide modifications](https://github.com/DeepBide/DeepBide-RedSocket/blob/v0.5.2/LICENSE); original upstream RedSocket 0.5.0, commit 055420a7317cb6e318251ed168eefad10fb1ea5b |
| [Microsoft Visual C++ Redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) | compatible v14 x64 runtime for RedSocket; separately installed | Microsoft terms, not relicensed or bundled |
| [Python](https://www.python.org/) | 3.11+ (3.11.9 used for Windows packaging/tests); example and packaging only | [PSF License](https://docs.python.org/3.11/license.html) |

RedSocket's pinned transitive build inputs and full original notices are
documented in its exact [THIRD_PARTY.md](https://github.com/DeepBide/DeepBide-RedSocket/blob/v0.5.2/THIRD_PARTY.md):
RED4ext.SDK 0f5eba42a4cf3a1161ad3de0b4ed6f1901ec169e (MIT, including
its D3D12 Memory Allocator notice); RedLib
3fd71fee06834e748ea593166fb179c9c1b9191b (MIT, including nameof);
Asio 1.32.0, 03ae834edbace31a96157b89bf50e5ee464e5ef9
(Boost Software License 1.0). These are indirect external dependencies;
their source, DLLs, installers and original notices remain in their own
projects/distributions. None is bundled or copied into Telemetry.
Install official releases separately and retain their notices.

For testing, LuaJIT via Lupa 2.8 and Python were used in the lab; neither
is bundled, nor a new player installation requirement. No test-only
external package is required by the standalone source example/packer.

## Interface research, not incorporated implementations

The project uses native interface names and factual API observations.
Research consulted the [CET wiki](https://wiki.redmodding.org/cyber-engine-tweaks),
[NativeDB](https://github.com/rayshader/cp2077-nativedb),
[RED4ext docs](https://docs.red4ext.com/),
[redscript wiki](https://github.com/CDPR-Modding-Documentation/Redscript-Wiki)
and [cp2077-cet-kit](https://github.com/psiberx/cp2077-cet-kit) (MIT;
historical GameUI 1.2.3/1.1.7 references). The source history records
consultation of other inventory references for signatures only, and
excludes copying/adapting AGPL or unlicensed implementations.
Documentation/dump licensing is distinct from application licensing;
no license to their expressive content is asserted. No third-party
source files, RTTI dumps, game assets, game text datasets, captures,
databases or dependency binaries are distributed in these packages.
Preserve the original MIT notice for our work. Any future bundled
component or copied fragment requires its exact license and original
notices to be reviewed and included as applicable.

## Thanks

We sincerely thank Louis Poirier (rayshader), yamashi and CET contributors,
Octavian Dima and the RED4ext/SDK community, jac3km4 and the redscript
team, NativeDB contributors, Pavel Siberx and RedLib/cet-kit contributors,
Christopher Kohlhoff and Asio, Daniil Goncharov and nameof, AMD D3D12
Memory Allocator contributors, rxi, Python, LuaJIT, Lupa and Microsoft's
toolchain team. Thanks to CD Projekt Red and the wider modding community
for the game and its ecosystem. The game and all third-party material
remain the property of their respective rights holders. This independent
fan-made tool does not claim affiliation, endorsement or ownership
of those projects.

The independent expanded reader derives from our original native contract, replay, stash and reference-key code. Its optional CET rotation cursor and tests adapt our own original, verified internal follower; only Python's standard library is used. No external cache, game asset, additional third-party dependency or external code is included.


## World clock research references (development candidate)

Thanks to the REDmodding/NativeDB documentation and modding communities.
The following links informed API discovery only; the new reader and
validation are original DeepBide code, without importing third-party
implementation code or assets:

- [NativeDB gameTimeSystem](https://wiki.redmodding.org/nativedb-documentation/classes/gametimesystem)
- [REDnode ScriptGameInstance](https://edgemodders.github.io/REDnode/game/t/ScriptGameInstance.html)
- [CETBridge handlers, Y4rd13](https://github.com/Y4rd13/cyber-engine-tweak-mcp/blob/main/cet-mod/CETBridge/handlers.lua)
- [Equipment-EX, psiberx](https://github.com/psiberx/cp2077-equipment-ex/blob/master/scripts/OutfitSystem.reds)
- [SantaMuerte, SkyrimLL](https://github.com/SkyrimLL/Cyberpunk2077/blob/main/SantaMuerte/r6/scripts/SantaMuerte/SantaMuerte_Controllers.reds)

These are API references/independent usage examples, not a claim of
affiliation, permission to redistribute their code, or exact CP2.5
physical qualification.

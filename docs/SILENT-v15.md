# v15 — static shot bridge and experimental Silent Aim

## Required install

This version consists of TWO matching pieces:
1. The copy of the original IPA with a static bridge in blackrussia-client.
2. BRMenuInject.dylib built from workflow v15.

Build the dylib with Actions. Import the supplied v15 bridge IPA into Ksign,
add the NEW dylib, add your own server-connection dylib again if needed, then
re-sign the whole IPA (including nested frameworks) and install. The provided
copy is derived from the original uploaded IPA, so it does not already contain
the user's separate connection dylib or earlier injected menu. Do not inject a
second old copy of BRMenuInject. The original IPA remains unchanged.

The modified IPA's old signatures are invalid until re-signed. No certificate
or private signing key is included. Static executable code becomes part of the
re-signed application; there are no runtime executable-page writes, JIT pages,
VM protection changes, or anti-cheat bypasses in this implementation.

The v15 dylib still supports existing menu functions on the original IPA, but
Silent Aim then displays "requires the v15 bridge IPA" and does not redirect.

## Menu

New Aim tab, disabled by default:
- Silent Aim enable/disable; ordinary fire controls still trigger each shot.
- Chest or head point, from collected actor bounds. Bounds can be approximate.
- FOV 30–300 UIKit points, accounting for the v14 horizontal stretch.
- Circle display; default: only when a qualifying target exists.
- Green Shoot [ID] label above the chosen target. It denotes selection, not a
  confirmed server hit. The label and FOV circle use reused Core Animation layers.
- 0–100% probability to skip redirection for each eligible bullet. A skipped
  bullet follows its original direction and can still hit naturally. This is
  not a guaranteed physical miss probability.
- Exclusions by ID or exact nickname (case-insensitive), separated with commas,
  semicolons or whitespace. Add the current selected ID with one button.
- Always excludes own player, non-positive remote/physical HP, and native
  CPed state DYING=52 / DEAD=53. Extra server-specific wounded states which keep
  positive HP and ordinary native state are not independently identified.
- Shows callback, redirected and skipped counters for device diagnostics.

Only a streamed target, on-foot local shooter and supported firearm are
handled. Walls remain subject to the original game's collision processing.
No camera rotation, trigger automation, extra shots, extra damage, or synthetic
network packet sender is added. Server hit validation can reject local results.

## Static bridge

Exact original client SHA256:
85c7e83cb5c471a31a01f4acd3ba7bb194a14823cc23c4ba229eba42401076b6

Modified client SHA256:
9f562ee4c014790f7cf2735297f040d9b9fe81ea82ac68f3d1f724b0fc84cdd2

The parser verified __TEXT header/load commands end at file/RVA 0x1068 and
__text begins at 0x4000. Existing unused zero padding at 0x2000..0x23ff supplies
the code/string/manifest/trampoline. No segment/section sizes, fixups, symbol
indices or file offsets are shifted.

Queue writer 0xb06a00 originally starts with four PC-independent stack stores.
Its first instruction branches to 0x2000. The bridge saves argument registers,
FP arguments, frame/link registers and stack, calls the client's existing dlsym
stub (0x12556d8) with RTLD_DEFAULT and BRMenuQueueHook15, then restores arguments.
If the symbol exists, the fifth argument is the original trampoline at 0x2200;
otherwise the bridge jumps straight to that trampoline. The trampoline executes
the original four instructions and resumes at 0xb06a10.

The native callback revalidates the local shooter, remote ID/slot/ped pointers,
nickname, HP, native state, latest camera/FOV and target position at shot time.
It changes only the endpoint passed to the original queue writer, preserving
ray length. Both queued and synchronously processed projectiles receive the
same redirected endpoint. The original native queue/collision/hit processing
continues. VFX code elsewhere in the client may still use its original endpoint.

## Performance and lifetime

Actor publication shares the existing 10–30 Hz worker collection with ESP,
including when ESP drawing is off. Main-frame target selection uses at most 128
cached candidates and the current camera. The hook copies one selected actor
under a short separate lock and revalidates only that actor. No full player-pool
scan occurs per shot. Candidates expire after 300 ms. Configuration updates,
background/reset and actor mismatches clear or reject selection. Nickname reuse
and whitelist/configuration changes invalidate a pending redirection.

## Validation and limits

Passed locally:
- ARM64 bridge emulation, symbol present/absent and two image bases (ASLR),
  preserving argument/FP registers, link register and original stack prologue.
- Native radar/ground finder tests from v14 remain unchanged.
- Portable C++ tests of HP/dead states, FOV/stretch/behind-camera, exact probability
  thresholds and 10,000 direction/range-preserving endpoint cases.
- Native queue writer ABI: owner, weapon, original and redirected vectors reach
  the game's queue record (external definition/collision calls stubbed).
- Native death routine's early state guard recognizes 52/53.
- Swift grammar, shell/YAML syntax and exact embedded-source extraction.
- Every IPA entry's uncompressed bytes remain identical except the client binary;
  original IPA SHA256 rechecked unchanged.

NOT performed here: Xcode SDK compilation, real dyld resolution on iOS, actual
certificate signing, device launch, real collision/streaming, or server-accepted
hits. Actions must compile the dylib; device testing is required before calling
this fully working. No app entrypoint/network is executed by the isolated tests.

# Experimental local controls · v10

Scope: exact client UUID 855846c3-4f72-3770-b811-dd7fbe68b0db. These are implementations for device testing, not verified working cheats. No app was executed in the analysis environment.

## Evidence
- getLocalPlayerId at 0xa72654 reads *(base+0x340de18), then pool[0]. Getter 0x92d4c0 reads uint16 local[0]; getter 0x92d4c8 reads local+0x38 -> actual CPed.
- Position stored at CPed+0x38 (x/y), +0x40 (z) by function 0x9aab84. This function removes/re-adds the actor through 0x119130/0x1190cc, sets dirty byte +0x60, and resets internal state. Full effects require runtime validation.
- Physical.cpp routine 0x153400 accumulates force divided by scalar +0x1c8 into XYZ speed at +0x180/+0x184/+0x188.
- CPed+0x540 vehicle pointer inferred from callers 0x910034, 0x910278, 0x910488 and vehicle subtype access +0x430. Vehicle-stop action remains experimental.

## Implemented
- Local XYZ readout, persistent saved point, teleport XYZ and to streamed player ID. On-foot only; native teleport function called on main thread.
- High Hop sets vertical speed 0.18 × user power (1–5), on button press. This is an impulse, not a verified vanilla-jump multiplier.
- Vehicle stop writes zero to the shared physical linear speed vector. One-shot boost multiplies its horizontal components (1–3), capped at vector magnitude 3.0. This does not activate the game's nitro system or continuously scale driving speed.
- Vehicle unflip writes orthonormal right/forward/vertical axes of the shared placeable matrix at +0x8/+0x18/+0x28, retaining heading and position, and sets dirty byte +0x60. Inferred from shared matrix layout; on-device verification required.
- Mass multiplier 0.1–5 applies to the +0x1c8 scalar used by the physical impulse routine. Saves the original scalar once per matching actor, supports restore, attempts restore on background/uninstall. Old pointers are never restored after actor identity changes. Does not change global gravity. Multipliers are settings; effects are only applied on button press.
- AirBrake holds a position and zero speed, updating at max 20 Hz. Hold arrow buttons to move relative to camera horizontal rows; vertical motion follows world Z. Input clears on release/page switch/collapse. Disables on missing/changed ped, vehicle entry, long timer gap, background or uninstall. Native teleport invoked on stop to update world placement. Collisions are NOT disabled. Direct position writes require runtime validation, especially world sector updates during movement.
- Visual FOV circle, radius 30–300 screen points; no aim is connected.

## Guards
UUID and exact instruction anchors, finite values, XYZ limits, actor identity recheck, one-shot action cooldown, main-thread requirement for game actions. No code patching, protection changes, hooks or server/network modifications. Main-thread native control ticks may wait for the ESP collector lock.

## Validation
Isolated ARM64 synthetic fixtures: three teleport register/direct-store cases (engine calls stubbed), one local ped getter case, two physical force/speed arithmetic cases. This does not test spatial sectors, collisions, player states, server sync, or performance. iOS compilation/UI/device tests still required.

## Not implemented
Run/drive speedhack, independent NoClip, stamina, water walk/drive, waypoint/job/vehicle teleport, gravity editing; Silent Aim/triggerbot, visibility check, recoil/spread, fire-rate/ammo/reload/damage changes; repair, vehicle godmode, unlimited nitro, locks/keys, handling; player godmode, fall damage immunity, cuffs/tazer, respawn, invisibility. No fake switches for these features.


## v11 added local assists
- CPed health +0x4b0: damage arithmetic 0x9c388c and store 0x9c394c. Armour +0x4b8 participates in combined protection at 0x9c36d4. Manual HP/armour refill and optional ≥100 local maintenance (20 Hz). Dead actors (HP≤0) are not revived. Server rules may overwrite/reject local values; this is not guaranteed invincibility.
- CVehicle health +0x398: NetVehicle setter 0x943efc, stock initializer writes 1000 at 0xaf776c, damage subtraction/store at 0xafc210/0xafc214. Manual and automatic ≥1000 HP restore for non-destroyed vehicles. Does not repair body panels, reset all fire/damage state, fix the engine or prevent instant destruction.
- Experimental stamina candidate: CPed +0x880 current, +0x884 maximum, recovery at 0x9d2a74..0x9d2ad4, max growth at 0x9ccf50..0x9ccf6c. Optional current-to-max refill with finite/range guards. Stamina meaning is inferred from movement-state/recovery code and must be verified while sprinting; maximum is never changed.
- Dash sets a bounded horizontal velocity in camera-forward direction on button press. It is not a continuously applied run speedhack.
- Soft fall caps downward speed at -0.1, on foot. Does not guarantee fall-damage immunity.
- Auto-assists default off, stop in background/disconnect and follow saved user toggles on foreground. Additional instruction fingerprints guard HP/vehicle HP/stamina writes.
- Isolated synthetic damage arithmetic (2 cases) and candidate recovery arithmetic (2 cases) passed. Application not run; iOS compile/UI/device validation pending. User reported v10 controls working, but this does not validate v11 additions.

# v12 consolidated experimental batch

v12 includes v10/v11 controls and the frame-projected, layer-rendered ESP. No need to install v11 separately. User confirmed v10 controls; all v11/v12 changes still require iOS build and device validation.

## Added in this batch
- Ammo reserve refill to ≥999; manual magazine fill; optional reserve maintenance and magazine refill / ready-state transition. Only active firearm with WeaponInfo fireType==1 and validated capacity 1–1000.
- Experimental fire-delay divisor 1–5. Adjusts the current weapon next-shot timer once per observed deadline, rather than compounding every tick. Animation/server limits remain; no trigger input or shot-direction hook.
- NoClip while AirBrake is active: clears collision bit 0 at CPed+0x8c, preserves/restores original bits when stopped.
- Per-object gravity multiplier −2…3 for the ped or current vehicle, using CPhysical+0x170. Original scalar saved; repeated application is relative to original, not compounded. Restore button / background cleanup included.
- Local ped damage-protection bits and experimental fall-damage bit. These are local engine flags, not guaranteed server invincibility.
- Current network vehicle local damage gate at +0x382 bit 1. Original bit restored on disable, vehicle change and background, provided the network slot, wrapper, actor pointer and physical identifier still match.
- Teleport to loaded vehicle ID 0–1999, or nearest loaded vehicle within 5 km. On foot only, target position +2 Z, using the existing validated native teleport routine.
- Experimental body-repair request through NetVehicle routine 0x944034, with network-slot checks and automobile kind==0 / valid clump guards; HP refill follows. Unsupported/destroyed vehicles are rejected. Repair outcome must be checked on device.
- Emergency button disables gameplay switches, stops AirBrake and attempts restoration of recorded gravity, mass and flags for still-valid objects. Consumable HP/ammo refills are not rolled back.

## Static evidence
- CPed+0x5b0 -> inventory/brain. 0x996968 calls 0x9d63f8: selected uint8 index at +0x44, vector [begin,end) at +0x48/+0x50, 32-byte entries.
- Active Weapon: type uint8 +0, state uint32 +4, clip int32 +8, reserve int32 +0xc, deadline uint32 +0x10. Shot code 0xb0bb24..0xb0bb40 decrements both counters, preserving zero.
- WeaponInfo hash at base+0x3537cb8: buckets pointer +0, count +8; key byte at node+0, info node+8, next node+0x210. Bounded traversal, no game lookup function invoked. fireType info+0x20, magazine capacity +0x34. Native reload completion at 0xb11454..0xb11464 writes state=0 and clip=min(reserve,capacity).
- Weapon update 0xb11198 compares current game time (base+0x2f348e0) with weapon+0x10 before clearing firing state.
- CPhysical constructor 0x151890..0x151898 initializes +0x170 to float 0.008. Gravity arithmetic at 0x152d28..0x152d40 updates vertical velocity by subtracting gravity × timestep.
- Collision pair gate 0x15c4d0..0x15c4d4 rejects actors with bit 0 of +0x8c cleared.
- Ped damage code 0x9c3460 checks flag bit 21; 0x9c352c/0x9c3624 check +0x8e bit 3; 0x9c3694 checks +0x8d bit 1; 0x9c3740 checks +0x8e bit 2. This batch preserves originals while setting +0x8e mask 0x3e and/or +0x8d mask 0x02.
- Vehicle damage 0xafc084 skips damage when +0x382 bit 1 is clear. Vehicle pool getter 0x972020 validates ID≤1999 and reads pool[id]. Global base+0x340de20 -> pool; wrapper[0] -> vehicle; vehicle+0x434 -> ID.
- NetVehicle repair 0x944034 conditionally calls automobile repair 0xad37a8 and marks pending repair in the network vehicle data. Automobile routine resets the damage manager at +0x740 and restores model components.

## Verification and limits
Swift syntax grammar parsing, workflow YAML, shell syntax and exact embedded-source extraction passed. Isolated ARM64 synthetic checks: active-weapon getter (1), collision-chain WeaponInfo lookup (1), ammo depletion (3), reload completion (2), gravity (4), collision gate (2), vehicle damage gate (2), vehicle pool bounds (2). Existing projection/camera and control-ABI checks also pass. This is not an iOS compilation or a gameplay test.

No app entrypoint, networking, live game or initializer was executed in the analysis environment. No code-page patches or anti-cheat bypass. Local memory writes and a few validated native game calls are performed only by the injected module on the user's device.

Still absent: Silent Aim, Triggerbot, shot-direction changes, recoil/spread edits, damage multiplier, continuous run/drive speedhack, water walk/drive, unlimited nitro, locks/keys, drift handling, cuffs/tazer bypass, respawn/invisibility and map/job teleports. No fake switches for these.

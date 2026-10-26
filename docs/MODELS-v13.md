# v13 local models and actual weapon selection

User confirmed v12 controls work. This is new experimental code: no v13 iOS build/device validation yet. No app entrypoint/initializer/network was run in the analysis environment.

## UI
- Я: skin ID, restore original skin.
- Оруж.: weapon ID and ammo, issue/select active firearm. Normal game fire controls are used.
- Авто: change current car model, restore original model. Driver only, standard automobile class, no passengers.
- Settings: cancel a pending model operation. Model loading status/results appear in the shared status label.

Models must exist in this exact client's registered catalog/resource table. Missing, wrong-kind or unsupported IDs are rejected. Only one model job is pending at a time, with a 20-second limit; pending jobs cancel on background or actor change. Asset streaming is requested through the normal client function; no busy waits or code-page changes.

## Evidence
Catalog getter 0x10fa00 filters type 7 (ped), 0xa2938 filters type 6 (vehicle). Shared registered-bit map at +0x19b22a8 and pointer chunks at +0x19b2290 use 1024 entries per chunk. VehicleModelInfo+0x5c is the class used by the factory 0xb01338; class 0 selects automobile.
Streaming slots have a separate bit map at +0x2ed3c30 and chunks at +0x2ed3c18: 512 entries per chunk, 96 bytes each, readiness byte +0x48. Native accessor 0x112b04 confirms this layout. Stream request 0x10a084 copies a 24-byte variant key (uint64 kind=0, uint32 model ID at +8, remaining bytes zero) and is called with flags=8, matching request processing at 0x92aa90.

Skin: invoke the existing ScrSetPlayerSkin receive-side handler 0x951400 with a local 64-bit payload [uint32 own player ID, uint32 skin ID], padded to 12 bytes. RPC header input pointer +0, bit count +8. The handler performs its normal loading/custom-skin checks; rendering model is then verified through CPed+0x98. This is a local handler call, not a new network packet.

Weapon: validated WeaponInfo/fireType=1, render model at +0xdc and configured inventory-slot compatibility. Native give wrapper 0x9d6124 chooses an existing/compatible slot and calls 0x9d6e94, which initializes a real Weapon via 0xb0b428. Native selection 0x9d6aa8 sets the active slot and attaches the render model. Thus this is actual local client weapon state, not only a mesh in the hand. Only supported firearms are enabled; server inventory, accepted damage and weapon permissions are not granted.

Car: require an existing network vehicle, own driver, no passengers, current class +0x430==0 and target VehicleModelInfo class +0x5c==0. Check automobile model/delete virtual slots against 0xabfdc8 / 0xaf7cc8. Remove the same actor from world, release old render objects, call its native model setter, restore pose and re-add to world. Keeps current object/network ID and old handling; this is a local model substitution, not a new server vehicle. Restore model ID is recorded for that validated vehicle.

Original skin/car models remain until their explicit restore buttons or normal server/streaming updates. The generic gameplay reset cancels pending jobs but does not automatically revert already-applied appearances.

## Validation
Swift syntax grammar, workflow YAML, shell and embedded-byte extraction checked. Isolated ARM64 fixtures: catalog kind checks 6, resource slot lookup 3, model-key copy ABI 1, native give-wrapper argument/slot ABI 2 (inner game calls stubbed), skin RPC reader/header payload ABI 1 (reader calls stubbed), static automobile vtable anchors 2. These do not validate actual asset loading, rendering, firing, vehicle parts, or server behavior.

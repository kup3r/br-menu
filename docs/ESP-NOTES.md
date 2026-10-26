# ESP v7: evidence and limits

Target: blackrussia-client 1.99.0 build matching UUID 855846c3-4f72-3770-b811-dd7fbe68b0db, arm64. Full application entrypoint was not run. Handoff Mach-O supplied by the user was used for static analysis.

## Static evidence

References from code to PlayerPool.cpp lead to a slot-allocation path and a bounded pointer array. The name-tag rendering path enumerates 1504 slots, formats the name and ID with `%s [%d]`, reads two scalar status fields, fetches bone 5, then calls projection and draws tag/status elements. The remote object's name begins at +0x18, ID getter reads +0x4a, and two getters read float fields +0x148/+0x14c. These feed the status bars in the name-tag renderer; mapping to HP/armor needs confirmation on the device.

The RemotePlayer sync path and initializer were inspected. The implementation uses skeleton matrix positions via the same hierarchy lookup used by the tag renderer rather than treating a guessed sync vector as current position. It computes a screen bounding rectangle from valid projected bones, so pose/animation can change box proportions. No skeletal edges are drawn.

The original projection transforms a world point by camera matrix rows at 0x22892a0+0x900, divides by transformed Z and scales by viewport width/height. Normalized screen coordinates in this module omit the final viewport scale, which Swift applies using overlay bounds. A different in-game viewport/letterboxing can require alignment adjustment.

## Independent arithmetic checks

Using Unicorn, isolated ARM64 projection instructions were evaluated on 128 controlled camera/point fixtures. Maximum normalized error against the reconstructed formula: 1.173792905095894e-07. Two synthetic player-slot boundary checks and two scalar getter checks also passed. This validates selected arithmetic and memory-access behavior on synthetic inputs, not a full runtime object model. The application, its initializer and server connection were not executed in these checks.

## Runtime behavior

The ESP provider performs read-only vm_read_overwrite calls in the current process. It does not call engine methods, change game memory, bypass visibility checks in game code, or send network requests. A module UUID check and two instruction fingerprints gate version-specific reads. Invalid/missing pointers, nonfinite coordinates and impossible sizes are skipped. These checks reduce invalid reads but are not a proof of compatibility. There are no actors available beyond what the client currently streams.

ESP is off by default. Enable it under Визуал → ESP · эксперимент. Labels show source status under Обзор. Options: box, name/ID, HP bar, armor, camera distance and range 25–500. Range uses camera distance, not local-player distance. Bars assume a display maximum of 100 and clamp fill; numeric text preserves the sampled value. The read cadence is 10 Hz. At most 128 projected actors are returned per sample. Pool entries are checked again before emitting the sample to reduce slot-reuse races; this is not an atomic game-state snapshot.

Game FPS remains the GLK frame-update counter. Own-player XYZ remains disconnected. The new provider does not implement aim assistance.

## Validation still required

v7 has not been compiled with Xcode in this environment. Actions must compile ObjC++, import its header into Swift, link the dylib and run the menu test. The existing UI test validates demo UI interactions; the demo has no blackrussia-client module and cannot validate ESP entities. On-device tests must confirm the source status, label/HP correctness, box alignment, camera modes, rotations, transitions, performance and the 128-actor cap. Use a copy of the app and replace the previous injected dylib; do not load both versions.


Correction v8: iOS SDK 18.5 rejects mach/mach_vm.h. The reader now uses vm_read_overwrite declared by mach/vm_map.h, vm_address_t and vm_size_t, with a compile-time 64-bit target check. Other provider logic is unchanged. v8 still requires an Actions build and device validation.


## v9 performance / render flags
- Collect snapshots on a serial utility queue. Only one task in flight per menu; stale generations are discarded after disable/uninstall. UIKit mutations stay on main. Native collection is serialized across scenes.
- Enable -O2 for ObjC++; merge adjacent ped/clump/hierarchy reads. Reject out-of-range actors before projecting all bones.
- Remove per-label shadow blur and constrain label width.
- New default-on espWalls option skips remote bit 0 and ped bit 2 render filters. No depth/occlusion test is performed by the overlay. Still requires a streamed ped, valid clump and bone hierarchy. Offscreen bone transforms may be stale; players absent from client memory cannot be displayed. No guarantee of correct behind-wall positions until device testing.
- No internal game routines called or game memory written. Performance improvement is unmeasured until on-device comparison.


## v11: frame projection, independent locks and GPU layers
- Collector publishes world-space bounds anchored to the current CPed root (+0x38), rather than projected screen boxes. Cached actor-relative bounds survive unchanged/cull-stopped bone matrices; missing skeletons use an approximate 0.7×0.7×1.85 body box. These boxes can differ from the exact animated silhouette.
- Collection runs at configurable 10–30 Hz (20 default) on a serial user-initiated queue, with one request in flight. Requests are scheduled from CADisplayLink; there is no timer or accumulated queue of snapshots.
- Every display tick independently reads the current 64-byte camera matrix. The camera getter never acquires the collector or controls locks. Controls and metadata no longer share one lock; status has a separate short mutex.
- UI projects the eight world-box corners with the fresh camera each frame. No lerp/spring animation is applied to boxes. Snapshots older than 300 ms since collection START are hidden.
- Boxes and HP bars are CAShapeLayers; labels reuse CATextLayers and update text only when changed. Implicit layer animations are disabled explicitly. No full-screen UIKit raster redraw every display tick; draw() now only handles static guides/crosshair/FOV.
- Main-frame dictionaries/label layout were removed. Distance/actor position still follows the collection cadence. Bone caches and approximate bodies require device validation, including near-plane cases.
- 60 synthetic camera frames ×8 corners were checked against the isolated ARM64 projection routine; max normalized error <5e-8. This is formula validation, not an iOS build or device performance test.

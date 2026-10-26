# v14 — waypoint, car diagnostics, experimental horizontal stretch

This is a partial implementation of the latest request. All v13 controls remain.

## Automobile appearance

Removed the unsupported requirement that VehicleModelInfo +0x28 contain a pointer.
The native RW bundle getter at 0x91c284 reads +0x48; +0x28 was never established
as a mandatory loaded mesh pointer. Keep the +0x48 bundle check, the model kind,
exact standard-automobile vtable functions, driver/passenger checks, native world
remove/add and native RW deletion/model setter. Removed the unnecessary model ID
invalidation immediately before the native setter (the setter writes the ID).

Failure messages now distinguish missing bundle, changed vehicle, driver seat,
unsupported vtable class, and instruction verification. Unsupported derived
classes remain rejected. No claim is made that the reported device failure is
fixed: its precise status/vehicle/model were not supplied and v14 has not run on
a device. Existing handling is retained; this is local visual replacement only.

## Teleport to the map's user waypoint

Movement tab: set a waypoint in the map, close the map, then press the waypoint
teleport button. It works on foot. No automatic teleport on every map click.

Verified native writer 0x101a3c:
- handle: client +0x19cbb98; low16 trace index <75, high16 generation
- radar table: +0x2ed2124, stride 0x38
- +4 coordinate marker type 4; +0x24 generation; +0x27 active=1
- +0x34 sprite 41; position +0x0c

Reads the generation-tagged trace, not a scan for arbitrary coordinates.
Ground finder 0x11f89c uses float x/y/z and a success byte pointer. It descends
from z=1000 with the native collision call. For already loaded ground, teleport
to height+1. For unloaded ground, first move above the destination at z=500,
hold physical position and zero velocity while polling, then move to height+1.
Timeout after 8 seconds or explicit cancellation attempts return to the original
point. Background/reset cancels and attempts the same return. Actor/vehicle
changes cancel without writing the former actor. Horizontal correction >10
units aborts instead of fighting the host/server's position.

The original native ped teleport function is used. No waypoint network RPC is
constructed or invoked. Distant terrain streaming and server corrections still
require device testing. This is a local command, not guaranteed server-authorized
teleportation. The ground finder can find a roof; interiors and terrain beyond
the tested ray's height range are not specially supported.

## Horizontal stretch experiment

Settings: ×1.00–×1.60 and reset. Applies a horizontal UIKit transform to the
full-screen active GLKViewController surface only, retaining/restoring its prior
transform. Edges are cropped. This does not change the engine's aspect ratio,
3D projection or render resolution; it is an explicitly labeled image-scale
experiment. ESP's screen-space X bounds use the same center-based scale.
Unavailable outside a suitable full-screen GLK surface. Restored on background,
uninstall and reset. Changes to an app's view hierarchy need device testing.

## Silent aim and related settings

NOT IMPLEMENTED: shot redirection, miss probability, Shoot indicator driven by
successful redirection, dying-state exclusion for aim, whitelist for aim.
The existing FOV circle remains a guide and does not change hits. No controls
are presented as working when their shot redirection path is absent.

Static investigation identified CWeapon::FireBullet-like paths around 0xb0bbf4,
projectile queue writer 0xb06a00 and collision update 0xb06af4. Some projectiles
are processed synchronously inside the writer; polling that queue from the menu
would miss short-range shots. No queue-polling implementation is shipped as
"working silent aim". A verified shot interception/extension point is still
missing. No executable page patching or dynamic code generation is added.

## Validation

Isolated native ARM64 radar setup: three synthetic trace indices; check type,
active byte, sprite, XYZ and generation-tagged handle. Native ground-finder ABI:
success and miss cases with the external collision routine stubbed. No game
entrypoint or network event path is executed. Swift grammar, YAML, shell syntax,
and exact embedded source extraction checked locally. Xcode compilation/UI
tests run only in GitHub Actions, and v14 is not device-verified.

# BR Menu v17

Native iOS menu for the exact supplied com.blackhub.bronline 1.99.0 build 1102.
This repository now keeps the source files directly: Actions no longer unpacks
an opaque embedded source archive over them.

## v17 changes

- FOV drawing is independent of the shot bridge. An unavailable backend displays
  an amber dashed circle and a concrete error. A target preview is labeled
  `Цель`; green `Shoot` denotes a selected target with the bridge available.
- Aim diagnostics distinguish missing/mismatched patched IPA, duplicate menu
  dylib, dead local actor, unsupported weapon/range, stale/empty actor data, and
  a bridge which has not yet been called. Counters are not server-hit counters.
- Aspect scaling changes the engine's projection ratio through a second static
  bridge. No transform is applied to the app window or HUD. A NEW v17-patched
  IPA is required for this projection feature; v15 only has the shot bridge.
- Existing ESP, waypoint teleport, native controls, skin/weapon/car appearance
  actions and ID/nickname exclusions remain. Existing limits still apply.

## Build and install

Actions builds unsigned `BRMenuInject.dylib`, checks its exported hooks, runs the
portable production-core tests and builds/tests the UIKit demo with Xcode.
Use the matching v17 IPA package, then fully re-sign it in Ksign. The prepared
package already includes the menu dylib and its load command. Add your separate
server-connection dylib if your private server needs it; remove duplicate old
menu dylibs. The original uploaded IPA is never modified in place.

To prepare a package with a locally available original IPA after compiling:

```sh
python3 scripts/prepare_ipa.py original.ipa dist/BRMenuInject.dylib BRMenu-v17-unsigned.ipa
```

The packager checks the exact client SHA256, unused executable header padding,
original instructions and the embedded dylib. It adds bridges without shifting
Mach-O sections and adds a verified load command to BrBase. Existing signatures
are invalid until the whole package and nested binaries are re-signed.

## Invisible

Not implemented client-side as a fake toggle. Visibility to other players
requires support from the actual private-server code/protocol. This repository
contains only the menu and no server implementation. The relevant server source
or repository is needed to implement and validate this request.

## Verification scope

Native bridge emulation and portable math/selector tests use synthetic inputs;
no game entrypoint or network is run by them. Passing Actions proves SDK build
and UIKit demo tests, not installation, real-game behavior or server-accepted
hits. Device checks are still required for projection, shot redirection and
model replacement.

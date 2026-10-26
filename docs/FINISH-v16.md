# v16 validation and diagnostics

Use the already supplied v15 bridge IPA with a dylib built from v16. The bridge
ABI and exported symbol name BRMenuQueueHook15 are unchanged; no new IPA download
or binary patch is needed for this version.

Changes:
- The actual production target selector is now portable C++ and tested for own
  player, dead/dying state, HP, ID/name exclusion flag, FOV/stretch, range,
  invalid values and deterministic ties.
- Native selection and shot-time checks also reject a dead/dying local shooter.
- The runtime verifies the bridge manifest, saved prologue, resume branch and
  export name. dlsym must resolve to this copy of the dylib's hook, which helps
  identify a hidden or duplicated library.
- The menu distinguishes bridge availability from an observed callback. Before
  the first callback it asks for a normal shot; Shoot is shown after the callback
  has actually been observed. Counters count hook invocations/redirections, not
  server hits.
- Actions first compiles and runs the production C++ selector/ray tests. The
  existing dylib build, export check and simulator UI checks remain in the job.

Locally passed: C++ selection tests; 10,000 ray direction/range invariants; exact
skip thresholds; Objective-C++ parsing with libclang and test-only Foundation /
Mach declarations; Swift grammar; YAML/shell validation and embedded source
round-trip. The mock declarations are not included in the deliverable and do
not substitute for Apple SDK type checking, linking or running on iOS.

GitHub access check for kup3r/br-menu returned 404 and its repository list was
empty. Consequently Actions was not started from this chat. Apple SDK build,
real dyld loading, certificate signing, device behavior and server hit acceptance
remain unverified. Existing client-specific limits from SILENT-v15.md apply.

# v18: controls and navigation

The menu now opens a two-column category home with a persistent Back button and
large touch targets. Page changes release held flight controls. Existing pages,
preferences, floating button, drag behavior and passthrough touches remain.

Added for the client UUID 855846c3-4f72-3770-b811-dd7fbe68b0db only:

- Independent on-foot No Collision via CPhysical collision flag +8c bit 0.
- No Spread via active bullet WeaponInfo random-axis amplitudes +44/+48/+4c.
  These definitions are shared locally, so the same weapon type used by other
  actors in this client may also lose dispersion. Registry identity is checked
  before restoration. No network ownership or damage permissions change.
- NoAnim pauses local RenderWare association playback. Fast Anim changes speed
  1–4x. NoAnim takes precedence. Only the current local clump is traversed, with
  a 64-node limit, cycle detection and association identity checks. Removed nodes
  are never restored through stale pointers. Death releases animation modifiers.
  These controls do not cancel server tasks or promise server animation skips.
- Bypass Lock uses the existing NetVehicle setter 944760 (door state +3bc=1).
  CVehicle's gate afc718 rejects locked enum states 2/4/5/7, and accepts 1.
  Targets the current vehicle or the nearest loaded vehicle within 8 metres.
- Drive Without Key calls the native engine setter 94477c, which sets engine-on
  bit 2 and clears engine-off bit 30 of +380. Requires the local driver and a
  non-destroyed engine. Does not grant server keys; server updates may override it.
- Suicide calls 99d4c0 with the same ABI as the native fatal-damage caller at
  9c39f8: ped, cause 202, float 4, float 0. Requires a loaded living on-foot actor.
  Automatic HP/protection and animation pause are disabled before the action.
- Fast Respawn calls the native local-player spawn routine 92cce8 only in DEAD
  state, with existing valid spawn information (+1d4, position +1ac). It does not
  invent a spawn position or guarantee acceptance by the server.
- Existing Rapid Fire is clearly named and displays its multiplier.

No Recoil is **not connected**: the independent camera recoil handler has not
been established. Clearing spread/inaccuracy is not presented as camera recoil.

All new native actions require the exact UUID, current local-player identity,
validated registry ownership and instruction anchors. No runtime executable-page
patching is added. Existing v17 patched IPA accepts this dylib; no additional
static client bridge is needed for these controls. Re-sign the modified copy.

Validation: portable tests compile the production backup/restore functions against
a sparse memory fixture. They check spread restoration, stale registry handling,
animation pause precedence, no repeated multiplier accumulation, external native
speed changes, death release and cyclic list termination. CI also builds with the
iPhone SDK and exercises the category navigation and controls in the simulator.
These checks do not establish behavior on an actual game server or phone.

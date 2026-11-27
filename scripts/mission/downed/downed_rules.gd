class_name DownedRules
extends RefCounted
## Downed, revive, respawn (docs/design/pacing-director.md "Downed, revive, respawn"; user decision 2026-11-24): every
## number in one place. PlayerTarget runs the state on the OWNER's machine (downed -> revived in place, or downed -> held
## SPACE -> redeploying -> respawned at a deck arrival point); DownedCrew (scripts/mission/downed/downed_crew.gd) is the scene's
## side (who can revive, the call for help, the HUD, the beacon, where a respawn lands). Pure constants and helpers: no
## state, nothing synced.
##
##   downed       a core component destroyed: stays where it fell, no movement, no weapons, takes no damage, enemies
##                drop it (PlayerTarget.is_hittable() is false). No automatic respawn.
##   revive       a standing crewmate's repair drone on duty, within its radius (15 m of the launcher), beams the wreck:
##                REVIVE_TIME s of beam stands it up IN PLACE with REVIVE_STRUCTURE (destroyed components rebuilt at 30 %,
##                every other one at least 30 %), heat 0, shutdown cleared, ammo unchanged, REVIVE_INVULN s of
##                invulnerability. Not a death. The beam stopping drains the progress over REVIVE_DECAY s (a full bar).
##                Cost: the drone's own (one of its charges launched it; the revive takes no extra charge and no life).
##   respawn      the downed pilot holds the `respawn` action (SPACE) for RESPAWN_HOLD s (release resets), then is
##                REDEPLOYING for RESPAWN_PENALTY s (out of the fight, no deck), then stands at the arrival point of the
##                deck the crew's lead pilot is on with RESPAWN_STRUCTURE on every component, heat 0, ammo unchanged. A death.
##   bots         a host-owned bot cannot hold a key: it waits BOT_REVIVE_WAIT s when a standing crewmate can revive it
##                (BOT_ALONE_WAIT s otherwise), then takes the respawn path (same penalty, same structure). It keeps waiting
##                while a revive is in progress.

const REVIVE_TIME := 4.0          ## s of continuous drone beam that stands a downed mech up in place
const REVIVE_DECAY := 2.0         ## s for a full revive bar to drain once the beam stops (progress decays, not resets)
const REVIVE_STRUCTURE := 0.3     ## share of max HP: destroyed components rebuilt at it, every other at least it
const REVIVE_INVULN := 2.0        ## s of no damage after a revive (not killed while standing up)
const RESPAWN_HOLD := 3.0         ## s the downed pilot holds the respawn key
const RESPAWN_PENALTY := 5.0      ## s redeploying (out of the fight) after the hold
const RESPAWN_STRUCTURE := 0.5    ## share of max HP every component has after a respawn (destroyed ones rebuilt too)
const BOT_REVIVE_WAIT := 8.0      ## s a downed bot waits for a revive when a standing crewmate can revive it
const BOT_ALONE_WAIT := 2.0       ## s a downed bot waits when nobody standing can revive it
## Respawn next to an ACTIVE defend / hold on the deck the pilot went down on (coordinator, 2026-11-24, from bot
## evidence: a relay died during the ~40 s walk back from the arrival point): a clear spot this far from the site,
## tried at the RESPAWN_NEAR_TRIES distances in order (75 m first, all within 60-90 m), 8 bearings each starting on the
## side of the deck's arrival point; out of the objective's zone, on clear ground (SiteFit.snap), preferring
## one with no live enemy within RESPAWN_ENEMY_CLEAR m.
const RESPAWN_NEAR_TRIES := [75.0, 60.0, 90.0]
const RESPAWN_ENEMY_CLEAR := 40.0  ## m: no live enemy this close to the respawn spot (when a candidate allows it)
const RESPAWN_ZONE_MARGIN := 10.0  ## m kept outside the objective's radius / zone
const RESPAWN_SNAP_REACH := 8.0    ## m a candidate may slide to clear ground
const RESPAWN_CLEAR_R := 4.0       ## m of clear ground round the spot (a mech is 4.4 m across)
const REVIVER := "repair_drone"   ## the equipment that revives (back mount)
const ACTION := "respawn"         ## the input action held to respawn (only has an effect while downed)
const KEY := KEY_SPACE            ## its default key (thrusters while standing: the action does nothing then)


## The `respawn` input action (default SPACE), added at runtime when the project's input map has none (the project
## file defines no actions: every other key is read directly).
static func ensure_input() -> void:
	if InputMap.has_action(ACTION):
		return
	InputMap.add_action(ACTION)
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY
	InputMap.action_add_event(ACTION, ev)


## The key's name for the HUD ("SPACE").
static func key_name() -> String:
	return OS.get_keycode_string(KEY).to_upper()


## Seconds a downed bot waits before it takes the respawn path.
static func bot_wait(reviver_available: bool) -> float:
	return BOT_REVIVE_WAIT if reviver_available else BOT_ALONE_WAIT


## Revive progress drained per second once the beam stops.
static func decay_rate() -> float:
	return REVIVE_TIME / maxf(REVIVE_DECAY, 1e-3)

class_name Net
## Authority classes for networked state, and the facade gameplay code asks (ported from cast's net.gd, cut down to
## what exists so far; docs/networking.md).
##
## Model: OWNER AUTHORITY (cast's option A). Each player's machine owns that player's mech and streams it; the host owns
## everything else (enemies, civilians, pickups, the mission). Cross-owner effects travel as messages: the victim decides
## about its own mech, the attacker's machine decides about host-owned targets. No anti-cheat (friends only).
##
## Every class with gameplay state will return `net_fields() -> {var name: Net.KIND}` covering EVERY script var, and
## test_net_contract fails when a var is missing or a name is stale. Gameplay code never sends anything itself: it asks
## `Net.is_host()`, `Net.online()`, `Net.crewed()` and talks to the `Session` autoload (NetSession).

enum {
	SPAWN,    ## Fixed when the thing is created (spawn event or the seed), never written after. Same everywhere, never streamed.
	OWNER,    ## The owner writes it; everyone else receives it (snapshot or event). Non-owners never write it.
	PRIVATE,  ## The owner's working state (AI timers, input buffers). Not replicated; non-owners must not use it for gameplay.
	LOCAL,    ## Every machine keeps its own: presentation, or a value recomputed from OWNER/SPAWN state and the shared clock.
}

const NAMES := {SPAWN: "SPAWN", OWNER: "OWNER", PRIVATE: "PRIVATE", LOCAL: "LOCAL"}


static func is_kind(v: Variant) -> bool:
	return v is int and NAMES.has(v)


## The Session autoload, or null (a bare script run without the autoloads).
static func session() -> NetSession:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Session") as NetSession
	return null


## True on the host, and offline (solo is hosting with nobody joining), so solo code paths never change.
static func is_host() -> bool:
	var s := session()
	return s == null or s.is_host()


## In a crew session (hosting or joined).
static func online() -> bool:
	var s := session()
	return s != null and s.online()


## In a crew session with someone else in it. A host alone in an online session is NOT crewed.
static func crewed() -> bool:
	var s := session()
	return s != null and s.online() and s.roster.size() > 1

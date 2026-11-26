class_name NetSession
extends Node
## Autoload "Session": the crew session. Ported from cast's net_session.gd (its M0: transports, hello handshake, crew
## roster, refusals with a reason, the session clock, telemetry, the link simulator, Steam invites), with cast's gameplay
## layers (shared run, seats, snapshots, world, objects, casts) left out until babamech has gameplay to sync. A crew is up
## to MAX_CREW (4) players. Gameplay code only ASKS (Net.is_host(), Session.online(), the roster); every send lives in
## scripts/net/.
##
## TRANSPORTS
##   STEAM: what ships. A Steam lobby (SteamLobby) plus SteamMultiplayerPeer (no_nagle) to the lobby owner.
##   ENET:  dev and tests. Plain UDP, so several instances (run.ps1 -Crew, the multi-process test harness) can play on
##          one machine with no Steam client.
## Both are the same MultiplayerAPI, so everything above this file is transport-agnostic.
##
## HANDSHAKE (all reliable events on NetWire, kinds "sys.*")
##   host -> joiner   sys.ask      {protocol, build}                   sent when the host sees the peer connect
##   joiner -> host   sys.hello    {protocol, build, name, head, chassis, accent, loadout, steam_id}
##   host -> joiner   sys.welcome  {seat, peer, entries, host_unix, link, friendly_fire}   or   sys.refuse {reason}
##   host -> all      sys.roster   {entries}                            after every join, leave and profile change
##   joiner -> host   sys.profile  {name, head, chassis, accent, loadout}   the player changed name / head / chassis / accent / loadout
##   host -> all      sys.link     {preset}                             the host changed the simulated link
##   host -> all      sys.crew_opts {friendly_fire}                     the host changed a crew option (also in sys.welcome)
##   host -> all      sys.bye      {reason}                             the host is leaving (closes once the crew has)
## The host speaks first, so it has always registered the peer before the joiner says anything. A refused joiner is told
## why ("Crew is full", "Different build") and dropped REFUSE_GRACE later; the transport admits a few more peers than
## MAX_CREW for that.
##
## BOTS (docs/design/hangar-bots.md): the host may seat AI pilots (add_bot / remove_bot / set_bot_skill, crew "lobby"
##   only). A bot's pilot id is NEGATIVE (-1..-3, its bot slot): never a peer id. Bots live in `bots` (pilot id -> entry
##   with "bot": true, "skill"), NOT in `roster`, so every transport path (sends, silence, kicks, telemetry, the load
##   barrier) only ever sees players; crew() lists both by seat, and sys.roster carries both (flagged). A bot runs on the
##   host's machine (machine_of(id) = 1). players + bots <= MAX_CREW.
## ROSTER: peer id -> {peer, seat, name, head, chassis, accent, loadout, steam_id}. The host is seat 1; a joiner takes the
## lowest free seat. Same list on every machine (the host broadcasts it). `head` (chicken / pickle / corn / dog) and
## `chassis` are ids from MechCatalog, `accent` an id from MechAccent; this layer carries them as plain strings and never
## interprets them. `loadout` ({hardpoint id: weapon id}) is the one exception: the host makes it valid for the entry's
## chassis on receipt (clean_loadout: MechCatalog.sanitize_loadout), so every machine builds the same weapons.
##
## MISSION (co-op step 1, cast's M1): NetMission, child "Mission". The host's Launch is start_mission(seed, mode): one
##   reliable mission.launch {seed, mode, start_t, crew, friendly_fire, scale} to the crew (mode: always "stack"); every machine (the host too) gets mission_started(params), plays
##   the bay alert until start_t on the shared clock, then loads the mission. Each machine reports its city checksum
##   (report_mission_built), the host compares them behind a load barrier (a mismatch is sent out with DESYNC), then
##   mission.go {start_at}: mission_go(elapsed) fires on every machine at start_at. See net_mission.gd.
##   The mission plan (the one mode): the host's wave orders go out as reliable mission.wave
##   {order} (send_mission_wave; mission_wave(order) on every client; mission.go carries the ones still to open).
##   Supply depots: depot.claim / depot.grant / depot.deny (claim_depot, send_depot_grant, send_depot_deny; signals
##   depot_claimed / depot_granted / depot_denied), see net_mission.gd "DEPOTS".
##
## MECH SNAPSHOTS (co-op step 2, cast's M2): NetMechStream, child "Mechs" (`mechs`). Each machine streams its own mech
##   on NetWire.T_SNAP (unreliable, 30 Hz, client -> host; the host forwards the others' to each client) and shows the
##   crew's as puppets interpolated ~100 ms behind host_time(). The game calls mechs.begin / feed / pose / end.
##
## ENEMIES (W4, cast's M3): NetEnemyStream, child "Enemies" (`enemies`). The host runs every enemy and streams them on
##   NetWire.T_ENEMY (unreliable, ACTIVE_RATE / IDLE_RATE); clients show puppets ~100 ms behind host_time(). Spawns,
##   telegraphs, destruction and enemy fire are reliable "enemy.*" events (scripts/game/enemy_sync.gd).
##
## LEAVING. A client leaves: the host drops it from the roster. The host leaves normally (leave(), or its process quits):
## sys.bye {reason} (HOST_CLOSED / HOST_ENDED), the transport kept open BYE_LINGER at most until every client has closed
## its end, and each client's session ends with that reason. The host's transport closes with no bye (crash, kill, ENet
## gave up): HOST_LEFT; the host silent for HOST_SILENCE: HOST_SILENT. A kick ends with its own reason. No host migration. While a mission loads, the silence limits
## widen to the load allowance and ENet's own timeouts are wide (docs/networking.md "Timeouts"). session_ended(reason) fires for every way a session (or
## an attempt at one) ends.
##
## CLOCK: NetClock, pinged over unreliable packets; `host_time()` is the shared clock.
## TELEMETRY: NetTelemetry, one row a second, clients' rows collected on the host.
## LINK SIMULATOR: the host's Settings "Simulate a long link" (GameSettings link_sim: off / coast / rough) is the crew's
##   link: applied on the host when it opens the crew, carried in sys.welcome and re-sent as sys.link when it changes
##   (set_link); every machine applies it to what IT receives (NetLink on ENet, Steam's FakePacket* config on Steam).
## CREW OPTIONS: chosen by the host in the hangar, shown read-only to the crew: `friendly_fire` (default true; the host's
##   GameSettings crew friendly_fire). set_friendly_fire on the host (or offline) sends sys.crew_opts; sys.welcome carries
##   the current value; crew_opts_changed fires on every machine. A client's own choice comes back when its session ends.
##   mission.launch carries it, so every machine plays the mission with the same rule (TestDrive.friendly_fire).
## INVITES: Steam's join_requested (an overlay invite accepted while the game runs) becomes `pending_invite` and
##   invite_received(lobby, inviter). The menu (FrontEnd) asks first: Accept (accept_invite(): leave whatever this is and
##   join) or Decline (decline_invite()). With no screen listening (in a mission) nothing is left or joined: the invite
##   waits in pending_invite (it outlives a session ending) and the menu asks when it comes back.
##   `+connect_lobby <id>` (Steam launching the game for an invite) joins at start. invite_crew() opens the overlay.
##
## Dev flags (after `--`):
##   --net-host               host over ENet on --net-port
##   --net-join <ip[:port]>   join over ENet
##   --net-port <P>           ENet port (default DEFAULT_PORT)
##   --net-link off|coast|rough   simulate lag and loss on everything this process receives
##   --net-name <name>        the roster name for this run (two local instances share one Steam name)
##   --net-steam-probe        create a Steam lobby, print it, leave and quit (the manual Steam check)
##   +connect_lobby <id>      Steam launched us to accept an invite: join that lobby

signal session_started(as_host: bool)
signal invite_received(lobby_id: int, inviter: String)
signal link_changed(preset: String)
signal session_ended(reason: String)
signal roster_changed()
signal peer_joined(peer: int)
## A crew member (player or bot) left the roster: on the host when it drops or is sent out (_drop), on a client when the
## host's sys.roster no longer has it. The mission retires the leaver's mech on every machine (CrewSync.retire).
signal peer_left(peer: int)
signal status_changed(text: String)
## Host: a crew member was dropped or sent out, with the reason ("c1 dropped: went silent while loading"). The mission HUD
## shows it; telemetry notes carry it too.
signal crew_note(text: String)
## A crew option changed (friendly_fire): the host chose it, or a client heard it from the host.
signal crew_opts_changed()
## The host launched a mission: {seed, start_t, crew: [roster entries by seat]} (NetMission). Load it at start_t.
signal mission_started(params: Dictionary)
## The load barrier passed: the mission starts now (`elapsed` seconds past start_at on the shared clock).
signal mission_go(elapsed: float)
## A client: the host ended the mission (mission.end). Back to the hangar. (Not emitted for this machine's own
## end_mission(), nor when the session itself ends: session_ended covers that.)
signal mission_ended(reason: String)
## A client: the host decided new mission progress (mission.state, MissionRules.state(): outcome, reason, done, left,
## current). Not emitted on the host (it decided it).
signal mission_state_changed(state: Dictionary)
## A client: the host ordered a reinforcement wave (mission.wave {order}: {wave, deck, source, open_at, max_units}, plan
## mode). Also fired for each order mission.go carries whose open_at has not passed.
signal mission_wave(order: Dictionary)
## A client: the host changed the crew scale (mission.scale {n, at, from, reason, pilot}: apply n at `at` on the shared
## clock; MissionFlow). Also fired for each change mission.go carries.
signal mission_scale(change: Dictionary)
## The host: a crew member asks for a supply depot's power core (depot.claim {depot, n}; NetMission "DEPOTS").
signal depot_claimed(from: int, data: Dictionary)
## A client: the host granted a core (depot.grant {depot, peer, seq, cores_left}; to everyone, or a repeat to the asker).
signal depot_granted(grant: Dictionary)
## A client: the host refused this machine's claim (depot.deny {depot, reason, n}).
signal depot_denied(data: Dictionary)
## A non-system reliable event from a crew member (gameplay events, test probes).
signal event_received(from: int, kind: String, data: Dictionary, stamp: float)
## A non-system unreliable packet that passed the sequence check.
signal packet_received(from: int, type: int, seq: int, stamp_ms: int, payload: PackedByteArray)

enum Transport { NONE, ENET, STEAM }
enum State { OFFLINE, OPENING, CONNECTING, HELLO, ONLINE }

const PROTOCOL := 1
const MAX_CREW := 4
const DEFAULT_PORT := 24600
const DEFAULT_HEAD := "chicken"
const DEFAULT_CHASSIS := "strider"
const DEFAULT_ACCENT := "orange"
const OPEN_TIMEOUT := 12.0      ## Steam lobby create / list / join
const CONNECT_TIMEOUT := 10.0   ## transport connect
const HELLO_TIMEOUT := 10.0     ## connected, waiting for the host's welcome (or a joiner's hello)
const HOST_SILENCE := 6.0       ## a client hears nothing from the host this long: the host is gone
const CLIENT_SILENCE := 10.0    ## the host hears nothing from a client this long: drop it
const REFUSE_GRACE := 1.0       ## a refused joiner is dropped this long after being told why
const KICK_WAIT := 30.0         ## a kicked member that is never heard again is disconnected this long after the kick
const ENET_THROTTLE_INTERVAL_MS := 5000
const ENET_THROTTLE_UP := 2
## ENet's own peer timeout (ENetPacketPeer.set_timeout). ENet's default (limit 32, 5000 ms min, 30000 ms max) dropped a
## client whose main thread was blocked ~6 s building the mission (no service, so no acks: the host's reliable resends hit
## the limit and the 5 s minimum). These are wide on purpose: the session's own watchdogs (HOST_SILENCE, CLIENT_SILENCE,
## the loading allowance) decide when a member is gone; ENet only catches a link that is dead for half a minute.
const ENET_TIMEOUT_LIMIT := 32
const ENET_TIMEOUT_MIN_MS := 30000
const ENET_TIMEOUT_MAX_MS := 60000
## This machine's own frame took longer than this: the silence clocks pause for the stall (it was us, not them).
const STALL_GRACE := 0.5

const CREW_FULL := "Crew is full"
const DIFFERENT_BUILD := "Different build"
## The host's transport closed with no sys.bye first (it crashed, was killed, or ENet gave up on the link): not a normal
## end, not a silence either (HOST_SILENT). A host that ends normally says why in sys.bye (HOST_ENDED / HOST_CLOSED).
const HOST_LEFT := "Lost the host (connection closed)"
## sys.bye reasons: the host's process is quitting (or a hands-off run is over) / the host left the crew from the menu.
const HOST_ENDED := "The host ended the session"
const HOST_CLOSED := "The host closed the crew"
## After sys.bye the host keeps its transport open this long (or until every client has closed its end, which a client
## does as soon as it reads the bye): a disconnect landing in the same receive batch as the bye would discard it, so the
## client would only see the transport close (HOST_LEFT).
const BYE_LINGER := 1.5
const YOU_LEFT := "You left the crew"
const CREW_CLOSED := "You closed the crew"
const CONNECT_FAILED := "Couldn't reach the crew"
const NO_ANSWER := "The crew never answered"
const NO_CREWS := "No crews open right now"
const STEAM_OFF := "Steam not running"
const ON_MISSION := "That crew is on a mission"
const RELAY := "net.relay"           ## broadcast_event, client -> host
const RELAY_FWD := "net.relay_fwd"   ## broadcast_event, host -> the other clients
const DESYNC := "Desync: different city"
const LOAD_SLOW := "Didn't load the mission in time"
const HOST_SILENT := "Lost the host (no answer)"
const HOST_LOST_LOADING := "Lost the host while loading"
const BOT_NAMES := ["Rook", "Vesper", "Kestrel"]
const BOT_HEADS := ["dog", "duck", "corn"]
const BOT_ACCENTS := ["", "", ""]   ## "" = the default accent
const BOT_SKILLS := ["rookie", "average", "veteran", "brawler"]   ## BotProfile.PROFILE_ORDER (kept here: no AI in net code)
const BOT_SKILL := "veteran"

var state := State.OFFLINE
var transport := Transport.NONE
var hosting := false
## peer id -> {"peer", "seat", "name", "head", "chassis", "accent", "steam_id"}
var roster: Dictionary = {}
## Bots seated by the host (pilot id < 0 -> {peer: id, seat, name, head, chassis, accent, loadout, bot: true, skill}).
var bots: Dictionary = {}
## This player's profile, carried in the hello. "" name = the Steam persona, else "Pilot <seat>".
var player_name := ""
var head_id := ""
var chassis_id := ""
var accent_id := ""
## {hardpoint id: weapon id} for local_chassis() ({} = the chassis' default loadout).
var loadout: Dictionary = {}
## What this machine says it is in the hello (tests change them to provoke "Different build").
var protocol := PROTOCOL
var build := ""
var last_reason := ""
var telemetry_enabled := true
var telemetry_dir := NetTelemetry.DIR
## Client: the host's unix time at host_time 0 (tests use it to measure the clock on one machine).
var host_unix_epoch := 0.0
## "lobby" or "mission", published in the lobby data.
var crew_state := "lobby"
## Host: every refused hello, [{peer, name, reason}] (tests and logs).
var refusals: Array = []
## The crew's simulated link: the host decides, every machine applies it to what it receives.
var link_preset := "off"
## Host: take the crew's link from Settings when the crew opens (only the game's own Session; not with --net-link or tests).
var link_from_settings := false
## The crew's friendly fire option: the host decides (set_friendly_fire), the crew sees it (sys.crew_opts, sys.welcome) and
## mission.launch carries it. On a client this is the host's value while online.
var friendly_fire := true
## Host: the skill new bots get (the hangar's picker; set_bot_skill also sets every seated bot's).
var bot_skill := BOT_SKILL
## An overlay invite waiting for the player's answer: {lobby, inviter} ({} = none).
var pending_invite: Dictionary = {}

var wire: NetWire = null
var mission: NetMission = null
## Mech snapshots (co-op step 2): the local mech streamed, the crew's shown as puppets. See net_mech_stream.gd.
var mechs: NetMechStream = null
## The host-owned enemies' stream (W4): child "Enemies" (scripts/net/net_enemy_stream.gd).
var enemies: NetEnemyStream = null
var lobby: SteamLobby = null
var clock := NetClock.new()
var telemetry: NetTelemetry = null
## The worst of this second for the next telemetry row.
var silence_ms := 0.0
var frame_ms := 0.0

var _pending: Dictionary = {}      ## host: peer -> usec it connected (no hello yet)
var _refused: Dictionary = {}      ## host: peer -> usec to drop it
var _last_heard: Dictionary = {}   ## peer -> usec of the last message
var _deadline_usec := 0
var _pings_sent := 0
var _next_ping_usec := 0
var _next_row_usec := 0
var _find_first := false           ## a join_first() is waiting for the lobby list
var _probe := false                ## --net-steam-probe
var _steam_link := false           ## Steam's fake-lag config is set (cleared when the session ends)
var _last_frame_usec := 0
var _prev_process_usec := 0        ## the last _process (any state but OFFLINE): this machine's own stalls
var _last_service_usec := 0        ## the last service_transport()
var _linger_peer: MultiplayerPeer = null   ## a host after sys.bye: the old transport, closed when the crew has gone
var _linger_until_usec := 0
var _own_friendly_fire := true     ## this machine's own choice (a client gets it back when its session ends)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	wire = NetWire.new()
	wire.name = "Wire"
	wire.clock_source = host_time
	add_child(wire)
	mission = NetMission.new()
	mission.name = "Mission"
	add_child(mission)
	mechs = NetMechStream.new()
	mechs.name = "Mechs"
	add_child(mechs)
	enemies = NetEnemyStream.new()
	enemies.name = "Enemies"
	add_child(enemies)
	wire.event_received.connect(_on_event)
	wire.packet_received.connect(_on_packet)
	lobby = SteamLobby.new()
	lobby.name = "Lobby"
	add_child(lobby)
	lobby.created.connect(_on_lobby_created)
	lobby.joined.connect(_on_lobby_joined)
	lobby.failed.connect(_on_lobby_failed)
	lobby.listed.connect(_on_lobby_listed)
	lobby.invite_accepted.connect(_on_invite)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	if get_parent() == get_tree().root:
		_apply_flags.call_deferred(OS.get_cmdline_user_args(), OS.get_cmdline_args())
		var watch := QuitWatch.new()
		watch.name = "SessionQuitWatch"
		watch.on_quit = _on_quitting
		get_tree().root.add_child.call_deferred(watch)


## Exits the tree just before Session does when the process quits (a later child of the root, and the root's children
## leave last-first), while Session's Wire is still in the tree and can send: Session's own _exit_tree comes after its
## children's, too late for an RPC.
class QuitWatch extends Node:
	var on_quit: Callable

	func _exit_tree() -> void:
		if on_quit.is_valid():
			on_quit.call()


## The process is quitting (QuitWatch). A host says bye (HOST_ENDED) and keeps polling its transport for up to
## BYE_LINGER, until every client has read it and closed its end.
func _on_quitting() -> void:
	if hosting and state == State.ONLINE:
		leave(CREW_CLOSED, HOST_ENDED)
	_linger_block()


func _linger_block() -> void:
	if _linger_peer == null:
		return
	while _linger_peer != null and Time.get_ticks_usec() < _linger_until_usec and not multiplayer.get_peers().is_empty():
		multiplayer.poll()
		OS.delay_msec(5)
	_close_linger()


## Closing the transport is what tells the others (a host has said bye in _on_quitting already, when it could).
func _exit_tree() -> void:
	if state != State.OFFLINE:
		_end(CREW_CLOSED if hosting else YOU_LEFT, true)
	_linger_block()


# --- Asking (anyone may) -------------------------------------------------------------------------------

func online() -> bool:
	return state == State.ONLINE


## Hosting a session, or offline (solo is hosting with nobody joining).
func is_host() -> bool:
	return hosting or state == State.OFFLINE


func is_client() -> bool:
	return state == State.ONLINE and not hosting


## Busy opening, connecting or saying hello.
func busy() -> bool:
	return state != State.OFFLINE and state != State.ONLINE


## This machine's peer id, or 0 offline. (get_unique_id() is 1 offline too, so never use it for "host".)
func local_id() -> int:
	return multiplayer.get_unique_id() if state == State.ONLINE else 0


## The shared session clock in seconds (0 offline, and on a client before the first pong).
func host_time() -> float:
	if state != State.ONLINE:
		return 0.0
	return clock.host_time(Time.get_ticks_usec())


## The crew sorted by seat: the players (roster) and the host's bots (entries with "bot": true, negative peer ids).
func crew() -> Array:
	var out: Array = roster.values() + bots.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["seat"]) < int(b["seat"]))
	return out


## A bot's pilot id (negative; players' ids are peer ids, always positive).
static func is_bot_id(id: int) -> bool:
	return id < 0


func is_bot(id: int) -> bool:
	return bots.has(id)


## A crew member (player or bot) right now: use it where a crew mech's pilot id is checked against the crew.
func has_member(id: int) -> bool:
	return roster.has(id) or bots.has(id)


## The crew entry of a player or bot ({} when none).
func member(id: int) -> Dictionary:
	return roster.get(id, bots.get(id, {}))


## The peer whose machine runs pilot `id`: the player itself, the host (1) for a bot.
static func machine_of(id: int) -> int:
	return 1 if id < 0 else id


## The bots' pilot ids, by seat.
func bot_ids() -> Array[int]:
	var out: Array[int] = []
	for e: Dictionary in crew():
		if bool(e.get("bot", false)):
			out.append(int(e["peer"]))
	return out


func local_entry() -> Dictionary:
	return roster.get(local_id(), {})


func host_name() -> String:
	for e: Dictionary in roster.values():
		if int(e["seat"]) == 1:
			return str(e["name"])
	return ""


func steam_available() -> bool:
	return SteamIdentity.available()


func local_head() -> String:
	return head_id if head_id != "" else DEFAULT_HEAD


func local_chassis() -> String:
	return chassis_id if chassis_id != "" else DEFAULT_CHASSIS


func local_accent() -> String:
	return accent_id if accent_id != "" else DEFAULT_ACCENT


## This player's loadout, valid for local_chassis().
func local_loadout() -> Dictionary:
	return clean_loadout(local_chassis(), loadout)


## A loadout from the wire (or settings) made safe and valid for `chassis`: a {String: String} dictionary of at most a
## dozen short entries, then MechCatalog.sanitize_loadout (every hardpoint present, misfits emptied; {} = the default).
static func clean_loadout(chassis: String, v: Variant) -> Dictionary:
	var raw := {}
	if v is Dictionary:
		for k: Variant in v:
			if raw.size() >= 12:
				break
			if (k is String or k is StringName) and (v[k] is String or v[k] is StringName):
				raw[str(k).left(24)] = str(v[k]).left(24)
	return MechCatalog.sanitize_loadout(chassis, raw)


## The name this player shows: the profile's, else the Steam persona, else `fallback`.
func display_name(fallback: String = "Pilot") -> String:
	if player_name != "":
		return player_name
	var steam_name := SteamIdentity.player_name("")
	return steam_name if steam_name != "" else fallback


## The player changed their name, head, chassis, accent or loadout (settings, hangar). Offline it is just stored; in a
## session the host updates its own entry and tells the crew, a client asks the host (sys.profile), which re-sends the
## roster. `accent` "" and `loadout_` {} keep the current ones (the stored loadout is re-validated for the chassis).
func set_profile(name_: String, head: String, chassis: String, accent: String = "", loadout_: Dictionary = {}) -> void:
	player_name = name_
	head_id = head
	chassis_id = chassis
	if accent != "":
		accent_id = accent
	if not loadout_.is_empty():
		loadout = loadout_.duplicate()
	if state != State.ONLINE:
		return
	var data := {"name": display_name("Pilot %d" % int(local_entry().get("seat", 1))), "head": local_head(),
		"chassis": local_chassis(), "accent": local_accent(), "loadout": local_loadout()}
	if hosting:
		_update_entry(1, data)
	else:
		wire.send_event(1, "sys.profile", data)


# --- Starting and ending ----------------------------------------------------------------------------

## Host over ENet. False (and session_ended) when the port can't be opened.
func host_enet(port: int = DEFAULT_PORT) -> bool:
	if not _can_start():
		return false
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_server(port, MAX_CREW + 2)   # room to tell a 5th "Crew is full" before dropping it
	if err != OK:
		_end("Couldn't open port %d (error %d)" % [port, err])
		return false
	_begin_host(enet, Transport.ENET)
	return true


## Join over ENet. The result arrives as session_started(false) or session_ended(reason).
func join_enet(address: String, port: int = DEFAULT_PORT) -> bool:
	if not _can_start():
		return false
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_client(address, port)
	if err != OK:
		_end("%s (%s:%d, error %d)" % [CONNECT_FAILED, address, port, err])
		return false
	_set_peer(enet)
	transport = Transport.ENET
	_set_state(State.CONNECTING, CONNECT_TIMEOUT, "Calling the crew at %s:%d..." % [address, port])
	return true


## Host over Steam: open a lobby, then the Steam peer. Result: session_started(true) or session_ended(reason).
func host_steam() -> bool:
	if not _can_start():
		return false
	if not SteamIdentity.available():
		_end(STEAM_OFF)
		return false
	transport = Transport.STEAM
	hosting = true
	_set_state(State.OPENING, OPEN_TIMEOUT, "Opening a lobby...")
	return lobby.create(MAX_CREW)


## Join the first Steam lobby open for this game and build (no browser).
func join_first() -> bool:
	if not _can_start():
		return false
	if not SteamIdentity.available():
		_end(STEAM_OFF)
		return false
	transport = Transport.STEAM
	_find_first = true
	_set_state(State.OPENING, OPEN_TIMEOUT, "Looking for an open crew...")
	return lobby.request_list()


## Join a specific Steam lobby (an invite).
func join_lobby(lobby_id: int) -> bool:
	if not _can_start():
		return false
	if not SteamIdentity.available():
		_end(STEAM_OFF)
		return false
	transport = Transport.STEAM
	_set_state(State.OPENING, OPEN_TIMEOUT, "Joining the crew...")
	return lobby.join(lobby_id)


## Leave the session (or stop trying to join one). The host tells everyone first: sys.bye {bye_reason} (HOST_CLOSED by
## default; HOST_ENDED when the game quits or a hands-off run is over), then keeps the transport open until every client
## has closed its end, BYE_LINGER at most, so the bye is read before the disconnect.
func leave(reason: String = "", bye_reason: String = HOST_CLOSED) -> void:
	if state == State.OFFLINE:
		return
	if reason == "":
		reason = CREW_CLOSED if hosting else YOU_LEFT
	if hosting and state == State.ONLINE:
		_to_crew("sys.bye", {"reason": bye_reason})
		wire.flush()
		_log("said bye to the crew: %s" % bye_reason)
		if roster.size() > 1:
			_end(reason, false, true)
			return
	_end(reason)


## Send a reliable event to one crew member, or the whole crew (to = 0; from a client that is the host).
## Kinds starting "sys." are reserved.
func send_event(to: int, kind: String, data: Dictionary = {}) -> void:
	if state != State.ONLINE:
		return
	if to != 0:
		wire.send_event(to, kind, data)
	elif hosting:
		_to_crew(kind, data)
	else:
		wire.send_event(1, kind, data)


## Send a reliable event to EVERY other crew member, relayed by the host: a client sends it to the host, which hears it
## (event_received(sender, kind, data, stamp)) and forwards it to the other clients, who hear it from the original sender
## with the original stamp; the host's own goes straight to every client. The sender does not hear its own (apply it
## locally). `kind` must not start with "sys.".
func broadcast_event(kind: String, data: Dictionary = {}) -> void:
	if state != State.ONLINE or kind.begins_with("sys."):
		return
	if hosting:
		_to_crew(RELAY_FWD, {"from": 1, "kind": kind, "data": data, "t": host_time()})
	else:
		wire.send_event(1, RELAY, {"kind": kind, "data": data})


## Send an unreliable, sequence-numbered packet (NetWire.T_SNAP and up, or T_TEST) to one member, or the whole crew
## (to = 0: one send, and one sequence stream, per member). Returns the sequence number, or -1 offline.
func send_packet(to: int, type: int, payload: PackedByteArray) -> int:
	if state != State.ONLINE:
		return -1
	if to != 0 or not hosting:
		return wire.send_packet(to if to != 0 else 1, type, payload)
	var seq := -1
	for p: int in roster:
		if p != 1:
			seq = wire.send_packet(p, type, payload)
	return seq


## "lobby" or "mission": what the host's crew is doing, for the lobby list.
func set_crew_state(s: String) -> void:
	crew_state = s
	if hosting and state == State.ONLINE:
		_publish_lobby()


# --- Mission (NetMission does the work; these are the calls game and UI code make) ------------------

## Host: launch a mission for the crew on `seed`, built as `mode` (NetMission.MODE_STACK, the multi-deck section, the
## only one) (mission.launch, then mission_started on every machine). False on a client, offline (solo play loads
## the test drive itself), or while a mission is already under way.
func start_mission(seed_value: int, mode: String = NetMission.MODE_STACK) -> bool:
	return mission.host_launch(seed_value, mode)


## The launched mission's params ({seed, mode, start_t, crew}), {} when none (offline, or between missions).
func mission_params() -> Dictionary:
	return mission.params


## This machine built the mission behind the load barrier: `checksum` is its city checksum (TestDrive.mission_checksum():
## CityStack.checksum() for a stack, CityPlan.checksum() for a district).
## `ms`: how long the build took (telemetry, [Flow] logs).
func report_mission_built(checksum: String, ms: int = 0) -> void:
	mission.report_built(checksum, ms)


## This machine starts building the launched mission (a long blocking step on a slow machine): tells the host.
func report_mission_loading() -> void:
	mission.report_loading()


## Host: the mission's progress changed (MissionRules.state()): sent to the crew as a reliable mission.state, and in
## mission.go for late members. Ignored on a client or offline.
func send_mission_state(state_: Dictionary) -> void:
	mission.host_state(state_)


## Members of the launched mission that have reported their build (NetMission.ready_peers: the loading screen's crew
## list). Everyone once the barrier has passed; [] offline.
func mission_ready_peers() -> Array[int]:
	return mission.ready_peers()


## Host: a reinforcement wave order (PacingDirector.tick, plan mode): sent to the crew as a reliable mission.wave and kept
## for mission.go (members reaching the barrier late get the orders whose door hasn't opened). Ignored on a client.
func send_mission_wave(order: Dictionary) -> void:
	mission.host_wave(order)


## Client: ask the host for a power core of supply depot `depot` (reliable depot.claim {depot, n}; n = this pilot's claim
## counter, re-sent unchanged while unanswered). Ignored on the host (it arbitrates its own claims) or offline.
func claim_depot(depot: String, n: int) -> void:
	mission.client_depot_claim(depot, n)


## Host: a granted core (depot.grant {depot, peer, seq, cores_left}) to the crew (`to` 0) or one member.
func send_depot_grant(grant: Dictionary, to: int = 0) -> void:
	mission.host_depot_grant(grant, to)


## Host: a refused claim (depot.deny {depot, reason, n}) to the asker.
func send_depot_deny(peer: int, data: Dictionary) -> void:
	mission.host_depot_deny(peer, data)


## Every wave order of the mission this machine has (host: sent; client: heard), in order.
func mission_waves() -> Array:
	return mission.waves


## Host: the crew scale changes (MissionFlow.on_member_retired): {n, at, from, reason, pilot}, `at` on the shared clock;
## sent to the crew as a reliable mission.scale and kept for mission.go. Ignored on a client or offline.
func send_mission_scale(change: Dictionary) -> void:
	mission.host_scale(change)


## Every crew-scale change of the mission this machine has (host: sent; client: heard), in order.
func mission_scales() -> Array:
	return mission.scales


## The latest mission progress the host decided ({} before the first, or between missions).
func mission_state() -> Dictionary:
	return mission.state


## Leave the mission: the host ends it for the whole crew (mission.end), a client just for itself.
func end_mission(reason: String = "") -> void:
	mission.end(reason)


## Host: send a crew member out with a reason. It is told why, dropped at once and disconnected REFUSE_GRACE later.
func kick(peer: int, reason: String) -> void:
	if not hosting or state != State.ONLINE or peer == 1 or not roster.has(peer):
		return
	wire.send_event(peer, "sys.refuse", {"reason": reason})
	wire.flush()
	# A member is disconnected only REFUSE_GRACE after it is heard again (so it has had the refusal: an ENet disconnect
	# landing in the same receive batch would discard it), or KICK_WAIT at the latest (a stalled client, say).
	_refused[peer] = {"at": Time.get_ticks_usec(), "kick": true}
	_drop(peer, "was sent out: %s" % reason)


## The crew's friendly fire option, set on the host (sent to the crew) or offline (solo, and kept for the next crew this
## machine hosts). False on a client: the host decides.
func set_friendly_fire(on: bool) -> bool:
	if state == State.ONLINE and not hosting:
		return false
	_own_friendly_fire = on
	var changed := on != friendly_fire
	friendly_fire = on
	if hosting and state == State.ONLINE:
		_to_crew("sys.crew_opts", {"friendly_fire": on})
	if changed:
		_log("friendly fire: %s" % ("on" if on else "off"))
		crew_opts_changed.emit()
	return true


func _apply_crew_opts(data: Dictionary) -> void:
	var on := bool(data.get("friendly_fire", true))
	if on == friendly_fire:
		return
	friendly_fire = on
	_log("friendly fire (host): %s" % ("on" if on else "off"))
	crew_opts_changed.emit()


# --- Link simulator, invites ------------------------------------------------------------------------

## Host: the crew's simulated link ("off", "coast", "rough"): applied here and sent to every member. False on a client
## or for an unknown preset.
func set_link(preset: String) -> bool:
	if not NetLink.PRESETS.has(preset) or (state == State.ONLINE and not hosting):
		return false
	_apply_link(preset)
	if hosting and state == State.ONLINE:
		_to_crew("sys.link", {"preset": preset})
	return true


func _apply_link(preset: String) -> void:
	if not NetLink.PRESETS.has(preset):
		preset = "off"
	if transport == Transport.STEAM and SteamIdentity.steam() != null:
		if wire.link.preset != "off":
			wire.link.configure("off")
		NetSteamLink.apply(SteamIdentity.steam(), preset)
		_steam_link = preset != "off"
	elif wire.link.preset != preset:
		wire.link.configure(preset)
	var changed := preset != link_preset
	link_preset = preset
	if changed:
		_log("simulated link: %s" % preset)
		link_changed.emit(preset)


## A Steam crew with a seat free: the overlay's invite dialog can open.
func can_invite() -> bool:
	return state == State.ONLINE and transport == Transport.STEAM and lobby.lobby_id != 0 and seats_free() > 0


func invite_crew() -> bool:
	return can_invite() and lobby.open_invite_dialog()


## The player said yes to the pending invite: leave whatever this is and join that crew.
func accept_invite() -> bool:
	if pending_invite.is_empty():
		return false
	var id := int(pending_invite["lobby"])
	pending_invite = {}
	if state != State.OFFLINE:
		leave()
	return join_lobby(id)


func decline_invite() -> void:
	if not pending_invite.is_empty():
		_log("invite from %s declined" % str(pending_invite.get("inviter", "?")))
	pending_invite = {}


func seats_free() -> int:
	return maxi(MAX_CREW - roster.size() - bots.size(), 0)


## Host, crew in the lobby: seat a bot (lowest free bot slot and seat). Its name, head and accent follow its slot; its
## chassis and loadout are picked at launch from the mission seed (BotLoadout, on every machine). Returns its pilot id,
## 0 when refused (a client, offline, full, on a mission).
func add_bot(skill: String = BOT_SKILL) -> int:
	if not hosting or state != State.ONLINE or crew_state != "lobby" or seats_free() <= 0:
		return 0
	var slot := 1
	while bots.has(-slot):
		slot += 1
	var seat := 1
	var taken: Array[int] = []
	for e: Dictionary in crew():
		taken.append(int(e["seat"]))
	while taken.has(seat):
		seat += 1
	var id := -slot
	bots[id] = {"peer": id, "seat": seat, "name": BOT_NAMES[(slot - 1) % BOT_NAMES.size()],
		"head": BOT_HEADS[(slot - 1) % BOT_HEADS.size()], "chassis": DEFAULT_CHASSIS,
		"accent": BOT_ACCENTS[(slot - 1) % BOT_ACCENTS.size()], "loadout": {}, "bot": true, "skill": _clean_skill(skill)}
	_bots_changed("%s (bot) seated" % str(bots[id]["name"]))
	return id


## Host, lobby: take a bot out of the crew. False when there is no such bot or it is refused.
func remove_bot(id: int) -> bool:
	if not hosting or state != State.ONLINE or crew_state != "lobby" or not bots.has(id):
		return false
	var n := str(bots[id]["name"])
	bots.erase(id)
	_bots_changed("%s (bot) left" % n)
	return true


## Host, lobby: every bot's skill (a BotProfile id).
func set_bot_skill(skill: String) -> bool:
	if not hosting or state != State.ONLINE or crew_state != "lobby":
		return false
	bot_skill = _clean_skill(skill)
	for id: int in bots:
		(bots[id] as Dictionary)["skill"] = bot_skill
	if not bots.is_empty():
		_bots_changed("")
	return true


## Host: write fields of a bot's entry (e.g. the accent it derived at launch) and send the roster. Any crew state.
func set_bot_fields(id: int, fields: Dictionary) -> void:
	if not hosting or state != State.ONLINE or not bots.has(id):
		return
	var e: Dictionary = bots[id]
	var changed := false
	for k: Variant in fields:
		if k == "peer" or k == "bot" or e.get(k) == fields[k]:
			continue
		e[k] = fields[k]
		changed = true
	if changed:
		_bots_changed("")


static func _clean_skill(skill: String) -> String:
	return skill if skill in BOT_SKILLS else BOT_SKILL


func _bots_changed(text: String) -> void:
	_to_crew("sys.roster", {"entries": crew()})
	_publish_lobby()
	if text != "":
		_log(text)
		FlowLog.say("crew bot", "%s, crew %d" % [text, roster.size() + bots.size()])
		status_changed.emit(text + ".")
	roster_changed.emit()


# --- Internals --------------------------------------------------------------------------------------

func _can_start() -> bool:
	if state != State.OFFLINE:
		push_warning("[Net] already in a session")
		return false
	_close_linger()
	last_reason = ""
	return true


func _begin_host(peer: MultiplayerPeer, via: Transport) -> void:
	_set_peer(peer)
	transport = via
	hosting = true
	crew_state = "lobby"
	roster.clear()
	bots.clear()
	refusals.clear()
	clock.start_host(Time.get_ticks_usec())
	wire.reset()
	_set_state(State.ONLINE, 0.0, "")
	roster[1] = {"peer": 1, "seat": 1, "name": display_name("Pilot 1"), "head": local_head(), "chassis": local_chassis(),
		"accent": local_accent(), "loadout": local_loadout(), "steam_id": SteamIdentity.steam_id()}
	_apply_link(str(GameSettings.load_settings()["link_sim"]) if link_from_settings else wire.link.preset)
	_open_telemetry()
	_publish_lobby()
	_log("hosting via %s" % ("steam" if via == Transport.STEAM else "enet"))
	FlowLog.say("session hosting", "steam" if via == Transport.STEAM else "enet")
	status_changed.emit("Crew open. Waiting for pilots.")
	session_started.emit(true)
	roster_changed.emit()


func _set_peer(peer: MultiplayerPeer) -> void:
	var sm := multiplayer as SceneMultiplayer
	if sm != null:
		sm.server_relay = false   # clients only ever talk to the host
	multiplayer.multiplayer_peer = peer


func _set_state(s: State, timeout: float, status: String) -> void:
	state = s
	_deadline_usec = Time.get_ticks_usec() + int(timeout * 1e6) if timeout > 0.0 else 0
	if status != "":
		status_changed.emit(status)


## `close_now`: close the transport immediately (only safe outside its poll). `linger`: a host that just said bye keeps
## the transport open (polled, everything it delivers ignored: the state is OFFLINE) until the crew has closed its ends
## or BYE_LINGER passes (_process, _exit_tree).
func _end(reason: String, close_now: bool = false, linger: bool = false) -> void:
	FlowLog.say("session ended", reason)   # before the state resets: the line still says host / client and the peer
	var was := state
	var peer := multiplayer.multiplayer_peer
	if linger and peer != null and not (peer is OfflineMultiplayerPeer):
		_close_linger()
		_linger_peer = peer
		_linger_until_usec = Time.get_ticks_usec() + int(BYE_LINGER * 1e6)
	elif peer != null and not (peer is OfflineMultiplayerPeer):
		# Deferred: _end often runs inside the peer's own poll (an RPC or a disconnect signal), and freeing the peer
		# there crashes the engine. Until then state is OFFLINE, so nothing it still delivers is used.
		if close_now:
			_close_peer(peer)
		else:
			_close_peer.call_deferred(peer)
	if _steam_link and SteamIdentity.steam() != null:
		NetSteamLink.apply(SteamIdentity.steam(), "off")
	_steam_link = false
	lobby.leave()
	wire.reset()
	if telemetry != null:
		telemetry.close()
	telemetry = null
	state = State.OFFLINE
	transport = Transport.NONE
	hosting = false
	roster.clear()
	bots.clear()
	_pending.clear()
	_refused.clear()
	_last_heard.clear()
	_find_first = false
	_deadline_usec = 0
	crew_state = "lobby"
	mission.reset()
	if friendly_fire != _own_friendly_fire:
		friendly_fire = _own_friendly_fire   # a client's view of the host's option ends with the session
		crew_opts_changed.emit()
	last_reason = reason
	_log("session ended: %s (was %s)" % [reason, State.keys()[was]])
	session_ended.emit(reason)
	roster_changed.emit()
	status_changed.emit(reason)


func _close_peer(peer: MultiplayerPeer) -> void:
	if multiplayer.multiplayer_peer == peer:
		multiplayer.multiplayer_peer = null
	peer.close()


## The transport kept open after a bye: close it now (the crew has gone, the linger ran out, or a new session starts).
func _close_linger() -> void:
	if _linger_peer == null:
		return
	var peer := _linger_peer
	_linger_peer = null
	_linger_until_usec = 0
	_log("closing the transport after the bye")
	_close_peer(peer)


# --- Transport callbacks -----------------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if not hosting or state != State.ONLINE:
		return
	_tune_enet(id)
	_pending[id] = Time.get_ticks_usec()
	_last_heard[id] = Time.get_ticks_usec()
	wire.send_event(id, "sys.ask", {"protocol": protocol, "build": _build()})
	_log("peer %d connected, asking who it is" % id)


func _on_peer_disconnected(id: int) -> void:
	_log("transport: peer %d disconnected" % id)
	if hosting:
		_pending.erase(id)
		_refused.erase(id)
		_last_heard.erase(id)
		if roster.has(id):
			_drop(id, "lost the link while loading" if mission.waiting_for(id) else "left")
	elif id == 1 and state != State.OFFLINE:
		_end(HOST_LOST_LOADING if mission.loading() else HOST_LEFT)


func _on_connected_to_server() -> void:
	if state != State.CONNECTING:
		return
	_tune_enet(1)
	_last_heard[1] = Time.get_ticks_usec()
	_set_state(State.HELLO, HELLO_TIMEOUT, "Connected. Saying hello...")


## ENet's peer timeout is widened (ENET_TIMEOUT_*: a main thread blocked by a slow load must not be dropped by ENet).
## ENet throttles a connection whose round trips vary by dropping UNRELIABLE packets on purpose; the lag link's jitter
## provokes exactly that. The throttle is not allowed to fall, so unreliable loss on ENet is the link's alone (cast).
func _tune_enet(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var pp := enet.get_peer(peer_id)
	if pp != null:
		pp.throttle_configure(ENET_THROTTLE_INTERVAL_MS, ENET_THROTTLE_UP, 0)
		pp.set_timeout(ENET_TIMEOUT_LIMIT, ENET_TIMEOUT_MIN_MS, ENET_TIMEOUT_MAX_MS)
	else:
		push_warning("[Net] no ENet peer %d to tune" % peer_id)


func _on_connection_failed() -> void:
	if state != State.OFFLINE:
		_end(CONNECT_FAILED)


func _on_server_disconnected() -> void:
	if state == State.OFFLINE:
		return
	_log("transport: the host's connection closed")
	if state == State.ONLINE and mission.loading():
		_end(HOST_LOST_LOADING)
		return
	_end(HOST_LEFT if state == State.ONLINE or state == State.HELLO else CONNECT_FAILED)


# --- Steam lobby callbacks ---------------------------------------------------------------------------

func _on_lobby_created(lobby_id: int) -> void:
	if state != State.OPENING or not hosting:
		return
	var peer: Object = ClassDB.instantiate("SteamMultiplayerPeer")
	if peer == null:
		_end("This build has no Steam transport")
		return
	peer.set("no_nagle", true)
	NetSteamLink.apply_timeouts(SteamIdentity.steam())
	var err := int(peer.call("create_host", 0))
	if err != OK:
		_end("Steam couldn't host (error %d)" % err)
		return
	print("[Net] Steam lobby ", lobby_id, " open")
	_begin_host(peer as MultiplayerPeer, Transport.STEAM)


func _on_lobby_listed(lobbies: Array) -> void:
	if _probe and hosting:
		_finish_probe(lobbies)
		return
	if not _find_first or state != State.OPENING:
		return
	_find_first = false
	var pick := pick_lobby(lobbies, func(lid: int, key: String) -> String: return lobby.get_data(lid, key),
		SteamLobby.build_version())
	if int(pick["id"]) != 0:
		status_changed.emit("Found %s. Joining..." % lobby.get_data(int(pick["id"]), "name"))
		lobby.join(int(pick["id"]))
		return
	_end(str(pick["reason"]))


## Join's choice among listed lobbies: the first of this build with a free seat whose crew is in the hangar (lobby data
## "state" != "mission": its host would refuse us ON_MISSION). `data` is (lobby id, key) -> lobby data. {id, reason}:
## id 0 when none fits, reason ON_MISSION when every open crew of this build is on a mission, else NO_CREWS.
static func pick_lobby(lobbies: Array, data: Callable, version: String) -> Dictionary:
	var busy := 0
	for id: Variant in lobbies:
		var lid := int(id)
		if str(data.call(lid, "version")) != version or str(data.call(lid, "seats_free")) == "0":
			continue
		if str(data.call(lid, "state")) == "mission":
			busy += 1
			continue
		return {"id": lid, "reason": ""}
	return {"id": 0, "reason": ON_MISSION if busy > 0 else NO_CREWS}


func _on_lobby_joined(_lobby_id: int) -> void:
	if state != State.OPENING or hosting:
		return
	var host_steam_id := lobby.owner_id()
	var peer: Object = ClassDB.instantiate("SteamMultiplayerPeer")
	if host_steam_id == 0 or peer == null:
		_end(CONNECT_FAILED)
		return
	peer.set("no_nagle", true)
	NetSteamLink.apply_timeouts(SteamIdentity.steam())
	var err := int(peer.call("create_client", host_steam_id, 0))
	if err != OK:
		_end("%s (Steam error %d)" % [CONNECT_FAILED, err])
		return
	_set_peer(peer as MultiplayerPeer)
	_set_state(State.CONNECTING, CONNECT_TIMEOUT, "Calling the crew...")


func _on_lobby_failed(reason: String) -> void:
	if _probe:
		print("[Net] steam probe FAILED: ", reason)
		get_tree().quit(1)
		return
	if state == State.OPENING:
		_end(reason)


## An overlay invite accepted while the game runs: kept in pending_invite, and the menu asks first (INVITES above). Never
## joins on its own.
func _on_invite(lobby_id: int, friend_id: int = 0) -> void:
	if lobby_id != 0 and lobby_id == lobby.lobby_id and state != State.OFFLINE:
		_log("invite to the lobby we are in: ignored")
		return
	var inviter := lobby.friend_name(friend_id)
	print("[Net] invite accepted in the overlay: lobby %d from %s" % [lobby_id, inviter if inviter != "" else "?"])
	pending_invite = {"lobby": lobby_id, "inviter": inviter}
	if get_signal_connection_list("invite_received").is_empty():
		_log("invite kept for the menu to ask about (nothing is listening now)")
		status_changed.emit("%s invited you to their crew: answer in the menu." % (inviter if inviter != "" else "A Steam friend"))
	invite_received.emit(lobby_id, inviter)


# --- Events ------------------------------------------------------------------------------------------

func _on_event(from: int, kind: String, data: Dictionary, stamp: float) -> void:
	if state == State.OFFLINE:
		return
	_heard(from)
	if kind.begins_with("sys."):
		if hosting:
			_host_sys(from, kind, data)
		else:
			_client_sys(from, kind, data)
		return
	if state != State.ONLINE or (hosting and not roster.has(from)) or (not hosting and from != 1):
		return
	if kind == RELAY and hosting:   # a client's broadcast_event: hear it, then pass it on to the others
		var k := str(data.get("kind", ""))
		var d: Variant = data.get("data", {})
		if k == "" or k.begins_with("sys.") or not d is Dictionary:
			return
		event_received.emit(from, k, d, stamp)
		for p: int in roster:
			if p != 1 and p != from:
				wire.send_event(p, RELAY_FWD, {"from": from, "kind": k, "data": d, "t": stamp})
		return
	if kind == RELAY_FWD and not hosting:
		var k2 := str(data.get("kind", ""))
		var d2: Variant = data.get("data", {})
		if k2 == "" or k2.begins_with("sys.") or not d2 is Dictionary:
			return
		event_received.emit(int(data.get("from", 1)), k2, d2, float(data.get("t", stamp)))
		return
	event_received.emit(from, kind, data, stamp)


func _host_sys(from: int, kind: String, data: Dictionary) -> void:
	match kind:
		"sys.hello":
			if _pending.has(from):
				_admit(from, data)
		"sys.profile":
			if roster.has(from):
				_update_entry(from, data)


func _admit(from: int, data: Dictionary) -> void:
	_pending.erase(from)
	var name_ := str(data.get("name", "")).strip_edges().left(24)
	var their_build := str(data.get("build", ""))
	if int(data.get("protocol", -1)) != protocol or their_build != _build():
		_refuse(from, name_, "%s (crew on %s, you on %s)" % [DIFFERENT_BUILD, _build(), their_build])
		return
	if roster.size() + bots.size() >= MAX_CREW:
		_refuse(from, name_, CREW_FULL)
		return
	if crew_state == "mission":
		_refuse(from, name_, ON_MISSION)   # (joining mid-mission comes later: cast's M6 seat handover)
		return
	var seat := 1
	var taken: Array[int] = []
	for e: Dictionary in crew():
		taken.append(int(e["seat"]))
	while taken.has(seat):
		seat += 1
	if name_ == "":
		name_ = "Pilot %d" % seat
	var chassis := str(data.get("chassis", DEFAULT_CHASSIS))
	roster[from] = {"peer": from, "seat": seat, "name": name_, "head": str(data.get("head", DEFAULT_HEAD)),
		"chassis": chassis, "accent": str(data.get("accent", DEFAULT_ACCENT)),
		"loadout": clean_loadout(chassis, data.get("loadout", {})), "steam_id": int(data.get("steam_id", 0))}
	wire.send_event(from, "sys.welcome", {"seat": seat, "peer": from, "entries": crew(),
		"host_unix": Time.get_unix_time_from_system() - host_time(), "link": link_preset,
		"friendly_fire": friendly_fire})
	_to_crew("sys.roster", {"entries": crew()})
	_publish_lobby()
	_log("%s joined (peer %d, seat %d, head %s, chassis %s)" % [name_, from, seat, roster[from]["head"], roster[from]["chassis"]])
	FlowLog.say("crew joined", "%s peer %d seat %d, crew %d" % [name_, from, seat, roster.size()])
	status_changed.emit("%s joined." % name_)
	peer_joined.emit(from)
	roster_changed.emit()


## Host: a member's name / head / chassis changed (its sys.profile, or the host's own set_profile).
func _update_entry(peer: int, data: Dictionary) -> void:
	var e: Dictionary = roster[peer]
	var name_ := str(data.get("name", e["name"])).strip_edges().left(24)
	e["name"] = name_ if name_ != "" else e["name"]
	e["head"] = str(data.get("head", e["head"]))
	e["chassis"] = str(data.get("chassis", e["chassis"]))
	e["accent"] = str(data.get("accent", e.get("accent", DEFAULT_ACCENT)))
	e["loadout"] = clean_loadout(str(e["chassis"]), data.get("loadout", e.get("loadout", {})))
	_to_crew("sys.roster", {"entries": crew()})
	roster_changed.emit()


## Host: an event to every client in the roster (one send each: a broadcast would also reach peers still saying hello,
## or being refused, which must not see the crew).
func _to_crew(kind: String, data: Dictionary) -> void:
	for p: int in roster:
		if p != 1:
			wire.send_event(p, kind, data)


func _refuse(peer: int, name_: String, reason: String) -> void:
	refusals.append({"peer": peer, "name": name_, "reason": reason})
	wire.send_event(peer, "sys.refuse", {"reason": reason})
	wire.flush()
	_refused[peer] = {"at": Time.get_ticks_usec(), "kick": false}
	_log("refused %s (peer %d): %s" % [name_, peer, reason])
	FlowLog.say("joiner refused", "%s peer %d: %s" % [name_, peer, reason])


func _drop(peer: int, why: String) -> void:
	var e: Dictionary = roster[peer]
	roster.erase(peer)
	_to_crew("sys.roster", {"entries": crew()})
	_publish_lobby()
	_log("%s %s (peer %d)" % [str(e["name"]), why, peer])
	if telemetry != null:
		telemetry.note(host_time(), "crew: %s %s (peer %d)" % [str(e["name"]), why, peer])
	var text := "%s left" % str(e["name"]) if why == "left" else "%s dropped: %s" % [str(e["name"]), why]
	status_changed.emit(text + ".")
	crew_note.emit(text)
	FlowLog.say("crew left" if why == "left" else "crew dropped", "%s (peer %d), crew %d" % [text, peer, roster.size()])
	peer_left.emit(peer)
	roster_changed.emit()


func _client_sys(from: int, kind: String, data: Dictionary) -> void:
	if from != 1:
		return
	match kind:
		"sys.ask":
			if state == State.HELLO or state == State.CONNECTING:
				wire.send_event(1, "sys.hello", {"protocol": protocol, "build": _build(), "name": display_name(""),
					"head": local_head(), "chassis": local_chassis(), "accent": local_accent(), "loadout": local_loadout(),
					"steam_id": SteamIdentity.steam_id()})
		"sys.welcome":
			if state == State.ONLINE:
				return
			host_unix_epoch = float(data.get("host_unix", 0.0))
			_set_roster(data.get("entries", []) as Array)
			_apply_link(str(data.get("link", link_preset)))
			_apply_crew_opts(data)
			clock.start_client(Time.get_ticks_usec())
			_pings_sent = 0
			_next_ping_usec = 0
			_set_state(State.ONLINE, 0.0, "")
			_open_telemetry()
			_log("welcomed: seat %d as peer %d" % [int(data.get("seat", 0)), local_id()])
			FlowLog.say("session joined", "seat %d, crew %d, host %s" % [int(data.get("seat", 0)), roster.size(), host_name()])
			status_changed.emit("Joined %s's crew." % host_name())
			session_started.emit(false)
			roster_changed.emit()
		"sys.roster":
			if state == State.ONLINE:
				_set_roster(data.get("entries", []) as Array)
				roster_changed.emit()
		"sys.link":
			if state == State.ONLINE:
				_apply_link(str(data.get("preset", "off")))
		"sys.crew_opts":
			if state == State.ONLINE:
				_apply_crew_opts(data)
		"sys.refuse":
			FlowLog.say("session refused", str(data.get("reason", CONNECT_FAILED)))
			_end(str(data.get("reason", CONNECT_FAILED)))
		"sys.bye":
			# A normal end: show the host's reason. _end closes this end at once (deferred), which is what lets the
			# lingering host close too.
			var why := str(data.get("reason", ""))
			_end(why if why != "" else HOST_ENDED)


func _set_roster(entries: Array) -> void:
	var before: Array = roster.keys() + bots.keys()
	roster.clear()
	bots.clear()
	for e: Variant in entries:
		var d := e as Dictionary
		var id := int(d["peer"])
		if bool(d.get("bot", false)) and is_bot_id(id):
			bots[id] = d
		elif id > 0:
			roster[id] = d
	# A client hears a leaver only through the roster (clients talk to the host alone): say so, as the host's _drop does.
	# Players only: a bot taken off in the hangar is not a leaver (and bots never leave a mission on their own).
	if not hosting and state == State.ONLINE:
		for p: Variant in before:
			if not is_bot_id(int(p)) and not has_member(int(p)):
				_log("peer %d left the crew" % int(p))
				peer_left.emit(int(p))


# --- Packets -----------------------------------------------------------------------------------------

func _on_packet(from: int, type: int, seq: int, stamp_ms: int, payload: PackedByteArray) -> void:
	if state == State.OFFLINE:
		return
	_heard(from)
	if state != State.ONLINE:
		return
	match type:
		NetWire.T_PING:
			if hosting and roster.has(from) and payload.size() >= 8:
				var out := StreamPeerBuffer.new()
				out.put_u64(payload.decode_u64(0))
				out.put_double(host_time())
				wire.send_packet(from, NetWire.T_PONG, out.data_array)
				wire.flush()
		NetWire.T_PONG:
			if not hosting and from == 1 and payload.size() >= 16:
				clock.add_sample(payload.decode_u64(0), payload.decode_double(8), Time.get_ticks_usec())
		NetWire.T_ROW:
			if hosting and telemetry != null and roster.has(from):
				var row: Variant = bytes_to_var(payload)
				if row is Array:
					telemetry.note_peer_row(from, row as Array)
		_:
			if hosting and not roster.has(from):
				return
			packet_received.emit(from, type, seq, stamp_ms, payload)


# --- Every frame -------------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if state == State.OFFLINE:
		_last_frame_usec = 0
		_prev_process_usec = 0
		if _linger_peer != null and (Time.get_ticks_usec() >= _linger_until_usec or multiplayer.get_peers().is_empty()):
			_close_linger()
		return
	var now := Time.get_ticks_usec()
	if _prev_process_usec > 0 and now - _prev_process_usec > int(STALL_GRACE * 1e6):
		_pause_silence(now - _prev_process_usec, now)
	_prev_process_usec = now
	clock.advance(now)
	if state == State.ONLINE:
		if _last_frame_usec > 0:
			frame_ms = maxf(frame_ms, float(now - _last_frame_usec) / 1000.0)
		_last_frame_usec = now
	if _deadline_usec > 0 and now > _deadline_usec and state != State.ONLINE:
		match state:
			State.OPENING: _end("Steam didn't answer")
			State.CONNECTING: _end(CONNECT_FAILED)
			_: _end(NO_ANSWER)
		return
	if state != State.ONLINE:
		return
	if hosting:
		_host_watch(now)
	else:
		var loading := mission.loading()
		var limit := maxf(HOST_SILENCE, mission.load_allowance()) if loading else HOST_SILENCE
		if now - int(_last_heard.get(1, now)) > int(limit * 1e6):
			_end(HOST_LOST_LOADING if loading else HOST_SILENT)
			return
		if now >= _next_ping_usec:
			var buf := StreamPeerBuffer.new()
			buf.put_u64(now)
			wire.send_packet(1, NetWire.T_PING, buf.data_array)
			wire.flush()
			_pings_sent += 1
			_next_ping_usec = now + int(NetClock.ping_interval(_pings_sent) * 1e6)
	if telemetry != null and now >= _next_row_usec:
		_next_row_usec = now + 1000000
		_telemetry_row()


func _host_watch(now: int) -> void:
	var peer := multiplayer.multiplayer_peer
	for id: int in _pending.keys():
		if now - int(_pending[id]) > int(HELLO_TIMEOUT * 1e6):
			_pending.erase(id)
			_log("peer %d: no hello in time, disconnecting" % id)
			peer.disconnect_peer(id)
	for id: int in _refused.keys():
		var r: Dictionary = _refused[id]
		var at := int(r["at"])
		var due := at + int(REFUSE_GRACE * 1e6)
		if bool(r["kick"]):
			var heard := int(_last_heard.get(id, 0))
			due = heard + int(REFUSE_GRACE * 1e6) if heard > at else at + int(KICK_WAIT * 1e6)
		if now > due:
			_refused.erase(id)
			_log("peer %d: refused / sent out earlier, disconnecting" % id)
			peer.disconnect_peer(id)
	for id: int in roster.keys():
		if id == 1:
			continue
		var loading := mission.waiting_for(id)
		var limit := maxf(CLIENT_SILENCE, mission.load_allowance()) if loading else CLIENT_SILENCE
		if now - int(_last_heard.get(id, now)) > int(limit * 1e6):
			_drop(id, "went silent while loading" if loading else "went silent")
			peer.disconnect_peer(id)   # (_drop logged why)


## This machine's frame was blocked for `gap_usec` (a slow mission build, a hitch): nobody could have been heard while we
## weren't listening, so every silence clock (and a pending handshake deadline) moves forward by the stall. Packets that
## did arrive during it were already taken by this frame's poll (SceneMultiplayer polls before any _process).
func _pause_silence(gap_usec: int, now: int) -> void:
	for k: Variant in _last_heard.keys():
		_last_heard[k] = mini(now, int(_last_heard[k]) + gap_usec)
	for k: Variant in _pending.keys():
		_pending[k] = mini(now, int(_pending[k]) + gap_usec)
	if _deadline_usec > 0:
		_deadline_usec += gap_usec
	if state == State.ONLINE:
		var text := "this machine stalled %d ms: silence clocks paused" % (gap_usec / 1000)
		_log(text)
		if telemetry != null:
			telemetry.note(host_time(), text)


## Keep the link alive from inside a long blocking step (the mission build): service the transport (ENet answers acks
## and pings, Steam takes its messages) and push out what is queued, WITHOUT dispatching anything: what arrives waits in
## the peer's queue for the next SceneMultiplayer poll, so no event reaches game code that isn't set up yet. Cheap; at
## most every 20 ms. Safe to call offline.
func service_transport() -> void:
	if state == State.OFFLINE:
		return
	var now := Time.get_ticks_usec()
	if now - _last_service_usec < 20000:
		return
	_last_service_usec = now
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return
	peer.poll()
	wire.flush()


# --- Telemetry ---------------------------------------------------------------------------------------

func _heard(from: int) -> void:
	var now := Time.get_ticks_usec()
	if state == State.ONLINE and _last_heard.has(from) and roster.has(from) and from != local_id():
		silence_ms = maxf(silence_ms, float(now - int(_last_heard[from])) / 1000.0)
	_last_heard[from] = now


func _open_telemetry() -> void:
	if not telemetry_enabled:
		return
	telemetry = NetTelemetry.new()
	telemetry.dir = telemetry_dir
	if not telemetry.open("host" if hosting else "client"):
		telemetry = null
	_next_row_usec = Time.get_ticks_usec() + 1000000
	silence_ms = 0.0
	frame_ms = 0.0


func _telemetry_row() -> void:
	var c := wire.take_counters()
	var arrived := int(c["packets_in"])
	var expected := arrived + maxi(int(c["gaps"]) - int(c["stale"]), 0)
	var e := local_entry()
	var now := Time.get_ticks_usec()
	var others := 0
	for p: int in roster:
		if p != local_id() and _last_heard.has(p):
			others += 1
			silence_ms = maxf(silence_ms, float(now - int(_last_heard[p])) / 1000.0)
	var row: Array = [
		"%.3f" % host_time(), "host" if hosting else "client", local_id(), int(e.get("seat", 0)), roster.size(),
		"" if hosting else "%.1f" % clock.rtt_ms, "" if hosting else "%.1f" % clock.rtt_min_ms,
		"" if hosting else "%.1f" % clock.jitter_ms, "" if hosting else "%.2f" % clock.pending_correction_ms(),
		"%.3f" % (float(arrived) / float(expected) if expected > 0 else 1.0),
		c["bytes_out"], c["bytes_in"], c["packets_out"], c["packets_in"], c["events_out"], c["events_in"], c["gaps"], c["stale"],
		link_preset, wire.link.held(), wire.link.dropped, "%d" % roundi(silence_ms) if others > 0 else "", "%.1f" % frame_ms,
	]
	silence_ms = 0.0
	frame_ms = 0.0
	telemetry.write_row(row)
	if not hosting:
		wire.send_packet(1, NetWire.T_ROW, var_to_bytes(row))


# --- Lobby data, flags -------------------------------------------------------------------------------

func _publish_lobby() -> void:
	if transport != Transport.STEAM or not hosting:
		return
	lobby.set_data("seats_free", str(seats_free()))
	lobby.set_data("state", crew_state)


func _build() -> String:
	return build if build != "" else SteamLobby.build_version()


func _apply_flags(args: PackedStringArray, engine_args: PackedStringArray) -> void:
	var link := Boot.arg_value(args, "--net-link")
	if link != "" and not wire.link.configure(link):
		push_warning("[Net] unknown --net-link %s (off, coast, rough)" % link)
	link_from_settings = link == "" and not args.has("--run-test")
	wire.link.seed_with(OS.get_process_id())
	var name_ := Boot.arg_value(args, "--net-name")
	if name_ != "":
		player_name = name_
	if args.has("--run-test"):
		return   # tests drive the session themselves (NetTest)
	var port_s := Boot.arg_value(args, "--net-port")
	var port := int(port_s) if port_s.is_valid_int() else DEFAULT_PORT
	if args.has("--net-steam-probe"):
		_steam_probe()
	elif args.has("--net-host"):
		host_enet(port)
	elif Boot.arg_value(args, "--net-join") != "":
		var target := Boot.arg_value(args, "--net-join")
		var addr := target
		if target.contains(":"):
			addr = target.get_slice(":", 0)
			port = int(target.get_slice(":", 1))
		join_enet(addr, port)
	else:
		var invite := SteamLobby.connect_lobby_arg(engine_args)
		if invite == 0:
			invite = SteamLobby.connect_lobby_arg(args)
		if invite != 0:
			join_lobby(invite)


## The manual Steam check: host through the real path, ask Steam for the lobby list with Join's filters (our own lobby
## should be in it), then leave and quit.
func _steam_probe() -> void:
	_probe = true
	if not SteamIdentity.available():
		print("[Net] steam probe FAILED: Steam not available")
		get_tree().quit(1)
		return
	print("[Net] steam probe: hosting as ", SteamIdentity.player_name("?"))
	session_started.connect(func(_as_host: bool) -> void:
		print("[Net] steam probe: hosting via steam, lobby %d, roster %s" % [lobby.lobby_id, str(crew())])
		lobby.request_list())
	session_ended.connect(func(reason: String) -> void:
		if _probe:
			print("[Net] steam probe FAILED: ", reason)
			get_tree().quit(1))
	telemetry_enabled = false
	host_steam()
	get_tree().create_timer(OPEN_TIMEOUT * 2.0).timeout.connect(func() -> void:
		print("[Net] steam probe FAILED: timed out")
		get_tree().quit(1))


func _finish_probe(lobbies: Array) -> void:
	var id := lobby.lobby_id
	var data := {}
	for k in ["name", "game", "version", "protocol", "seats_free", "state"]:
		data[k] = lobby.get_data(id, k)
	var listed := lobbies.map(func(v: Variant) -> int: return int(v)).has(id)
	print("[Net] steam probe OK: lobby %d owned by %d (me %d), data %s; the Join list (%d lobbies) %s it" % [
		id, lobby.owner_id(), SteamIdentity.steam_id(), str(data), lobbies.size(), "includes" if listed else "does NOT include"])
	_probe = false
	leave()
	get_tree().create_timer(0.5).timeout.connect(func() -> void: get_tree().quit(0))


func _log(msg: String) -> void:
	print("[Net] ", msg)

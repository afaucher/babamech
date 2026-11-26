class_name CrewAuto
extends Node
## Hands-off crew runs (LAN verification, soak tests): one node under the tree root for the whole process (it outlives
## the menu <-> mission scene changes), made by FrontEnd the first time it opens (CrewAuto.ensure).
##   --auto-launch N    host: launch once the crew is N and every member is in the hangar (back from the last mission)
##   --auto-relaunch    host: after that mission, back in the hangar, launch once more
##   --auto-quit        host: after the last auto launch's mission, back in the hangar, close the crew and quit;
##                      client: quit when the session ends
## Every client, flags or not, tells the host it is in the hangar: "crew.hangar" {launches} (NetMission.launches it has
## heard) about every HEARTBEAT s while its menu shows the hangar. The host counts a member ready only when that number
## equals its own (so a heartbeat sent before a launch never counts after it).

const HEARTBEAT := 1.0
const HOLD := 2.0          ## s the launch conditions must hold before the host launches
const QUIT_AFTER := 3.0    ## s in the hangar after the last mission before an auto-quit host leaves

var auto_launch := 0       ## crew size to launch at (0 = off)
var relaunch := false
var auto_quit := false
var launched := 0          ## auto launches done
var _ready_peers: Dictionary = {}   ## host: peer -> the launches count its last heartbeat carried
var _beat := 0.0
var _hold := 0.0
var _quit_t := -1.0


static func ensure(tree: SceneTree) -> CrewAuto:
	var a := tree.root.get_node_or_null("CrewAuto") as CrewAuto
	if a != null:
		return a
	a = CrewAuto.new()
	a.name = "CrewAuto"
	tree.root.add_child.call_deferred(a)
	return a


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	var n := Boot.arg_value(args, "--auto-launch")
	auto_launch = int(n) if n.is_valid_int() else 0
	relaunch = args.has("--auto-relaunch")
	auto_quit = args.has("--auto-quit")
	Session.event_received.connect(_on_event)
	Session.session_ended.connect(func(reason: String) -> void:
		_ready_peers.clear()
		if auto_quit and not args.has("--run-test"):
			print("[CrewAuto] session ended (%s): quitting" % reason)
			get_tree().create_timer(1.0).timeout.connect(func() -> void: get_tree().quit()))
	if auto_launch > 0:
		print("[CrewAuto] host: auto launch at crew %d%s%s" % [auto_launch, ", relaunch" if relaunch else "", ", quit after" if auto_quit else ""])


func _on_event(from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	if kind == "crew.hangar" and Session.hosting:
		_ready_peers[from] = int(data.get("launches", -1))


## The menu is up and shows the hangar.
func _in_hangar() -> bool:
	var fe := get_tree().current_scene as FrontEnd
	return fe != null and fe.screen == "hangar" and not fe.launching


func _process(delta: float) -> void:
	if not Session.online():
		return
	if not Session.hosting:
		_beat -= delta
		if _beat <= 0.0 and _in_hangar():
			_beat = HEARTBEAT
			Session.send_event(1, "crew.hangar", {"launches": NetMission.launches})
		return
	if auto_launch <= 0 or Session.mission.phase != NetMission.IDLE or not _in_hangar():
		_hold = 0.0
		return
	var allowed := 2 if relaunch else 1
	if launched >= allowed:
		if auto_quit:
			if _quit_t < 0.0:
				_quit_t = QUIT_AFTER
				FlowLog.say("back in hangar", "the last auto mission is over")
			_quit_t -= delta
			if _quit_t <= 0.0:
				print("[CrewAuto] done: closing the crew and quitting")
				Session.leave("", NetSession.HOST_ENDED)   # the crew reads "The host ended the session"
				get_tree().create_timer(1.0).timeout.connect(func() -> void: get_tree().quit())
				auto_quit = false
		return
	if Session.roster.size() < auto_launch or not _crew_in_hangar():
		_hold = 0.0
		return
	_hold += delta
	if _hold < HOLD:
		return
	_hold = 0.0
	launched += 1
	var args := OS.get_cmdline_user_args()
	print("[CrewAuto] auto launch %d of %d (crew %d)" % [launched, allowed, Session.roster.size()])
	Session.start_mission(FrontEnd.mission_seed(args), TestDrive.MODE_STACK)


func _crew_in_hangar() -> bool:
	for p: int in Session.roster:
		if p != 1 and int(_ready_peers.get(p, -1)) != NetMission.launches:
			return false
	return true

class_name HangarHandoff
extends CanvasLayer
## Carries the hangar's launch egress (HangarEgress, docs/design/hangar-v2/README.md) across the scene change into the
## mission: FrontEnd hands its MechStage (bay mode, egress playing) to this layer on the tree root just before it
## changes scene, so the mechs keep walking into the airlock, full screen, over the mission's loading screen while the
## mission loads behind it. MissionScene waits for it (`wait_done`) before it reports its build at the crew's load barrier
## (crew) or uncovers (solo): play starts only when both the sequence and the load are done, and since the sequence's
## length comes from the crew, which every machine has the same, the crew still starts together on the host's go.
## When the sequence ends the layer fades out over FADE and frees itself (the loading screen underneath then shows
## what is left of the load).
##
## Never in tests unless one opts in (`in_tests`), never headless: there is no sequence to wait for, so net tests'
## barriers are not slowed. Cosmetic and local (no net state); processes ALWAYS (the solo warm-up pauses the tree).

const LAYER := 126              ## just above LoadingScreen.LAYER (125)
const FADE := 0.35

static var current: HangarHandoff
static var in_tests := false

signal done

var stage: MechStage
var _holder: Control
var _finished := false
var _fade := -1.0


## Whether a launch from this stage should be carried over: the bay is shown with its egress playing, a real window.
static func wanted(st: MechStage) -> bool:
	if st == null or not is_instance_valid(st) or not st.in_bay or st.bay == null or st.bay.egress() == null:
		return false
	if st.bay.egress().finished() or DisplayServer.get_name() == "headless":
		return false
	return in_tests or not OS.get_cmdline_user_args().has("--run-test")


## Take the stage over (call before the scene change): it moves to a full-screen layer on the root.
static func carry(st: MechStage) -> HangarHandoff:
	var h := HangarHandoff.new()
	h.layer = LAYER
	h.process_mode = Node.PROCESS_MODE_ALWAYS
	h.name = "HangarHandoff"
	st.get_tree().root.add_child(h)
	h._take(st)
	current = h
	return h


## Whether a carried sequence is still playing.
static func playing() -> bool:
	return current != null and is_instance_valid(current) and not current._finished


## Await this: returns at once when nothing is playing, else when the sequence ends.
static func wait_done() -> void:
	if playing():
		await current.done


func _take(st: MechStage) -> void:
	stage = st
	_holder = Control.new()
	_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_holder)
	_holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	st.reparent(_holder, false)
	st.mouse_filter = Control.MOUSE_FILTER_IGNORE
	st.process_mode = Node.PROCESS_MODE_ALWAYS
	st.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	if _fade >= 0.0:
		_fade += delta
		_holder.modulate.a = 1.0 - clampf(_fade / FADE, 0.0, 1.0)
		if _fade >= FADE:
			queue_free()
		return
	var eg := stage.bay.egress() if stage != null and is_instance_valid(stage) and stage.bay != null else null
	# Back in the menu (the mission was left during the load), or the sequence is over: done.
	if eg == null or eg.finished() or get_tree().current_scene is FrontEnd:
		_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if current == self:
		current = null
	done.emit()
	_fade = 0.0 if not (get_tree().current_scene is FrontEnd) else FADE


func _exit_tree() -> void:
	if current == self:
		current = null
	if not _finished:
		_finished = true
		done.emit()

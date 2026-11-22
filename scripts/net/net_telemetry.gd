class_name NetTelemetry
extends RefCounted
## Passive network telemetry (ported from cast, which ported it from Bridge to Friendship): ONE CSV ROW PER SECOND PER
## MACHINE, so a trend ("it gets worse over time") can be read afterwards. It diagnoses nothing and has no thresholds.
##
## - Every machine writes its own file: user://net/net_<role>_<date>_<pid>.csv (the path is printed when the session starts).
## - A client also sends each finished row to the host, UNRELIABLY, and the host files it in its own CSV under `from` (the
##   peer id the transport reports, never the one in the row). So the host's file holds the whole crew. A row that doesn't
##   arrive is a GAP, never a zero.
## - Event columns are rates over the last second; state columns are levels at the sample.
##   silence_ms  the longest stretch with nothing received from the other side (the host: its quietest client).
##   frame_ms    this machine's longest frame that second.
## (cast's casts / hits sheets are not ported yet: they come with combat.)

const DIR := "user://net"
const KEEP_FILES := 40      ## older telemetry files are pruned when a new one opens
const COLUMNS: Array[String] = [
	"t", "role", "from", "seat", "crew",
	"rtt_ms", "rtt_min_ms", "jitter_ms", "clock_fix_ms", "quality",
	"bytes_out", "bytes_in", "pkts_out", "pkts_in", "events_out", "events_in", "gaps", "stale",
	"link", "link_held", "link_dropped", "silence_ms", "frame_ms",
]

## Where files go (tests use their own folder so they never crowd out real sessions).
var dir := DIR
var path := ""
var rows_written := 0
var peer_rows := 0

var _file: FileAccess = null


## Open a fresh file for this session. Returns false when it can't be written.
func open(role: String) -> bool:
	DirAccess.make_dir_recursive_absolute(dir)
	_prune()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	path = "%s/net_%s_%s_%d.csv" % [dir, role, stamp, OS.get_process_id()]
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		printerr("[Net] could not open telemetry at ", path)
		return false
	_file.store_line(",".join(COLUMNS))
	_file.flush()
	print("[Net] telemetry -> ", ProjectSettings.globalize_path(path))
	return true


func close() -> void:
	if _file != null:
		_file.flush()
	_file = null


func is_open() -> bool:
	return _file != null


## This machine's row.
func write_row(row: Array) -> void:
	if _file == null or row.size() != COLUMNS.size():
		return
	_write(row)
	rows_written += 1


## A client's row, on the host. `from` is overwritten with the transport's peer id. A row of the wrong width (another
## build) is dropped, so a column can never silently shift.
func note_peer_row(peer: int, row: Array) -> void:
	if _file == null or row.size() != COLUMNS.size():
		return
	var copy := row.duplicate()
	copy[COLUMNS.find("from")] = peer
	_write(copy)
	peer_rows += 1


func _write(row: Array) -> void:
	var cells := PackedStringArray()
	for v: Variant in row:
		cells.append(str(v).replace(",", ";"))
	_file.store_line(",".join(cells))
	_file.flush()   # a session under investigation usually ends by being killed: keep the tail


func _prune() -> void:
	var files: Array = []   # [modified time, path]
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".csv") or not f.begins_with("net_"):
			continue
		var p := "%s/%s" % [dir, f]
		files.append([FileAccess.get_modified_time(p), p])
	if files.size() < KEEP_FILES:
		return
	files.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	for i in files.size() - KEEP_FILES + 1:
		DirAccess.remove_absolute(str(files[i][1]))

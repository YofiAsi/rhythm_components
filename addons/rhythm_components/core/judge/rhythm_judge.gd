class_name RhythmJudge
extends RhythmComponent

signal note_succeed(note: ChartPartNote, error_beats: float)
signal note_missed(note: ChartPartNote)
signal note_blank_hit(note_key: StringName)

class NoteState:
	var note: ChartPartNote
	var note_key: StringName
	var resolved: bool = false
	var dispatched: bool = false # whether a succeed was already emitted (either by judge or orchestrator)
	var error_beats: float = 0.0

	func _init(n: ChartPartNote) -> void:
		note = n
		note_key = n.type.action_name

var _pending_by_key: Dictionary[StringName, Array] = {}
var _state_by_note_id: Dictionary[int, NoteState] = {}

func _ready() -> void:
	super._ready()

func set_note_keys(note_keys_list: Array[StringName]) -> void:
	_pending_by_key = {}
	_state_by_note_id = {}
	for note_key in note_keys_list:
		_pending_by_key[note_key] = []

# --- Window lifecycle (note-instance based) ---

func on_hit_window_opened(note: ChartPartNote) -> void:
	if note == null or note.type == null:
		return

	var st := NoteState.new(note)
	var id := note.get_instance_id()

	_state_by_note_id[id] = st

	if not _pending_by_key.has(st.note_key):
		_pending_by_key[st.note_key] = []
	_pending_by_key[st.note_key].append(st)

func on_hit_window_closed(note: ChartPartNote, close_beat: float) -> void:
	if note == null:
		return

	var id := note.get_instance_id()
	if not _state_by_note_id.has(id):
		return

	var st: NoteState = _state_by_note_id[id]

	# Remove from pending list
	if _pending_by_key.has(st.note_key):
		var arr := _pending_by_key[st.note_key]
		var idx := arr.find(st)
		if idx != -1:
			arr.remove_at(idx)

	_state_by_note_id.erase(id)

	# If never resolved, it's a miss.
	if not st.resolved:
		note_missed.emit(st.note)
		return

	# Failsafe: if resolved but never dispatched for some reason, dispatch now.
	if st.resolved and not st.dispatched:
		note_succeed.emit(st.note, st.error_beats)
		st.dispatched = true

# --- Input handling ---

func on_input_event(
	note_key: StringName,
	event: InputEvent,
	input_beat: float,
	check_pressed: bool = true
) -> void:
	if event == null:
		return

	if not (event.is_pressed() or not check_pressed):
		return

	if event.is_echo():
		return

	var st := _pick_best_pending(note_key, input_beat)
	if st == null:
		note_blank_hit.emit(note_key)
		return

	# Resolve and record error.
	st.resolved = true
	st.error_beats = input_beat - st.note.start_time

	# Late (or exactly on time) hit: succeed immediately.
	if input_beat >= st.note.start_time and not st.dispatched:
		note_succeed.emit(st.note, st.error_beats)
		st.dispatched = true

func _pick_best_pending(note_key: StringName, input_beat: float) -> NoteState:
	if not _pending_by_key.has(note_key):
		return null

	var arr: Array = _pending_by_key[note_key]
	var best: NoteState = null
	var best_abs := INF

	for st in arr:
		# Only consider unresolved notes
		if st.resolved:
			continue

		var d := absf(input_beat - st.note.start_time)
		if d < best_abs:
			best_abs = d
			best = st

	return best

# --- Query from orchestrator at hit_time ---

# Returns:
# {
#   "emit": bool,            # should orchestrator emit succeed now
#   "error_beats": float     # stored error (only meaningful if emit=true)
# }
func on_note_hit_time(note: ChartPartNote) -> Dictionary:
	var out := {"emit": false, "error_beats": 0.0}

	if note == null:
		return out

	var id := note.get_instance_id()
	if not _state_by_note_id.has(id):
		return out

	var st: NoteState = _state_by_note_id[id]
	if st.resolved and not st.dispatched:
		# Orchestrator should emit succeed now (reaction at hit_time)
		out["emit"] = true
		out["error_beats"] = st.error_beats
		st.dispatched = true

	return out

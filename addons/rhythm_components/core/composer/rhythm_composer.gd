class_name RhythmComposer
extends RhythmComponent

class ComposerAction:
	enum ActionType {
		BEHAVIOR_ENTER,
		HIT_WINDOW_OPEN,
		HIT_WINDOW_CLOSE,
		BEHAVIOR_EXIT,
		SEQUENCE_START,
		SEQUENCE_END,
		HIT,
		SIGNAL
	}
	
	var time: float
	var type: ActionType
	var reported: bool = false
	var note: ChartPartNote = null
	var note_signal: ChartPartSignal = null
	var sequence: ChartPartSequence = null
	
	func _init(t: float, action_type: ActionType) -> void:
		time = t
		type = action_type
	
	static func create_behavior_enter(t: float, n: ChartPartNote) -> ComposerAction:
		var action := ComposerAction.new(t, ActionType.BEHAVIOR_ENTER)
		action.note = n
		return action
	
	static func create_hit_window_open(t: float, n: ChartPartNote) -> ComposerAction:
		var action := ComposerAction.new(t, ActionType.HIT_WINDOW_OPEN)
		action.note = n
		return action
	
	static func create_hit_window_close(t: float, n: ChartPartNote) -> ComposerAction:
		var action := ComposerAction.new(t, ActionType.HIT_WINDOW_CLOSE)
		action.note = n
		return action
	
	static func create_behavior_exit(t: float, n: ChartPartNote) -> ComposerAction:
		var action := ComposerAction.new(t, ActionType.BEHAVIOR_EXIT)
		action.note = n
		return action
	
	static func create_sequence_start(t: float, s: ChartPartSequence) -> ComposerAction:
		var action := ComposerAction.new(t, ActionType.SEQUENCE_START)
		action.sequence = s
		return action
	
	static func create_sequence_end(t: float, s: ChartPartSequence) -> ComposerAction:
		var action := ComposerAction.new(t, ActionType.SEQUENCE_END)
		action.sequence = s
		return action
	
	static func create_hit(t: float, n: ChartPartNote) -> ComposerAction:
		var action := ComposerAction.new(t, ActionType.HIT)
		action.note = n
		return action
	
	static func create_signal(t: float, ns: ChartPartSignal) -> ComposerAction:
		var action := ComposerAction.new(t, ActionType.SIGNAL)
		action.note_signal = ns
		return action

signal note_behavior_enter(note: ChartPartNote)
signal note_hit_window_open(note: ChartPartNote)
signal note_hit(note: ChartPartNote)
signal note_hit_window_close(note: ChartPartNote)
signal note_behavior_exit(note: ChartPartNote)
signal note_signal(note: ChartPartSignal)

signal sequence_started(sequence: ChartPartSequence)
signal sequence_ended(sequence: ChartPartSequence)

const EPSILON := 0.0001

var _actions: Array[ComposerAction] = []
var _chart: RhythmChart
var _hit_window: float
var _cur_index: int
var _prev_beat: float

func _ready() -> void:
	super._ready()

func set_hit_window(v: float) -> void:
	_hit_window = v

func update(curr_beat: float) -> void:
	while _cur_index < len(_actions):
		var action := _actions[_cur_index]

		if action.reported:
			_cur_index += 1
			continue

		if action.time <= curr_beat:
			action.reported = true
			_report_action(action)
			_cur_index += 1
		else:
			break
	
	_prev_beat = curr_beat

func _compile_chart(chart: RhythmChart) -> void:
	_actions = []
	if not chart:
		return

	for part in chart.parts:
		if part is ChartPartNote:
			add_note(part)
		if part is ChartPartSequence:
			add_sequence(part)
		if part is ChartPartSignal:
			add_note_signal(part)

	_actions.sort_custom(func(a, b):
		return a.time < b.time
	)

func set_chart(chart: RhythmChart) -> void:
	_cur_index = 0
	_prev_beat = 0.0
	_chart = chart
	_compile_chart(_chart)

func set_chart_from_midi(midi_path: String, bpm: float, note_mapping: MidiNoteMapping) -> void:
	_cur_index = 0
	_prev_beat = 0.0
	_chart = compile_chart_from_midi(midi_path, bpm, note_mapping)
	_compile_chart(_chart)

func _report_action(action: ComposerAction) -> void:
	match action.type:
		ComposerAction.ActionType.BEHAVIOR_ENTER:
			note_behavior_enter.emit(action.note)

		ComposerAction.ActionType.HIT_WINDOW_OPEN:
			note_hit_window_open.emit(action.note)

		ComposerAction.ActionType.HIT_WINDOW_CLOSE:
			note_hit_window_close.emit(action.note)

		ComposerAction.ActionType.BEHAVIOR_EXIT:
			note_behavior_exit.emit(action.note)

		ComposerAction.ActionType.SEQUENCE_START:
			sequence_started.emit(action.sequence)

		ComposerAction.ActionType.SEQUENCE_END:
			sequence_ended.emit(action.sequence)

		ComposerAction.ActionType.HIT:
			note_hit.emit(action.note)
		
		ComposerAction.ActionType.SIGNAL:
			note_signal.emit(action.note_signal)

func _insert_action_sorted(action: ComposerAction) -> void:
	var idx := _actions.bsearch_custom(action, func(a, b): return a.time < b.time)
	_actions.insert(idx, action)

#region Note API
func add_note(note: ChartPartNote) -> void:
	var pre_t  = note.start_time - note.type.behavior_pre_offset
	var hw_open = note.start_time - _hit_window
	var hw_close = note.start_time + _hit_window
	var post_t: float
	if note.hold:
		post_t = note.start_time + note.hold_time
	else:
		post_t = note.start_time + note.type.behavior_post_offset

	if pre_t <= _prev_beat:
		push_warning("Cannot insert note: first action occurs in the past.")
		return

	_insert_action_sorted(ComposerAction.create_behavior_enter(pre_t, note))
	_insert_action_sorted(ComposerAction.create_hit(note.start_time, note))
	_insert_action_sorted(ComposerAction.create_hit_window_open(hw_open, note))
	_insert_action_sorted(ComposerAction.create_hit_window_close(hw_close, note))
	_insert_action_sorted(ComposerAction.create_behavior_exit(post_t, note))

func _quantize(time: float, note_type: ChartNoteType) -> float:
	return _quantize_to_measure_parts(time, note_type.enter_measure_parts)

func _quantize_to_measure_parts(time: float, parts: Array[float]) -> float:
	if parts.is_empty():
		return ceil(time)

	var beats_per_measure: float = orchestrator.beats_per_measure
	var current_measure: int = orchestrator.measure

	parts.sort()

	# Try current measure
	for part in parts:
		var candidate: float = current_measure * beats_per_measure \
			+ part * beats_per_measure

		if candidate >= time:
			return candidate

	# Fallback: next measure
	var next_measure: int = current_measure + 1
	return next_measure * beats_per_measure \
		+ parts[0] * beats_per_measure

func add_note_auto(note: ChartPartNote) -> float:
	# Compute the earliest possible hit time such that
	# all derived action times are still in the future.
	var needed_enter_time: float = orchestrator.beat + EPSILON
	
	var enter_time := _quantize_to_measure_parts(
		needed_enter_time,
		note.type.enter_measure_parts
	)
	
	var hit_time := enter_time + note.type.behavior_pre_offset
	note.start_time = hit_time

	add_note(note)
	return hit_time

func add_note_signal(note_signal: ChartPartSignal) -> void:
	_insert_action_sorted(ComposerAction.create_signal(note_signal.start_time, note_signal))
#endregion

#region Sequence API
func _resolve_sequence_enter_time(sequence: ChartPartSequence) -> float:
	if sequence.start_time > 0.0:
		return sequence.start_time

	var needed_enter_time: float = orchestrator.beat + EPSILON

	return _quantize_to_measure_parts(
		needed_enter_time,
		sequence.enter_measure_parts
	)

func _compute_sequence_end_time(sequence: ChartPartSequence) -> float:
	var max_time := 0.0

	for part in sequence.parts:
		var part_end: float
		if part is ChartPartNote and part.hold:
			part_end = part.start_time + part.hold_time
		else:
			part_end = part.start_time + part.type.behavior_post_offset
		if part_end > max_time:
			max_time = part_end

	return sequence.start_time + max_time

func _add_sequence_start(sequence: ChartPartSequence) -> void:
	_insert_action_sorted(ComposerAction.create_sequence_start(sequence.start_time, sequence))

func _add_sequence_end(sequence: ChartPartSequence) -> void:
	var end_time := _compute_sequence_end_time(sequence)
	_insert_action_sorted(ComposerAction.create_sequence_end(end_time, sequence))

func add_sequence(sequence: ChartPartSequence) -> float:
	_add_sequence_start(sequence)
	for part in sequence.parts:
		var part_copy: ChartPart = part.duplicate()
		var original_start := part_copy.start_time
		part_copy.start_time = sequence.start_time + original_start
		add_note(part_copy)

	_add_sequence_end(sequence)

	return sequence.start_time

func add_sequence_auto(sequence: ChartPartSequence) -> float:
	var sequence_copy: ChartPartSequence = sequence.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	sequence_copy.start_time = 0.0
	var enter_time := _resolve_sequence_enter_time(sequence_copy)
	sequence_copy.start_time = enter_time

	if enter_time <= orchestrator.beat:
		push_warning("Cannot insert sequence: start_time is in the past.")
		return enter_time
	
	_add_sequence_start(sequence_copy)

	for part in sequence_copy.parts:
		var original_start := part.start_time
		part.start_time = sequence_copy.start_time + original_start
		add_note(part)

	_add_sequence_end(sequence_copy)

	return sequence_copy.start_time
#endregion

#region MIDI Compilation
func compile_chart_from_midi(
	midi_path: String,
	bpm: float,
	note_mapping: MidiNoteMapping
) -> RhythmChart:
	var parser := MidiParser.new()
	var parse_result := parser.parse_file(midi_path)
	
	if parse_result.notes.is_empty():
		push_warning("No notes found in MIDI file: " + midi_path)
		return null
	
	if not note_mapping or not note_mapping.default_note_type:
		push_error("MidiNoteMapping must have a default_note_type set")
		return null
	
	var chart := RhythmChart.new()
	chart.parts = []
	
	var ticks_per_quarter_note := parse_result.ticks_per_quarter
	var ticks_per_beat := parse_result.get_ticks_per_beat()
	var hold_threshold_beats := 0.5
	
	for midi_note in parse_result.notes:
		var note_type := note_mapping.get_note_type(midi_note.note_number)
		if not note_type:
			continue
		
		var start_beat := midi_note.start_tick / ticks_per_beat
		var duration_ticks := midi_note.duration
		var duration_beats := duration_ticks / ticks_per_beat
		
		var note := ChartPartNote.new()
		note.type = note_type
		note.start_time = start_beat
		note.name = "Note_" + str(midi_note.note_number) + "_" + str(start_beat)
		
		if duration_beats > hold_threshold_beats:
			note.hold = true
			note.hold_time = duration_beats
			
			if note_type.release_on_beat:
				var beats_per_measure: float = 4.0
				if orchestrator:
					beats_per_measure = orchestrator.beats_per_measure
				var release_beat := start_beat + duration_beats
				var quantized_release: float = ceil(release_beat / beats_per_measure) * beats_per_measure
				note.hold_time = quantized_release - start_beat
		
		chart.parts.append(note)
	
	chart.parts.sort_custom(func(a, b): return a.start_time < b.start_time)
	
	return chart
#endregion

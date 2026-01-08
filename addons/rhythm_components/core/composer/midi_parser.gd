class_name MidiParser
extends RefCounted

class MidiEvent:
	var tick: int
	var note_number: int
	var velocity: int
	var is_note_on: bool
	
	func _init(t: int, note: int, vel: int, on: bool) -> void:
		tick = t
		note_number = note
		velocity = vel
		is_note_on = on

class MidiNote:
	var start_tick: int
	var end_tick: int
	var note_number: int
	var velocity: int
	var duration: int:
		get:
			return end_tick - start_tick
	
	func _init(start: int, note: int, vel: int) -> void:
		start_tick = start
		note_number = note
		velocity = vel
		end_tick = -1

class ParseResult:
	var notes: Array[MidiNote]
	var ticks_per_quarter: int
	var time_signature_numerator: int = 4
	var time_signature_denominator: int = 4
	
	func _init(n: Array[MidiNote], tpq: int, ts_num: int = 4, ts_den: int = 4) -> void:
		notes = n
		ticks_per_quarter = tpq
		time_signature_numerator = ts_num
		time_signature_denominator = ts_den
	
	func get_ticks_per_beat() -> float:
		var quarter_notes_per_beat := 4.0 / time_signature_denominator
		return ticks_per_quarter * quarter_notes_per_beat

func parse_file(path: String) -> ParseResult:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Failed to open MIDI file: " + path)
		return ParseResult.new([], 480)
	
	var header := _parse_header_chunk(file)
	if header.is_empty():
		file.close()
		return ParseResult.new([], 480)
	
	var ticks_per_quarter := header.get("ticks_per_quarter", 480)
	var format := header.get("format", 0)
	var num_tracks := header.get("num_tracks", 0)
	
	var all_events: Array[MidiEvent] = []
	var time_sig_result := {"num": 4, "den": 4}
	
	if format == 0:
		var result := _parse_track_chunk(file, 0)
		all_events.append_array(result.events)
		if result.time_sig_num > 0:
			time_sig_result.num = result.time_sig_num
			time_sig_result.den = result.time_sig_den
	elif format == 1:
		for i in range(num_tracks):
			var result := _parse_track_chunk(file, i)
			all_events.append_array(result.events)
			if i == 0 and result.time_sig_num > 0:
				time_sig_result.num = result.time_sig_num
				time_sig_result.den = result.time_sig_den
	
	file.close()
	
	all_events.sort_custom(func(a, b): return a.tick < b.tick)
	
	var notes := _match_note_events(all_events)
	return ParseResult.new(notes, ticks_per_quarter, time_sig_result.num, time_sig_result.den)

func _parse_header_chunk(file: FileAccess) -> Dictionary:
	var magic := file.get_buffer(4).get_string_from_ascii()
	if magic != "MThd":
		push_error("Invalid MIDI file: missing MThd header")
		return {}
	
	var length := _read_uint32_be(file)
	if length != 6:
		push_error("Unexpected header length: " + str(length))
		return {}
	
	var format := _read_uint16_be(file)
	var num_tracks := _read_uint16_be(file)
	var ticks_per_quarter := _read_uint16_be(file)
	
	return {
		"format": format,
		"num_tracks": num_tracks,
		"ticks_per_quarter": ticks_per_quarter
	}

class TrackParseResult:
	var events: Array[MidiEvent]
	var time_sig_num: int = 0
	var time_sig_den: int = 0
	
	func _init(e: Array[MidiEvent], ts_num: int = 0, ts_den: int = 0) -> void:
		events = e
		time_sig_num = ts_num
		time_sig_den = ts_den

func _parse_track_chunk(file: FileAccess, track_index: int) -> TrackParseResult:
	var magic := file.get_buffer(4).get_string_from_ascii()
	if magic != "MTrk":
		push_error("Invalid track chunk at track " + str(track_index))
		return TrackParseResult.new([], 0, 0)
	
	var length := _read_uint32_be(file)
	var track_end := file.get_position() + length
	
	var events: Array[MidiEvent] = []
	var current_tick := 0
	var running_status := 0
	var time_sig_num := 0
	var time_sig_den := 0
	
	while file.get_position() < track_end:
		var delta_time := _read_vlq(file)
		current_tick += delta_time
		
		var status_byte := file.get_8()
		
		if status_byte & 0x80:
			running_status = status_byte
		else:
			file.seek(file.get_position() - 1)
			status_byte = running_status
		
		if status_byte == 0xFF:
			var meta_type := file.get_8()
			var meta_length := _read_vlq(file)
			if meta_type == 0x51:
				file.seek(file.get_position() + meta_length)
			elif meta_type == 0x58:
				var time_sig_bytes := file.get_buffer(meta_length)
				var numerator := time_sig_bytes[0]
				var denominator_power := time_sig_bytes[1]
				var denominator := int(pow(2, denominator_power))
				if current_tick == 0:
					time_sig_num = numerator
					time_sig_den = denominator
			else:
				file.seek(file.get_position() + meta_length)
			continue
		
		var event_type := status_byte & 0xF0
		var channel := status_byte & 0x0F
		
		if event_type == 0x90:
			var note_number := file.get_8()
			var velocity := file.get_8()
			if velocity > 0:
				events.append(MidiEvent.new(current_tick, note_number, velocity, true))
			else:
				events.append(MidiEvent.new(current_tick, note_number, 0, false))
		elif event_type == 0x80:
			var note_number := file.get_8()
			var velocity := file.get_8()
			events.append(MidiEvent.new(current_tick, note_number, velocity, false))
	
	return TrackParseResult.new(events, time_sig_num, time_sig_den)

func _read_vlq(file: FileAccess) -> int:
	var value := 0
	var byte := file.get_8()
	value = byte & 0x7F
	
	while byte & 0x80:
		byte = file.get_8()
		value = (value << 7) | (byte & 0x7F)
	
	return value

func _read_uint16_be(file: FileAccess) -> int:
	var b1 := file.get_8()
	var b2 := file.get_8()
	return (b1 << 8) | b2

func _read_uint32_be(file: FileAccess) -> int:
	var b1 := file.get_8()
	var b2 := file.get_8()
	var b3 := file.get_8()
	var b4 := file.get_8()
	return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4

func _match_note_events(events: Array[MidiEvent]) -> Array[MidiNote]:
	var active_notes := {}
	var notes: Array[MidiNote] = []
	
	for event in events:
		var key := str(event.note_number)
		
		if event.is_note_on:
			if active_notes.has(key):
				var old_note: MidiNote = active_notes[key]
				old_note.end_tick = event.tick
				notes.append(old_note)
			var note := MidiNote.new(event.tick, event.note_number, event.velocity)
			active_notes[key] = note
		else:
			if active_notes.has(key):
				var note: MidiNote = active_notes[key]
				note.end_tick = event.tick
				notes.append(note)
				active_notes.erase(key)
	
	for key in active_notes:
		var note: MidiNote = active_notes[key]
		if note.end_tick == -1:
			note.end_tick = note.start_tick + 1
		notes.append(note)
	
	notes.sort_custom(func(a, b): return a.start_tick < b.start_tick)
	return notes


class_name MidiNoteMapping
extends Resource

@export var mappings: Dictionary[int, ChartNoteType] = {}
@export var default_note_type: ChartNoteType

func get_note_type(midi_note_number: int) -> ChartNoteType:
	if mappings.has(midi_note_number):
		return mappings[midi_note_number] as ChartNoteType
	return default_note_type


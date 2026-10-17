extends RefCounted

const MODELS: Array[PackedScene] = [
	preload("res://assets/characters/players/man-00/MAN_00_Model.fbx"),
	preload("res://assets/characters/players/man-01/MAN_01_Model.fbx"),
	preload("res://assets/characters/players/woman-00/WOMAN_00_Model.fbx"),
	preload("res://assets/characters/players/woman-01/WOMAN_00_Model.fbx"),
]
const ALBEDO_TEXTURES: Array[Texture2D] = [
	preload("res://assets/characters/players/man-00/MAN_00_Texture.png"),
	preload("res://assets/characters/players/man-01/MAN_01_Texture.png"),
	preload("res://assets/characters/players/woman-00/WOMAN_00_Texture.png"),
	preload("res://assets/characters/players/woman-01/WOMAN_00_Texture.png"),
]
const AO_TEXTURES: Array[Texture2D] = [
	preload("res://assets/characters/players/man-00/MAN_00_AO.png"),
	preload("res://assets/characters/players/man-01/MAN_01_AO.png"),
	preload("res://assets/characters/players/woman-00/WOMAN_00_AO.png"),
	preload("res://assets/characters/players/woman-01/WOMAN_00_AO.png"),
]
const NAMES: PackedStringArray = ["Wayfinder", "Pathfinder", "Cave Scout", "Lantern Bearer"]
const COLORS: Array[Color] = [
	Color(0.22, 0.75, 0.95),
	Color(0.96, 0.42, 0.24),
	Color(0.56, 0.9, 0.38),
	Color(0.86, 0.55, 0.96),
]

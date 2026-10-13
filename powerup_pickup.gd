extends Node3D
## Small floating pickup displayed to every player in the round.

var powerup_type := "stun"
var _phase := 0.0
@onready var _visual: Node3D = $Visual

func _ready() -> void:
	_phase = randf_range(0.0, TAU)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.emission_enabled = true
	if powerup_type == "blind":
		material.albedo_color = Color(0.72, 0.25, 1.0)
		material.emission = Color(0.55, 0.08, 1.0)
	else:
		material.albedo_color = Color(0.2, 0.85, 1.0)
		material.emission = Color(0.08, 0.55, 1.0)
	material.emission_energy_multiplier = 1.5
	$Visual/Orb.material_override = material
	$Visual/Ring.material_override = material

func _process(_delta: float) -> void:
	_visual.position.y = 0.72 + sin(Time.get_ticks_msec() * 0.002 + _phase) * 0.12
	_visual.rotation.y += 0.012

func get_powerup_type() -> String:
	return powerup_type

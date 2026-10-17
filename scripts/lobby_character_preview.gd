extends Node3D
## Adds a slow turn and subtle idle motion to the lobby character portrait.

var preview_model: Node3D
var _time := 0.0

func _process(delta: float) -> void:
	if not is_instance_valid(preview_model):
		return
	_time += delta
	preview_model.rotation.y = PI + sin(_time * 0.42) * 0.16
	preview_model.position.y = sin(_time * 1.4) * 0.025

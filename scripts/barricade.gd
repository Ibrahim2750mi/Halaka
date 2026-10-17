extends StaticBody3D
## Temporary multiplayer wall spawned by the barricade gun.

var lifetime := 10.0

func _ready() -> void:
	if multiplayer.is_server():
		get_tree().create_timer(lifetime).timeout.connect(queue_free)

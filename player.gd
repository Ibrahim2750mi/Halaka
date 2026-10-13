extends CharacterBody3D
## Each player controls only their own avatar. MultiplayerSynchronizer shares its transform.

@export var move_speed := 5.0
@export var jump_speed := 4.5
@export var mouse_sensitivity := 0.0025
@export var gravity := 18.0

@onready var camera: Camera3D = $Camera3D
@onready var visual: MeshInstance3D = $Visual
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var flashlight: SpotLight3D = $Camera3D/Flashlight
@onready var local_beam: MeshInstance3D = $Camera3D/LocalBeam
var owner_peer_id := 1
var round_active := false
var is_alive := true
var score := 0.0
var total_alive_time := 0.0
var respawn_remaining := 0.0
var held_powerup := ""
var stun_remaining := 0.0
var blind_remaining := 0.0
var wall_travel_remaining := 0.0
var _camera_pitch := 0.0
var _camera_yaw := 0.0
var _smoothed_camera_position := Vector3.ZERO
var _camera_follow_ready := false
var _remote_input := Vector2.ZERO
var _remote_yaw := 0.0
var _remote_pitch := 0.0
var _remote_jump := false
var _input_send_timer := 0.0
var _death_label: Label
var _powerup_label: Label
var _crosshair: Label
var _stun_beam: MeshInstance3D
var _blind_overlay: ColorRect
var _powerup_feedback := ""
var _powerup_feedback_time := 0.0
var _stun_beam_time := 0.0
var _last_alive_state := true

func _ready() -> void:
	var is_local := _is_local_player()
	camera.current = is_local
	if is_local:
		camera.make_current()
		_camera_yaw = rotation.y
		_smoothed_camera_position = global_position + Vector3.UP * 1.55
		_camera_follow_ready = true
	flashlight.visible = true
	flashlight.position = Vector3(0.0, -0.05, -0.2)
	flashlight.light_energy = 5.0
	flashlight.spot_range = 20.0
	flashlight.spot_angle = 42.0
	flashlight.light_volumetric_fog_energy = 0.0
	flashlight.shadow_enabled = false
	local_beam.visible = is_local
	visual.visible = not is_local
	var player_colors: Array[Color] = [Color(0.22, 0.75, 0.95), Color(0.96, 0.42, 0.24), Color(0.56, 0.9, 0.38), Color(0.86, 0.55, 0.96)]
	var player_material := StandardMaterial3D.new()
	player_material.albedo_color = player_colors[(owner_peer_id - 1) % player_colors.size()]
	visual.material_override = player_material
	_last_alive_state = is_alive
	_apply_alive_state(is_local)
	if is_local:
		_create_death_overlay()
		_create_powerup_hud()
		_create_blind_overlay()
	if is_local and multiplayer.has_multiplayer_peer():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	add_to_group("players")

func _process(delta: float) -> void:
	var is_local := _is_local_player()
	if is_local and _camera_follow_ready:
		var camera_target: Vector3 = global_position + Vector3.UP * 1.55
		if _smoothed_camera_position.distance_to(camera_target) > 3.0:
			_smoothed_camera_position = camera_target
		else:
			_smoothed_camera_position = _smoothed_camera_position.lerp(camera_target, 1.0 - exp(-24.0 * delta))
		camera.global_position = _smoothed_camera_position
		# Restore local yaw after server snapshots so the camera and movement stay aligned.
		rotation.y = _camera_yaw
		camera.rotation = Vector3(_camera_pitch, 0.0, 0.0)
	if is_alive != _last_alive_state:
		_apply_alive_state(is_local)
		_last_alive_state = is_alive
	if _death_label != null:
		_death_label.visible = not is_alive
		if not is_alive:
			_death_label.text = "CAUGHT  |  Respawning in %d" % ceili(respawn_remaining)
	if _powerup_label != null:
		_powerup_feedback_time = maxf(0.0, _powerup_feedback_time - delta)
		if _powerup_feedback_time > 0.0:
			_powerup_label.text = _powerup_feedback
		else:
			_powerup_label.text = _powerup_hud_text()
	if _blind_overlay != null:
		_blind_overlay.visible = is_local and blind_remaining > 0.0
	if _stun_beam != null and _stun_beam_time > 0.0:
		_stun_beam_time = maxf(0.0, _stun_beam_time - delta)
		var beam_material := _stun_beam.material_override as StandardMaterial3D
		var fade := _stun_beam_time / 0.18
		beam_material.albedo_color.a = 0.82 * fade
		beam_material.emission_energy_multiplier = 2.0 * fade
		_stun_beam.visible = _stun_beam_time > 0.0

func _is_local_player() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return multiplayer.get_unique_id() == owner_peer_id

func _apply_alive_state(is_local: bool) -> void:
	visual.visible = not is_local and is_alive
	camera.current = is_local
	collision_shape.set_deferred("disabled", not is_alive)
	if not is_alive:
		velocity = Vector3.ZERO

func _create_death_overlay() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "DeathOverlay"
	add_child(canvas)
	_death_label = Label.new()
	_death_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_death_label.position.y = 48.0
	_death_label.add_theme_font_size_override("font_size", 28)
	_death_label.add_theme_color_override("font_color", Color(0.95, 0.22, 0.16))
	_death_label.visible = false
	canvas.add_child(_death_label)

func _create_powerup_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "PowerupHUD"
	add_child(canvas)
	_powerup_label = Label.new()
	_powerup_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_powerup_label.offset_top = -62.0
	_powerup_label.offset_bottom = -28.0
	_powerup_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_powerup_label.add_theme_font_size_override("font_size", 20)
	_powerup_label.add_theme_color_override("font_color", Color(0.75, 0.95, 1.0))
	canvas.add_child(_powerup_label)
	_crosshair = Label.new()
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_crosshair.position = Vector2(-14.0, -18.0)
	_crosshair.custom_minimum_size = Vector2(28.0, 36.0)
	_crosshair.text = "+"
	_crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_crosshair.add_theme_font_size_override("font_size", 26)
	_crosshair.add_theme_color_override("font_color", Color(0.82, 1.0, 1.0, 0.9))
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_crosshair)
	_stun_beam = MeshInstance3D.new()
	_stun_beam.name = "StunBeam"
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 0.018
	beam_mesh.bottom_radius = 0.045
	beam_mesh.height = 1.0
	beam_mesh.radial_segments = 8
	_stun_beam.mesh = beam_mesh
	var beam_material := StandardMaterial3D.new()
	beam_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_material.albedo_color = Color(0.22, 0.86, 1.0, 0.82)
	beam_material.emission_enabled = true
	beam_material.emission = Color(0.08, 0.62, 1.0)
	beam_material.emission_energy_multiplier = 2.0
	_stun_beam.material_override = beam_material
	_stun_beam.visible = false
	camera.add_child(_stun_beam)

func _powerup_hud_text() -> String:
	match held_powerup:
		"stun":
			return "Stun gun  |  1 shot  |  Left click to fire"
		"blind":
			return "Blind gun  |  1 shot  |  Left click to fire"
		"barricade":
			return "Barricade gun  |  1 shot  |  Left click to deploy"
		"wall_travel":
			return "Wall travel  |  1 use  |  3 seconds"
		_:
			return "Power-up: empty"

func _create_blind_overlay() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "BlindOverlay"
	canvas.layer = 20
	add_child(canvas)
	_blind_overlay = ColorRect.new()
	_blind_overlay.name = "Blackout"
	_blind_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blind_overlay.color = Color.BLACK
	_blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blind_overlay.visible = false
	canvas.add_child(_blind_overlay)

func _unhandled_input(event: InputEvent) -> void:
	if not _is_local_player():
		return
	if not is_alive:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var yaw_delta: float = -event.relative.x * mouse_sensitivity
		rotate_y(yaw_delta)
		_camera_yaw += yaw_delta
		_camera_pitch = clampf(_camera_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-85.0), deg_to_rad(85.0))
		camera.rotation.x = _camera_pitch
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if multiplayer.is_server():
			_request_powerup_use()
		else:
			_request_powerup_use_rpc.rpc_id(1, rotation.y, _camera_pitch)
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not _network_is_active():
		return
	_update_wall_travel_collision()
	if not round_active or not is_alive or stun_remaining > 0.0:
		velocity = Vector3.ZERO
		return
	if multiplayer.is_server():
		var server_input := _read_move_input() if owner_peer_id == 1 else _remote_input
		if owner_peer_id != 1:
			rotation.y = _remote_yaw
			camera.rotation.x = _remote_pitch
		var server_jump := Input.is_key_pressed(KEY_SPACE) if owner_peer_id == 1 else _remote_jump
		_simulate_movement(delta, server_input, server_jump)
	elif _is_local_player():
		var predicted_input := _read_move_input()
		var jump_pressed := Input.is_key_pressed(KEY_SPACE)
		_simulate_movement(delta, predicted_input, jump_pressed)
		_input_send_timer -= delta
		if _input_send_timer <= 0.0:
			_submit_input.rpc_id(1, predicted_input, rotation.y, _camera_pitch, jump_pressed)
			_input_send_timer = 1.0 / 30.0

func _update_wall_travel_collision() -> void:
	# Layer 1 keeps the floor solid; layer 2 contains cave walls.
	collision_mask = 1 if wall_travel_remaining > 0.0 else 3

func _network_is_active() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func _request_powerup_use() -> void:
	if multiplayer.is_server():
		var game := get_tree().current_scene
		if game.has_method("use_powerup_for_player"):
			game.use_powerup_for_player(self)

@rpc("authority", "reliable")
func _show_powerup_feedback(message: String) -> void:
	_powerup_feedback = message
	_powerup_feedback_time = 1.5

@rpc("authority", "reliable")
func _show_powerup_beam(world_end: Vector3, beam_color: Color) -> void:
	if not _is_local_player() or _stun_beam == null:
		return
	var start_local := Vector3(0.14, -0.1, -0.25)
	var end_local := camera.to_local(world_end)
	var beam_vector := end_local - start_local
	if beam_vector.length_squared() < 0.01:
		return
	_stun_beam.position = (start_local + end_local) * 0.5
	var beam_material := _stun_beam.material_override as StandardMaterial3D
	beam_material.albedo_color = Color(beam_color.r, beam_color.g, beam_color.b, 0.82)
	beam_material.emission = beam_color
	_stun_beam.quaternion = Quaternion(Vector3.UP, beam_vector.normalized())
	_stun_beam.scale = Vector3.ONE
	_stun_beam.scale.y = beam_vector.length()
	_stun_beam_time = 0.18
	_stun_beam.visible = true

@rpc("any_peer", "reliable")
func _request_powerup_use_rpc(body_yaw: float, camera_pitch: float) -> void:
	if not multiplayer.is_server() or multiplayer.get_remote_sender_id() != owner_peer_id:
		return
	rotation.y = body_yaw
	_camera_pitch = clampf(camera_pitch, deg_to_rad(-85.0), deg_to_rad(85.0))
	camera.rotation.x = _camera_pitch
	_request_powerup_use()

func _simulate_movement(delta: float, move_input: Vector2, jump_pressed: bool) -> void:
	move_input = move_input.normalized()
	var move_direction: Vector3 = global_basis.x * move_input.x + global_basis.z * move_input.y
	velocity.x = move_direction.x * move_speed
	velocity.z = move_direction.z * move_speed
	if is_on_floor():
		if jump_pressed:
			velocity.y = jump_speed
	else:
		velocity.y -= gravity * delta
	move_and_slide()

func _read_move_input() -> Vector2:
	var move_input := Vector2.ZERO
	if Input.is_key_pressed(KEY_A):
		move_input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		move_input.x += 1.0
	if Input.is_key_pressed(KEY_W):
		move_input.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		move_input.y += 1.0
	return move_input.normalized()

@rpc("any_peer", "unreliable")
func _submit_input(move_input: Vector2, body_yaw: float, camera_pitch: float, jump_pressed: bool) -> void:
	if not multiplayer.is_server() or multiplayer.get_remote_sender_id() != owner_peer_id:
		return
	_remote_input = move_input
	_remote_yaw = body_yaw
	_remote_pitch = camera_pitch
	_remote_jump = jump_pressed

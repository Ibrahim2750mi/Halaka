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
var _camera_pitch := 0.0
var _remote_input := Vector2.ZERO
var _remote_yaw := 0.0
var _remote_pitch := 0.0
var _remote_jump := false
var _input_send_timer := 0.0
var _death_label: Label
var _last_alive_state := true

func _ready() -> void:
	var is_local := _is_local_player()
	camera.current = is_local
	if is_local:
		camera.make_current()
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
	if is_local and multiplayer.has_multiplayer_peer():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	add_to_group("players")

func _process(_delta: float) -> void:
	var is_local := _is_local_player()
	if is_alive != _last_alive_state:
		_apply_alive_state(is_local)
		_last_alive_state = is_alive
	if _death_label != null:
		_death_label.visible = not is_alive
		if not is_alive:
			_death_label.text = "CAUGHT  |  Respawning in %d" % ceili(respawn_remaining)

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

func _unhandled_input(event: InputEvent) -> void:
	if not _is_local_player():
		return
	if not is_alive:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_camera_pitch = clampf(_camera_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-85.0), deg_to_rad(85.0))
		camera.rotation.x = _camera_pitch
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not _network_is_active():
		return
	if not round_active or not is_alive:
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

func _network_is_active() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func _simulate_movement(delta: float, move_input: Vector2, jump_pressed: bool) -> void:
	move_input = move_input.normalized()
	var move_direction := global_basis.x * move_input.x + global_basis.z * move_input.y
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

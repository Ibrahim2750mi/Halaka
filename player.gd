extends CharacterBody3D
## Each player controls only their own avatar. MultiplayerSynchronizer shares its transform.

const CHARACTER_SCENES: Array[PackedScene] = [
	preload("res://MAN_00/MAN_00_Model.fbx"),
	preload("res://MAN_01/MAN_01_Model.fbx"),
	preload("res://WOMAN_00/WOMAN_00_Model.fbx"),
	preload("res://WOMAN_01/WOMAN_00_Model.fbx"),
]
const CHARACTER_ALBEDO_TEXTURES: Array[Texture2D] = [
	preload("res://MAN_00/MAN_00_Texture.png"),
	preload("res://MAN_01/MAN_01_Texture.png"),
	preload("res://WOMAN_00/WOMAN_00_Texture.png"),
	preload("res://WOMAN_01/WOMAN_00_Texture.png"),
]
const CHARACTER_AO_TEXTURES: Array[Texture2D] = [
	preload("res://MAN_00/MAN_00_AO.png"),
	preload("res://MAN_01/MAN_01_AO.png"),
	preload("res://WOMAN_00/WOMAN_00_AO.png"),
	preload("res://WOMAN_01/WOMAN_00_AO.png"),
]

@export var move_speed := 5.0
@export var jump_speed := 4.5
@export var mouse_sensitivity := 0.0025
@export var gravity := 18.0

@onready var camera: Camera3D = $Camera3D
@onready var visual: MeshInstance3D = $Visual
@onready var character_model: Node3D = $CharacterModel
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var flashlight: SpotLight3D = $Camera3D/Flashlight
@onready var local_beam: MeshInstance3D = $Camera3D/LocalBeam
var owner_peer_id := 1
var character_index := 0
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
var _character_asset_loaded := false
var _character_skeleton: Skeleton3D
var _animated_bone_indices: Dictionary = {}
var _base_bone_rotations: Dictionary = {}
var _animation_clock := 0.0
var _animation_speed := 0.0
var _last_animation_position := Vector3.ZERO

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
	character_index = clampi(character_index, 0, CHARACTER_SCENES.size() - 1)
	var character_scene: PackedScene = CHARACTER_SCENES[character_index]
	var character_instance: Node = character_scene.instantiate()
	character_model.add_child(character_instance)
	_apply_character_textures(CHARACTER_ALBEDO_TEXTURES[character_index], CHARACTER_AO_TEXTURES[character_index])
	character_model.scale = Vector3.ONE
	# The imported characters face +Z; turn their front toward Godot's -Z forward.
	character_model.rotation.y = PI
	_character_asset_loaded = true
	var skeleton_nodes: Array[Node] = character_model.find_children("*", "Skeleton3D", true, false)
	if not skeleton_nodes.is_empty():
		_character_skeleton = skeleton_nodes[0] as Skeleton3D
	_cache_animation_bones()
	_last_animation_position = global_position
	visual.visible = not is_local and not _character_asset_loaded
	var player_colors: Array[Color] = [Color(0.22, 0.75, 0.95), Color(0.96, 0.42, 0.24), Color(0.56, 0.9, 0.38), Color(0.86, 0.55, 0.96)]
	var player_material := StandardMaterial3D.new()
	player_material.albedo_color = player_colors[character_index % player_colors.size()]
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
	_update_procedural_animation(delta)
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

func _cache_animation_bones() -> void:
	if _character_skeleton == null:
		return
	for bone_name in ["thigh.L", "thigh.R", "shin.L", "shin.R", "upper_arm.L", "upper_arm.R", "forearm.L", "forearm.R", "spine.001"]:
		var bone_index: int = _character_skeleton.find_bone(bone_name)
		if bone_index >= 0:
			_animated_bone_indices[bone_name] = bone_index
			_base_bone_rotations[bone_name] = _character_skeleton.get_bone_pose_rotation(bone_index)

func _apply_character_textures(albedo_texture: Texture2D, ao_texture: Texture2D) -> void:
	var mesh_nodes: Array[Node] = character_model.find_children("*", "MeshInstance3D", true, false)
	for node in mesh_nodes:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface_index in range(mesh_instance.mesh.get_surface_count()):
			var source_material: Material = mesh_instance.get_active_material(surface_index)
			var character_material := StandardMaterial3D.new()
			if source_material is StandardMaterial3D:
				character_material = (source_material as StandardMaterial3D).duplicate() as StandardMaterial3D
			character_material.albedo_texture = albedo_texture
			character_material.ao_enabled = true
			character_material.ao_texture = ao_texture
			character_material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			mesh_instance.set_surface_override_material(surface_index, character_material)

func _update_procedural_animation(delta: float) -> void:
	if not _character_asset_loaded or _character_skeleton == null:
		return
	var safe_delta: float = maxf(delta, 0.001)
	var position_delta: Vector3 = global_position - _last_animation_position
	_last_animation_position = global_position
	var measured_speed: float = Vector2(position_delta.x, position_delta.z).length() / safe_delta
	measured_speed = minf(measured_speed, maxf(move_speed, 0.1) * 1.25)
	var speed_blend: float = 1.0 - exp(-12.0 * safe_delta)
	_animation_speed = lerpf(_animation_speed, measured_speed, speed_blend)
	var walk_weight: float = clampf((_animation_speed - 0.18) / maxf(move_speed * 0.72, 0.1), 0.0, 1.0) if is_alive else 0.0
	if not is_alive:
		_animation_speed = 0.0
	_animation_clock += safe_delta
	var gait_phase: float = _animation_clock * TAU * 1.8
	var leg_cycle: float = sin(gait_phase)
	var leg_swing: float = leg_cycle * 0.42 * walk_weight
	var arm_swing: float = sin(gait_phase + PI) * 0.62 * walk_weight
	character_model.position.y = sin(_animation_clock * 2.2) * 0.008 + maxf(0.0, sin(gait_phase * 2.0)) * 0.045 * walk_weight
	character_model.rotation.z = sin(gait_phase) * 0.025 * walk_weight

	# The imported T-pose bones have their own rest axes. Apply offsets after each rest rotation.
	_set_procedural_bone_rotation("thigh.L", Quaternion(Vector3.RIGHT, leg_swing))
	_set_procedural_bone_rotation("thigh.R", Quaternion(Vector3.RIGHT, -leg_swing))
	_set_procedural_bone_rotation("shin.L", Quaternion(Vector3.RIGHT, maxf(0.0, -leg_cycle) * 0.65 * walk_weight))
	_set_procedural_bone_rotation("shin.R", Quaternion(Vector3.RIGHT, maxf(0.0, leg_cycle) * 0.65 * walk_weight))
	_set_procedural_bone_rotation("spine.001", Quaternion(Vector3.RIGHT, -0.04 * walk_weight))

	# Rest the hands beside the hips, then swing both arms opposite the legs while running.
	var left_shoulder_idle := Quaternion(Vector3.BACK, -1.3)
	var right_shoulder_idle := Quaternion(Vector3.BACK, 1.3)
	_set_procedural_bone_rotation("upper_arm.L", left_shoulder_idle)
	_set_procedural_bone_rotation("upper_arm.R", right_shoulder_idle)
	_character_skeleton.force_update_all_bone_transforms()
	var side_axis: Vector3 = _model_right_in_skeleton_space()
	var left_arm_axis: Vector3 = _bone_local_axis("upper_arm.L", side_axis)
	var right_arm_axis: Vector3 = _bone_local_axis("upper_arm.R", side_axis)
	_set_procedural_bone_rotation("upper_arm.L", left_shoulder_idle * Quaternion(left_arm_axis, arm_swing))
	_set_procedural_bone_rotation("upper_arm.R", right_shoulder_idle * Quaternion(right_arm_axis, -arm_swing))
	_character_skeleton.force_update_all_bone_transforms()
	var left_elbow_axis: Vector3 = _bone_local_axis("forearm.L", side_axis)
	var right_elbow_axis: Vector3 = _bone_local_axis("forearm.R", side_axis)
	var elbow_bend: float = -0.75 - 0.1 * walk_weight
	_set_procedural_bone_rotation("forearm.L", Quaternion(left_elbow_axis, elbow_bend))
	_set_procedural_bone_rotation("forearm.R", Quaternion(right_elbow_axis, elbow_bend))

func _model_right_in_skeleton_space() -> Vector3:
	var model_right_global: Vector3 = character_model.global_basis.x.normalized()
	var skeleton_basis: Basis = _character_skeleton.global_basis.orthonormalized()
	return (skeleton_basis.inverse() * model_right_global).normalized()

func _bone_local_axis(bone_name: String, skeleton_axis: Vector3) -> Vector3:
	var bone_index: int = int(_animated_bone_indices.get(bone_name, -1))
	if bone_index < 0:
		return Vector3.RIGHT
	var bone_pose: Transform3D = _character_skeleton.get_bone_global_pose(bone_index)
	return (bone_pose.basis.orthonormalized().inverse() * skeleton_axis).normalized()

func _set_procedural_bone_rotation(bone_name: String, offset: Quaternion) -> void:
	if _character_skeleton == null or not _animated_bone_indices.has(bone_name):
		return
	var bone_index: int = int(_animated_bone_indices[bone_name])
	var base_rotation: Quaternion = _base_bone_rotations[bone_name]
	_character_skeleton.set_bone_pose_rotation(bone_index, base_rotation * offset)

func _is_local_player() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return multiplayer.get_unique_id() == owner_peer_id

func _apply_alive_state(is_local: bool) -> void:
	visual.visible = not is_local and is_alive and not _character_asset_loaded
	character_model.visible = not is_local and is_alive and _character_asset_loaded
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

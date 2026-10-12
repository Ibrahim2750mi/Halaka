@tool
extends StaticBody3D
## Godot 4 version of the procedural maze asset.

@export_range(2, 100, 1) var size_x := 8:
	set(value):
		size_x = value
		if is_inside_tree():
			generate()
@export_range(2, 100, 1) var size_y := 8:
	set(value):
		size_y = value
		if is_inside_tree():
			generate()
@export_range(1.0, 20.0, 0.1) var corridor_width := 6.0:
	set(value):
		corridor_width = value
		if is_inside_tree():
			generate()
@export_range(0.05, 1.0, 0.05) var wall_width := 0.2:
	set(value):
		wall_width = value
		if is_inside_tree():
			generate()
@export_range(1.0, 10.0, 0.1) var height := 2.5:
	set(value):
		height = value
		if is_inside_tree():
			generate()
@export var random_seed := 1:
	set(value):
		random_seed = value
		if is_inside_tree():
			generate()
const DIRECTIONS := [Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1)]
const OPPOSITE := [2, 3, 0, 1]
const CORRIDOR_ASSET: PackedScene = preload("res://kenney_modular-cave-kit_1.0/Models/GLB format/corridor.glb")
const CORNER_ASSET: PackedScene = preload("res://kenney_modular-cave-kit_1.0/Models/GLB format/corridor-corner.glb")
const END_ASSET: PackedScene = preload("res://kenney_modular-cave-kit_1.0/Models/GLB format/corridor-end.glb")
const JUNCTION_ASSET: PackedScene = preload("res://kenney_modular-cave-kit_1.0/Models/GLB format/corridor-junction.glb")
const INTERSECTION_ASSET: PackedScene = preload("res://kenney_modular-cave-kit_1.0/Models/GLB format/corridor-intersection.glb")
const FLOOR_ASSET: PackedScene = preload("res://kenney_modular-cave-kit_1.0/Models/GLB format/template-floor.glb")
var _cells: Array = []

func _ready() -> void:
	generate()

func generate() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_cells.clear()
	for x in range(size_x):
		var column: Array[int] = []
		column.resize(size_y)
		_cells.append(column)
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var visited := {}
	var stack: Array[Vector2i] = [Vector2i(0, 0)]
	visited[Vector2i(0, 0)] = true
	while not stack.is_empty():
		var current: Vector2i = stack.back()
		var choices: Array[int] = []
		for direction in range(4):
			var next_cell: Vector2i = current + DIRECTIONS[direction]
			if next_cell.x >= 0 and next_cell.x < size_x and next_cell.y >= 0 and next_cell.y < size_y and not visited.has(next_cell):
				choices.append(direction)
		if choices.is_empty():
			stack.pop_back()
			continue
		var direction: int = choices[rng.randi_range(0, choices.size() - 1)]
		var next_cell: Vector2i = current + DIRECTIONS[direction]
		_cells[current.x][current.y] |= 1 << direction
		_cells[next_cell.x][next_cell.y] |= 1 << OPPOSITE[direction]
		visited[next_cell] = true
		stack.append(next_cell)
	_build_geometry()

func _build_geometry() -> void:
	# Kenney's cave tiles are 4x4 units, so the procedural grid follows their module size.
	var pitch := corridor_width
	var origin := Vector3(-0.5 * size_x * pitch + 0.5 * pitch, 0.0, -0.5 * size_y * pitch + 0.5 * pitch)
	_add_collision_box("CaveFloorCollision", Vector3(size_x * pitch, 0.2, size_y * pitch), Vector3(0.0, -0.1, 0.0))
	for x in range(size_x):
		for y in range(size_y):
			var center := origin + Vector3(x * pitch, 0.0, y * pitch)
			var floor_tile: Node3D = FLOOR_ASSET.instantiate()
			floor_tile.name = "CaveFloor_%d_%d" % [x, y]
			floor_tile.position = center + Vector3(0.0, -0.03, 0.0)
			floor_tile.scale = Vector3(pitch / 4.0, 1.0, pitch / 4.0)
			add_child(floor_tile)
			floor_tile.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null
			var openings: int = _cells[x][y]
			var tile_choice := _tile_for_openings(openings)
			var cave_tile: Node3D = tile_choice.scene.instantiate()
			cave_tile.name = "CaveTile_%d_%d" % [x, y]
			cave_tile.position = center
			cave_tile.scale = Vector3(pitch / 4.0, 1.0, pitch / 4.0)
			cave_tile.rotation.y = tile_choice.rotation
			add_child(cave_tile)
			cave_tile.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null
			if not Engine.is_editor_hint():
				_add_mesh_collisions(cave_tile)

func _tile_for_openings(openings: int) -> Dictionary:
	var degree := 0
	for direction in range(4):
		if openings & (1 << direction):
			degree += 1
	var asset: PackedScene
	var base_mask: int
	match degree:
		1:
			asset = END_ASSET
			base_mask = 1 << 2
		2:
			if openings == 0b0101 or openings == 0b1010:
				asset = CORRIDOR_ASSET
				base_mask = 0b0101
			else:
				asset = CORNER_ASSET
				base_mask = 0b1100
		3:
			asset = JUNCTION_ASSET
			base_mask = 0b1101
		_:
			asset = INTERSECTION_ASSET
			base_mask = 0b1111
	for turns in range(4):
		if _rotate_openings(base_mask, turns) == openings:
			return {"scene": asset, "rotation": turns * PI * 0.5}
	return {"scene": asset, "rotation": 0.0}

func _rotate_openings(mask: int, turns: int) -> int:
	var rotated := 0
	for direction in range(4):
		if mask & (1 << direction):
			rotated |= 1 << ((direction - turns + 4) % 4)
	return rotated

func _add_collision_box(node_name: String, box_size: Vector3, position: Vector3) -> void:
	var collision := CollisionShape3D.new()
	collision.name = node_name
	var shape := BoxShape3D.new()
	shape.size = box_size
	collision.shape = shape
	collision.position = position
	add_child(collision)
	collision.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null

func _add_mesh_collisions(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh != null:
			child.create_trimesh_collision()
		_add_mesh_collisions(child)

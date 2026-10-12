extends Node3D
## Small LAN lobby and server-side player spawning for the maze prototype.

const GAME_PORT := 2456
const MAX_REMOTE_PLAYERS := 3
const PLAYER_SCENE: PackedScene = preload("res://player.tscn")

@onready var maze: Node = $Maze
@onready var players: Node3D = $Players
@onready var player_spawner: MultiplayerSpawner = $Players/MultiplayerSpawner

var _lobby_panel: PanelContainer
var _address_input: LineEdit
var _status_label: Label
var _player_list_label: Label
var _status_message := "Waiting for a host."

func _ready() -> void:
	player_spawner.spawn_function = _spawn_player
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	player_spawner.spawned.connect(_on_player_spawned)
	player_spawner.despawned.connect(_on_player_despawned)
	_build_lobby_ui()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _build_lobby_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "LobbyUI"
	add_child(canvas)
	_lobby_panel = PanelContainer.new()
	_lobby_panel.position = Vector2(28, 28)
	_lobby_panel.custom_minimum_size = Vector2(340, 0)
	canvas.add_child(_lobby_panel)
	var layout := VBoxContainer.new()
	_lobby_panel.add_child(layout)
	var title := Label.new()
	title.text = "CAVE HUNT  |  2–4 PLAYERS"
	layout.add_child(title)
	var instructions := Label.new()
	instructions.text = "Host a game or enter the host's LAN address."
	layout.add_child(instructions)
	_address_input = LineEdit.new()
	_address_input.placeholder_text = "Host IP address"
	_address_input.text = "127.0.0.1"
	layout.add_child(_address_input)
	var buttons := HBoxContainer.new()
	layout.add_child(buttons)
	var host_button := Button.new()
	host_button.text = "Host Game"
	host_button.pressed.connect(_host_game)
	buttons.add_child(host_button)
	var join_button := Button.new()
	join_button.text = "Join Game"
	join_button.pressed.connect(_join_game)
	buttons.add_child(join_button)
	_status_label = Label.new()
	_status_label.position = Vector2(28, 190)
	canvas.add_child(_status_label)
	_player_list_label = Label.new()
	_player_list_label.position = Vector2(28, 220)
	canvas.add_child(_player_list_label)
	_refresh_player_list()

func _host_game() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(GAME_PORT, MAX_REMOTE_PLAYERS)
	if error != OK:
		_set_status("Couldn't host: %s" % error_string(error))
		return
	multiplayer.multiplayer_peer = peer
	_spawn_peer(1)
	_lobby_panel.hide()
	_refresh_status("Hosting on port %d" % GAME_PORT)

func _join_game() -> void:
	var address := _address_input.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, GAME_PORT)
	if error != OK:
		_set_status("Couldn't connect: %s" % error_string(error))
		return
	multiplayer.multiplayer_peer = peer
	_set_status("Connecting to %s:%d..." % [address, GAME_PORT])

func _spawn_peer(peer_id: int) -> void:
	if multiplayer.is_server():
		player_spawner.spawn({"peer_id": peer_id})

func _spawn_player(data: Variant) -> Node:
	var peer_id := int(data.get("peer_id", 1))
	var player := PLAYER_SCENE.instantiate()
	player.name = "Player_%d" % peer_id
	player.owner_peer_id = peer_id
	player.set_multiplayer_authority(1, true)
	var spawn_offsets := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	var offset: Vector2i = spawn_offsets[(peer_id - 1) % spawn_offsets.size()]
	player.position = maze.cell_to_world(Vector2i(24, 24) + offset) + Vector3(0, 0.1, 0)
	return player

func _on_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		_spawn_peer(peer_id)
		_refresh_status("Player %d joined" % peer_id)
	else:
		_refresh_player_list.call_deferred()

func _on_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server():
		var player := players.get_node_or_null("Player_%d" % peer_id)
		if player != null:
			player_spawner.despawn(player)
			_refresh_status.call_deferred("Player %d left" % peer_id)
	else:
		_refresh_player_list.call_deferred()

func _on_player_spawned(_player: Node) -> void:
	_refresh_player_list.call_deferred()

func _on_player_despawned(_player: Node) -> void:
	_refresh_player_list.call_deferred()

func _on_connected_to_server() -> void:
	_lobby_panel.hide()
	_refresh_status("Connected to host")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_connection_failed() -> void:
	_set_status("Connection failed. Check the host IP and port %d." % GAME_PORT)
	multiplayer.multiplayer_peer = null

func _on_server_disconnected() -> void:
	_set_status("Host disconnected.")
	_lobby_panel.show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _refresh_status(message: String) -> void:
	_status_message = message
	_refresh_player_list()

func _refresh_player_list() -> void:
	if _player_list_label == null:
		return
	var active_players := get_tree().get_nodes_in_group("players")
	active_players.sort_custom(func(a: Node, b: Node) -> bool: return a.owner_peer_id < b.owner_peer_id)
	var lines: PackedStringArray = ["Players (%d/4):" % active_players.size()]
	for player in active_players:
		var entry := "Player %d" % player.owner_peer_id
		if player.owner_peer_id == multiplayer.get_unique_id():
			entry += " (you)"
		lines.append(entry)
	if active_players.is_empty():
		lines.append("Waiting for players...")
	_player_list_label.text = "\n".join(lines)
	_render_status()

func _set_status(message: String) -> void:
	_status_message = message
	_render_status()

func _render_status() -> void:
	if _status_label != null:
		var player_count := get_tree().get_nodes_in_group("players").size()
		_status_label.text = "%s  |  Players: %d/4" % [_status_message, player_count]

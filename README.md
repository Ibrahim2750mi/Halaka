# Halaka

Halaka is a Godot 4 multiplayer maze game. The project uses a generated cave maze, LAN multiplayer, a chasing monster, player characters, and collectible powerups.

## Project layout

- `scripts/` — game scripts
- `scenes/` — game scenes
- `assets/characters/` — player and monster characters
- `assets/environment/` — Kenney cave kit
- `addons/procedural_maze/` — maze generation and layout code

## Run the project

Open this folder in Godot 4.7 or later and run the main scene. The project currently uses Godot's Jolt 3D physics engine.

## Controls

- **W A S D** — move
- **Space** — jump
- **Mouse** — look
- **Left mouse button** — use a held powerup
- **Escape** — release the mouse

The first player hosts a LAN game; other players join using the host's IP address.

## License scope

The root `LICENSE` contains GNU GPL version 3.0 terms for the Halaka project code. It does not relicense third-party art, models, textures, addons, or other assets. See [ASSET_CREDITS.md](ASSET_CREDITS.md) for the asset-by-asset terms and known limits.

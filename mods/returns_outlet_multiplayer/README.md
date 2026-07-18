# Returns Outlet Multiplayer Mod

A lightweight, engine-agnostic multiplayer mod scaffold for **Returns Outlet Simulator**. It runs an authoritative TCP JSON-lines relay that game-side scripts can use to synchronize shoppers in a shared outlet session.

## Features

- Up to 8 players per lobby by default.
- Player join, leave, ready-state, transform, and chat replication.
- Authoritative pallet claiming so two players cannot claim the same return pallet.
- Deterministic lobby snapshots for late joiners and reconnects.
- No third-party Python dependencies.

## Running the server

```bash
cd mods/returns_outlet_multiplayer
python3 server.py --host 127.0.0.1 --port 8765 --max-players 8
```

## Game integration contract

Connect a TCP client to the server and send newline-delimited JSON messages. The first message must be:

```json
{"type":"join","name":"Player Name"}
```

The server replies with `welcome`, including the assigned `player_id` and a full lobby `snapshot`. Supported client messages are:

| Message | Required fields | Purpose |
| --- | --- | --- |
| `move` | `x`, `y`, `rotation` | Replicates a player's store-floor transform. |
| `ready` | `ready` | Updates lobby ready state. |
| `claim_pallet` | `pallet_id` | Atomically claims a pallet for the caller. |
| `chat` | `text` | Broadcasts short in-lobby chat. |
| `snapshot` | none | Requests a fresh authoritative snapshot. |

Server broadcasts include `player_joined`, `player_left`, `player_moved`, `player_ready`, `pallet_claimed`, and `chat`.

## Local smoke client

With the server running in another terminal:

```bash
cd mods/returns_outlet_multiplayer
python3 client_example.py --name "Demo Buyer"
```

## Suggested in-game hooks

1. Start or discover the relay from the game's mod loader.
2. Send `join` after the player selects a display name.
3. Send throttled `move` updates from the player controller, ideally 10-20 times per second.
4. Disable local pallet ownership changes until the server confirms `pallet_claimed`.
5. Rebuild lobby UI from `welcome.snapshot` and any later `snapshot` response.

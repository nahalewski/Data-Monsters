#!/usr/bin/env python3
"""Authoritative TCP JSON-lines multiplayer relay for Returns Outlet Simulator.

This mod is intentionally engine-agnostic: a game-side plugin can connect to this
process and mirror player transforms, pallet claims, ready state, and chat.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import secrets
from typing import Dict, Optional

from protocol import MAX_PLAYERS, Player, ProtocolError, default_pallets, decode_message, encode_message, lobby_snapshot


class MultiplayerServer:
    def __init__(self, max_players: int = MAX_PLAYERS) -> None:
        self.max_players = max_players
        self.players: Dict[str, Player] = {}
        self.writers: Dict[str, asyncio.StreamWriter] = {}
        self.pallets = {pallet.id: pallet for pallet in default_pallets()}

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        player_id: Optional[str] = None
        try:
            join = decode_message(await reader.readline())
            if join["type"] != "join":
                raise ProtocolError("first message must be join")
            if len(self.players) >= self.max_players:
                writer.write(encode_message("error", message="server full"))
                await writer.drain()
                return
            name = str(join.get("name") or "Buyer")[:32]
            player_id = secrets.token_hex(4)
            self.players[player_id] = Player(id=player_id, name=name)
            self.writers[player_id] = writer
            writer.write(encode_message("welcome", player_id=player_id, snapshot=self.snapshot()))
            await writer.drain()
            await self.broadcast("player_joined", player=self.players[player_id].snapshot(), skip=player_id)

            while not reader.at_eof():
                raw = await reader.readline()
                if not raw:
                    break
                await self.apply_message(player_id, decode_message(raw))
        except (ConnectionError, ProtocolError) as exc:
            if player_id and player_id in self.writers:
                writer.write(encode_message("error", message=str(exc)))
                with contextlib.suppress(ConnectionError):
                    await writer.drain()
        finally:
            if player_id:
                await self.remove_player(player_id)
            writer.close()
            with contextlib.suppress(ConnectionError):
                await writer.wait_closed()

    def snapshot(self):
        return lobby_snapshot(self.players.values(), self.pallets.values())

    async def apply_message(self, player_id: str, message) -> None:
        player = self.players[player_id]
        kind = message["type"]
        if kind == "move":
            player.x = float(message.get("x", player.x))
            player.y = float(message.get("y", player.y))
            player.rotation = float(message.get("rotation", player.rotation))
            await self.broadcast("player_moved", player=player.snapshot(), skip=player_id)
        elif kind == "ready":
            player.ready = bool(message.get("ready", True))
            await self.broadcast("player_ready", player=player.snapshot())
        elif kind == "claim_pallet":
            pallet = self.pallets.get(str(message.get("pallet_id")))
            if pallet is None:
                raise ProtocolError("unknown pallet")
            if pallet.claimed_by not in (None, player_id):
                raise ProtocolError("pallet already claimed")
            pallet.claimed_by = player_id
            await self.broadcast("pallet_claimed", pallet=pallet.snapshot())
        elif kind == "chat":
            text = str(message.get("text", ""))[:240]
            await self.broadcast("chat", player_id=player_id, name=player.name, text=text)
        elif kind == "snapshot":
            self.writers[player_id].write(encode_message("snapshot", snapshot=self.snapshot()))
            await self.writers[player_id].drain()
        else:
            raise ProtocolError(f"unsupported message type: {kind}")

    async def broadcast(self, kind: str, skip: Optional[str] = None, **payload) -> None:
        stale = []
        for player_id, writer in self.writers.items():
            if player_id == skip:
                continue
            try:
                writer.write(encode_message(kind, **payload))
                await writer.drain()
            except ConnectionError:
                stale.append(player_id)
        for player_id in stale:
            await self.remove_player(player_id)

    async def remove_player(self, player_id: str) -> None:
        if player_id in self.players:
            del self.players[player_id]
            del self.writers[player_id]
            for pallet in self.pallets.values():
                if pallet.claimed_by == player_id:
                    pallet.claimed_by = None
            await self.broadcast("player_left", player_id=player_id)


async def main_async(host: str, port: int, max_players: int) -> None:
    mod = MultiplayerServer(max_players=max_players)
    server = await asyncio.start_server(mod.handle_client, host, port)
    print(f"Returns Outlet Multiplayer listening on {host}:{port} ({max_players} players)")
    async with server:
        await server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Returns Outlet Simulator multiplayer mod server.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--max-players", type=int, default=MAX_PLAYERS)
    args = parser.parse_args()
    asyncio.run(main_async(args.host, args.port, args.max_players))


if __name__ == "__main__":
    main()

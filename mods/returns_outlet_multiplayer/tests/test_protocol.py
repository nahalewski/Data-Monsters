import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from protocol import ProtocolError, decode_message, default_pallets, encode_message, lobby_snapshot, Player


class ProtocolTests(unittest.TestCase):
    def test_encode_decode_round_trip(self):
        message = decode_message(encode_message("join", name="Buyer One"))
        self.assertEqual(message, {"type": "join", "name": "Buyer One"})

    def test_decode_rejects_missing_type(self):
        with self.assertRaises(ProtocolError):
            decode_message('{"name":"Buyer One"}')

    def test_default_pallets_are_claimable_inventory(self):
        pallets = default_pallets()
        self.assertGreaterEqual(len(pallets), 6)
        self.assertTrue(all(pallet.claimed_by is None for pallet in pallets))

    def test_lobby_snapshot_contains_players_and_pallets(self):
        snapshot = lobby_snapshot([Player(id="p1", name="Buyer")], default_pallets()[:1])
        self.assertEqual(snapshot["players"][0]["id"], "p1")
        self.assertEqual(snapshot["pallets"][0]["id"], "PALLET-001")
        self.assertIn("server_time", snapshot)


if __name__ == "__main__":
    unittest.main()

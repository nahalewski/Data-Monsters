from app.services.time_gate import MorningGate


def test_can_trigger_without_last_trigger(monkeypatch):
    gate = MorningGate("UTC", "00:00", "23:59", 60)
    assert gate.can_trigger(None) is True

#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.settings import settings

if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host=settings.ui_host, port=settings.ui_port, reload=False)

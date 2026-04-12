# Backend Integration (Upstream Core)

In the upstream `Core` repo, install the additive ESP32 routes without removing existing endpoints.

## Patch example for `core_bridge.py`
```python
from core_backend_compat.esp32_api_extension import install_esp32_routes

class CoreBridge:
    def __init__(self, app_instance):
        self.app = app_instance
        self.api = FastAPI()
        ...
        self._setup_routes()
        install_esp32_routes(self.api, self)
```

This is backward-compatible because it only adds `/esp32/*` routes.

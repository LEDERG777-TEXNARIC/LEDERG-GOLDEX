from pathlib import Path
import sys

# Allow direct execution as C:\LEDERG-MESSENGER\scripts\db_maintenance.py.
APP_ROOT = Path(__file__).resolve().parents[1]
if str(APP_ROOT) not in sys.path:
    sys.path.insert(0, str(APP_ROOT))

from server.db_guard import main

if __name__ == "__main__":
    raise SystemExit(main())

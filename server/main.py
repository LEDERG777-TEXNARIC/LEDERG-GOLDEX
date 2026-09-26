from contextlib import asynccontextmanager
import asyncio
import os
import time
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pathlib import Path
from sqlalchemy import text

from server.config import settings
from server.db.session import init_db, SessionLocal
from server.db_guard import guard_database
from server.routes.auth import router as auth_router
from server.routes.users import router as users_router
from server.routes.chats import router as chats_router
from server.routes.ws import router as ws_router
from server.routes.calls import router as calls_router

async def _database_watchdog():
    cycle = 0
    while True:
        await asyncio.sleep(30)
        cycle += 1
        try:
            # Fast health check every 30s. A full verification + verified
            # backup runs every 5 minutes from this single watchdog only.
            do_deep_cycle = cycle % 10 == 0
            ok, messages = await asyncio.to_thread(
                guard_database,
                do_deep_cycle,
                do_deep_cycle,
                do_deep_cycle,
            )
            if ok:
                if messages:
                    print("[DB-WATCH] " + " | ".join(messages))
                continue
            print("[DB-WATCH] CRITICAL: " + " | ".join(messages))
            print("[DB-WATCH] Restarting so the autopilot can repair the database.")
            if os.getenv("LEDERG_AUTOPILOT") == "1":
                os._exit(78)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            print("[DB-WATCH] error:", exc)


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings.ensure_dirs()
    for folder in ("avatars", "wallpapers"):
        (Path(settings.data_dir) / "uploads" / folder).mkdir(parents=True, exist_ok=True)

    ok, messages = guard_database(True, deep=True)
    if not ok:
        raise RuntimeError("[DB-WATCH] database is not healthy: " + " | ".join(messages))
    if messages:
        print("[DB-WATCH] " + " | ".join(messages))

    watcher = asyncio.create_task(_database_watchdog())
    try:
        yield
    finally:
        watcher.cancel()
        try:
            await watcher
        except asyncio.CancelledError:
            pass

app = FastAPI(title="LEDERG Messenger", version="0.4.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)


@app.middleware("http")
async def request_trace(request, call_next):
    if not request.url.path.startswith("/api"):
        return await call_next(request)
    started = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception as exc:
        elapsed = (time.perf_counter() - started) * 1000
        print(f"[HTTP] {request.method} {request.url.path} EXCEPTION {type(exc).__name__} {elapsed:.1f}ms")
        raise
    elapsed = (time.perf_counter() - started) * 1000
    print(f"[HTTP] {request.method} {request.url.path} -> {response.status_code} {elapsed:.1f}ms")
    return response


@app.middleware("http")
async def no_cache_web_client(request, call_next):
    response = await call_next(request)
    if request.url.path == "/" or request.url.path.endswith(".html"):
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
    return response

app.include_router(auth_router, prefix="/api/auth")
app.include_router(users_router, prefix="/api/users")
app.include_router(chats_router, prefix="/api")
app.include_router(ws_router)
app.include_router(calls_router, prefix="/api/calls")

media_dir = Path(settings.data_dir) / "uploads"
media_dir.mkdir(parents=True, exist_ok=True)
app.mount("/media", StaticFiles(directory=media_dir), name="media")

web_dir = Path(__file__).resolve().parent.parent / "web"
app.mount("/", StaticFiles(directory=web_dir, html=True), name="web")

@app.get("/api/ping")
def api_ping():
    return {"ok": True, "service": "lederg-messenger"}


@app.get("/api/health/db")
def api_db_health():
    return health()


@app.get("/health")
def health():
    try:
        with SessionLocal() as db:
            db.execute(text("SELECT 1"))
            integrity = db.execute(text("PRAGMA integrity_check")).scalar()
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity_check={integrity}")
        return {
            "ok": True,
            "service": "lederg-messenger",
            "version": "0.4.0",
            "database": "ok",
        }
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail={
                "ok": False,
                "service": "lederg-messenger",
                "database": "error",
                "reason": str(exc)[:200],
            },
        )

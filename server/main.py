from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pathlib import Path
from sqlalchemy import text

from server.config import settings
from server.db.session import init_db, SessionLocal
from server.routes.auth import router as auth_router
from server.routes.users import router as users_router
from server.routes.chats import router as chats_router
from server.routes.ws import router as ws_router

@asynccontextmanager
async def lifespan(app: FastAPI):
    settings.ensure_dirs()
    init_db()
    yield

app = FastAPI(
    title="LEDERG Messenger",
    version="0.5.0",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Permissions-Policy"] = "camera=(self), microphone=(self), geolocation=()"
    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    return response

app.include_router(auth_router, prefix="/api/auth")
app.include_router(users_router, prefix="/api/users")
app.include_router(chats_router, prefix="/api")
app.include_router(ws_router)

web_dir = Path(__file__).resolve().parent.parent / "web"
app.mount("/", StaticFiles(directory=web_dir), name="web")

@app.get("/health")
def health():
    try:
        with SessionLocal() as db:
            db.execute(text("SELECT 1"))
            integrity = db.execute(text("PRAGMA integrity_check")).scalar()
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity: {integrity}")
        return {
            "ok": True,
            "service": "lederg-messenger",
            "version": "0.5.0",
            "database": "ok",
            "privacy": "no phone-number identity; bearer auth; optional E2EE direct chats",
        }
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail={"ok": False, "service": "lederg-messenger", "database": "error", "reason": str(exc)[:200]},
        )

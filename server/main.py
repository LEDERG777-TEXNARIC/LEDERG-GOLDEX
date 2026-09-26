from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pathlib import Path

from server.config import settings
from server.db.session import init_db
from server.routes.auth import router as auth_router
from server.routes.users import router as users_router
from server.routes.chats import router as chats_router
from server.routes.ws import router as ws_router

@asynccontextmanager
async def lifespan(app: FastAPI):
    settings.ensure_dirs()
    init_db()
    yield

app = FastAPI(title="LEDERG Messenger", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router, prefix="/api/auth")
app.include_router(users_router, prefix="/api/users")
app.include_router(chats_router, prefix="/api")
app.include_router(ws_router)

web_dir = Path(__file__).resolve().parent.parent / "web"
app.mount("/", StaticFiles(directory=web_dir, html=True), name="web")

@app.get("/health")
def health():
    return {"ok": True, "service": "lederg-messenger", "version": "0.1.0"}

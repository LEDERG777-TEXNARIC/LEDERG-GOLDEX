from server.main import app
import os
import uvicorn

if __name__ == "__main__":
    uvicorn.run(
        app,
        host=os.getenv("LEDERG_HOST", "0.0.0.0"),
        port=int(os.getenv("LEDERG_PORT", "8000")),
        log_level="info",
        access_log=False,
    )

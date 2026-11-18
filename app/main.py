"""HTTP API for Just-In-Time defect prediction on Apache commits."""

import logging
import os
import secrets
import threading
import time
from collections import deque
from contextlib import asynccontextmanager
from pathlib import Path

import pandas as pd
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from jit.artifacts import load_artifacts
from jit.features import RAW_FEATURES

logger = logging.getLogger("jit.api")


class CommitMetrics(BaseModel):
    """The 12 structural change metrics describing one commit."""

    model_config = ConfigDict(extra="forbid")

    la: int = Field(ge=0, description="Lines added")
    ld: int = Field(ge=0, description="Lines deleted")
    nf: int = Field(ge=1, description="Files touched")
    nd: int = Field(ge=1, description="Directories touched")
    ns: int = Field(ge=1, description="Subsystems touched")
    ent: float = Field(ge=0, allow_inf_nan=False, description="Change entropy")
    ndev: float = Field(ge=0, allow_inf_nan=False, description="Distinct prior developers")
    age: float = Field(ge=0, allow_inf_nan=False, description="Avg. time since last change")
    nuc: float = Field(ge=0, allow_inf_nan=False, description="Unique prior changes")
    aexp: float = Field(ge=0, allow_inf_nan=False, description="Author experience")
    arexp: float = Field(ge=0, allow_inf_nan=False, description="Author recent experience")
    asexp: float = Field(ge=0, allow_inf_nan=False, description="Author subsystem experience")


class Prediction(BaseModel):
    risk_score: float = Field(description="Estimated probability the commit is bug-inducing")
    is_risky: bool = Field(description="risk_score at or above the tuned threshold")
    threshold: float
    model_version: str


@asynccontextmanager
async def lifespan(app: FastAPI):
    model_dir = Path(os.environ.get("MODEL_DIR", "artifacts"))
    app.state.model, app.state.metadata = load_artifacts(model_dir)
    logger.info("Loaded model %s", app.state.metadata["model_version"])
    yield


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    """Enforce the X-API-Key header when the API_KEY variable is set."""
    expected = os.environ.get("API_KEY")
    if expected and not secrets.compare_digest((x_api_key or "").encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


class RateLimiter:
    """Sliding-window limit of `limit` requests per `window` seconds per client."""

    MAX_TRACKED_CLIENTS = 10_000

    def __init__(self, limit: int, window: float = 60.0) -> None:
        self.limit = limit
        self.window = window
        self._hits: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def allow(self, client: str) -> bool:
        now = time.monotonic()
        with self._lock:
            if len(self._hits) > self.MAX_TRACKED_CLIENTS:
                self._forget_idle(now)
            hits = self._hits.setdefault(client, deque())
            while hits and now - hits[0] >= self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return False
            hits.append(now)
            return True

    def _forget_idle(self, now: float) -> None:
        for client in [c for c, h in self._hits.items() if not h or now - h[-1] >= self.window]:
            del self._hits[client]


def client_ip(request: Request) -> str:
    """The caller's address. Behind the Caddy proxy it is the last X-Forwarded-For entry,
    which Caddy sets itself; the API port is not exposed directly in the deployment."""
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[-1].strip()
    return request.client.host if request.client else "unknown"


def rate_limit(request: Request) -> None:
    limiter: RateLimiter | None = request.app.state.rate_limiter
    if limiter is not None and not limiter.allow(client_ip(request)):
        raise HTTPException(
            status_code=429,
            detail="Too many requests, try again in a minute",
            headers={"Retry-After": str(int(limiter.window))},
        )


def create_app() -> FastAPI:
    app = FastAPI(
        title="JIT Defect Prediction API",
        description=(
            "Scores how likely a commit is to introduce a bug. Intended as a "
            "review hint, not a merge gate: expect many false alarms."
        ),
        lifespan=lifespan,
    )
    per_minute = int(os.environ.get("RATE_LIMIT_PER_MIN", "60"))
    app.state.rate_limiter = RateLimiter(per_minute) if per_minute > 0 else None

    @app.exception_handler(Exception)
    async def unhandled_exception(request: Request, exc: Exception) -> JSONResponse:
        logger.exception("Unhandled error on %s", request.url.path)
        return JSONResponse(status_code=500, content={"detail": "Internal server error"})

    @app.get("/health")
    def health(request: Request) -> dict:
        return {
            "status": "ok",
            "model_version": request.app.state.metadata["model_version"],
        }

    @app.post("/predict", response_model=Prediction, dependencies=[Depends(require_api_key), Depends(rate_limit)])
    def predict(commit: CommitMetrics, request: Request) -> Prediction:
        frame = pd.DataFrame([commit.model_dump()], columns=RAW_FEATURES)
        score = float(request.app.state.model.score(frame)[0])
        metadata = request.app.state.metadata
        return Prediction(
            risk_score=round(score, 4),
            is_risky=score >= metadata["threshold"],
            threshold=metadata["threshold"],
            model_version=metadata["model_version"],
        )

    return app


app = create_app()

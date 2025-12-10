"""
NixFleet - Fleet management dashboard for NixOS and macOS hosts.

A lightweight solution that supports both NixOS and macOS,
runs in Docker, and provides a web UI for managing host updates.
"""

import os
import sqlite3
import secrets
import hmac
import logging
import re
from datetime import datetime, timedelta
from pathlib import Path
from contextlib import contextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, Request, Depends, Form
from fastapi.responses import HTMLResponse, RedirectResponse, PlainTextResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field, field_validator
from jinja2 import Environment, FileSystemLoader, select_autoescape
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded

# Optional bcrypt support (falls back to SHA-256 if not available)
try:
    import bcrypt
    BCRYPT_AVAILABLE = True
except ImportError:
    BCRYPT_AVAILABLE = False

# Optional TOTP support
try:
    import pyotp
    TOTP_AVAILABLE = True
except ImportError:
    TOTP_AVAILABLE = False

# ============================================================================
# Configuration
# ============================================================================

DATA_DIR = Path(os.environ.get("NIXFLEET_DATA_DIR", "/data"))
DB_PATH = DATA_DIR / "nixfleet.db"
TEMPLATES_DIR = Path(__file__).parent / "templates"

# Authentication (all required in production)
PASSWORD_HASH = os.environ.get("NIXFLEET_PASSWORD_HASH", "")
TOTP_SECRET = os.environ.get("NIXFLEET_TOTP_SECRET", "")
API_TOKEN = os.environ.get("NIXFLEET_API_TOKEN", "")

# Security modes
DEV_MODE = os.environ.get("NIXFLEET_DEV_MODE", "").lower() in ("1", "true", "yes")
REQUIRE_TOTP = os.environ.get("NIXFLEET_REQUIRE_TOTP", "").lower() in ("1", "true", "yes")

SESSION_DURATION = timedelta(hours=24)
VERSION = "0.1.0"

# Rate limiting
limiter = Limiter(key_func=get_remote_address)

# Host ID validation pattern (alphanumeric + hyphen, like hostnames)
HOST_ID_PATTERN = re.compile(r"^[a-zA-Z][a-zA-Z0-9\-]{0,62}$")

# ============================================================================
# Logging Setup
# ============================================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("nixfleet")

# ============================================================================
# Jinja2 Templates
# ============================================================================

jinja_env = Environment(
    loader=FileSystemLoader(str(TEMPLATES_DIR)),
    autoescape=select_autoescape(["html", "xml"]),
)


def render_template(name: str, **context) -> str:
    """Render a Jinja2 template with context."""
    template = jinja_env.get_template(name)
    return template.render(**context)


# ============================================================================
# Database
# ============================================================================


def init_db():
    """Initialize the SQLite database with all tables."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    logger.info(f"Initializing database at {DB_PATH}")
    
    with get_db() as conn:
        # Hosts table
        conn.execute("""
            CREATE TABLE IF NOT EXISTS hosts (
                id TEXT PRIMARY KEY,
                hostname TEXT NOT NULL,
                host_type TEXT NOT NULL CHECK(host_type IN ('nixos', 'macos')),
                location TEXT,
                criticality TEXT DEFAULT 'low' CHECK(criticality IN ('low', 'medium', 'high')),
                icon TEXT,
                last_seen TEXT,
                last_switch TEXT,
                last_audit TEXT,
                last_fix TEXT,
                current_generation TEXT,
                status TEXT DEFAULT 'unknown',
                pending_command TEXT,
                comment TEXT,
                test_status TEXT,
                config_repo TEXT,
                -- Test tracking
                test_running INTEGER DEFAULT 0,
                test_current INTEGER DEFAULT 0,
                test_total INTEGER DEFAULT 0,
                test_passed_count INTEGER DEFAULT 0,
                test_result TEXT,
                poll_interval INTEGER DEFAULT 60
            )
        """)
        
        # Command log table
        conn.execute("""
            CREATE TABLE IF NOT EXISTS command_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                host_id TEXT NOT NULL,
                command TEXT NOT NULL,
                status TEXT NOT NULL,
                output TEXT,
                created_at TEXT NOT NULL,
                completed_at TEXT,
                FOREIGN KEY (host_id) REFERENCES hosts(id)
            )
        """)
        
        # Sessions table (persistent across restarts)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                token TEXT PRIMARY KEY,
                csrf_token TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
        """)
        
        # Create indexes for performance
        conn.execute("CREATE INDEX IF NOT EXISTS idx_hosts_hostname ON hosts(hostname)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_command_log_host ON command_log(host_id)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at)")
        
        conn.commit()
    
    logger.info("Database initialized successfully")


@contextmanager
def get_db():
    """Get a database connection with row factory."""
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def cleanup_expired_sessions():
    """Remove expired sessions from database."""
    with get_db() as conn:
        result = conn.execute(
            "DELETE FROM sessions WHERE expires_at < ?",
            (datetime.utcnow().isoformat(),)
        )
        if result.rowcount > 0:
            logger.info(f"Cleaned up {result.rowcount} expired sessions")
        conn.commit()


# ============================================================================
# Session Management (Persistent in SQLite)
# ============================================================================


def create_session() -> tuple[str, str]:
    """Create a new session token and CSRF token, store in database.
    
    Returns:
        Tuple of (session_token, csrf_token)
    """
    token = secrets.token_urlsafe(32)
    csrf_token = secrets.token_urlsafe(32)
    expires_at = datetime.utcnow() + SESSION_DURATION
    
    with get_db() as conn:
        conn.execute(
            "INSERT INTO sessions (token, csrf_token, expires_at, created_at) VALUES (?, ?, ?, ?)",
            (token, csrf_token, expires_at.isoformat(), datetime.utcnow().isoformat())
        )
        conn.commit()
    
    logger.info("New session created")
    return token, csrf_token


def get_csrf_token(session_token: str) -> Optional[str]:
    """Get the CSRF token for a session."""
    with get_db() as conn:
        row = conn.execute(
            "SELECT csrf_token FROM sessions WHERE token = ?",
            (session_token,)
        ).fetchone()
        return row["csrf_token"] if row else None


def verify_csrf_token(session_token: str, csrf_token: str) -> bool:
    """Verify CSRF token matches the session."""
    if not session_token or not csrf_token:
        return False
    stored_csrf = get_csrf_token(session_token)
    if not stored_csrf:
        return False
    return hmac.compare_digest(csrf_token, stored_csrf)


def verify_session(token: str) -> bool:
    """Verify a session token is valid and not expired."""
    with get_db() as conn:
        row = conn.execute(
            "SELECT expires_at FROM sessions WHERE token = ?",
            (token,)
        ).fetchone()
        
        if not row:
            return False
        
        expires_at = datetime.fromisoformat(row["expires_at"])
        if datetime.utcnow() > expires_at:
            # Clean up expired session
            conn.execute("DELETE FROM sessions WHERE token = ?", (token,))
            conn.commit()
            return False
        
        return True


def delete_session(token: str):
    """Delete a session from database."""
    with get_db() as conn:
        conn.execute("DELETE FROM sessions WHERE token = ?", (token,))
        conn.commit()


# ============================================================================
# Authentication Helpers
# ============================================================================


def hash_password(password: str) -> str:
    """Hash a password using bcrypt."""
    if not BCRYPT_AVAILABLE:
        raise RuntimeError("bcrypt not available - install bcrypt package")
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def verify_password(password: str) -> bool:
    """Verify password against stored bcrypt hash."""
    if not PASSWORD_HASH:
        logger.warning("No password hash configured!")
        return False
    
    if not BCRYPT_AVAILABLE:
        logger.error("bcrypt not available - cannot verify password!")
        return False
    
    # Validate hash format
    if not (PASSWORD_HASH.startswith("$2b$") or PASSWORD_HASH.startswith("$2a$")):
        logger.error("Invalid password hash format - must be bcrypt ($2b$ or $2a$)")
        return False
    
    try:
        return bcrypt.checkpw(password.encode(), PASSWORD_HASH.encode())
    except Exception as e:
        logger.error(f"bcrypt verification failed: {e}")
        return False


def verify_totp(code: str) -> bool:
    """Verify TOTP code if configured."""
    if not TOTP_SECRET or not TOTP_AVAILABLE:
        return True  # TOTP not configured, skip
    totp = pyotp.TOTP(TOTP_SECRET)
    return totp.verify(code, valid_window=1)


def get_session_token(request: Request) -> Optional[str]:
    """Extract session token from cookie."""
    return request.cookies.get("nixfleet_session")


def require_auth(request: Request) -> bool:
    """Check if request is authenticated."""
    token = get_session_token(request)
    if token and verify_session(token):
        return True
    raise HTTPException(status_code=401, detail="Not authenticated")


def verify_api_token(token: str) -> bool:
    """Verify API token for agent requests. Fails closed if token not configured."""
    if not API_TOKEN:
        # SECURITY: Fail closed - no token means no access
        logger.error("Agent auth attempted but NIXFLEET_API_TOKEN not configured")
        return False
    if not token:
        return False
    return hmac.compare_digest(token, API_TOKEN)


# ============================================================================
# Pydantic Models with Validation
# ============================================================================

# Regex patterns for validation
HOSTNAME_PATTERN = re.compile(r"^[a-zA-Z][a-zA-Z0-9\-]{0,62}$")
GENERATION_PATTERN = re.compile(r"^[a-zA-Z0-9\-]{1,64}$")


class HostRegistration(BaseModel):
    """Model for host registration requests."""
    hostname: str = Field(..., min_length=1, max_length=63)
    host_type: str = Field(..., pattern="^(nixos|macos)$")
    location: Optional[str] = Field(None, max_length=50)
    criticality: Optional[str] = Field("low", pattern="^(low|medium|high)$")
    icon: Optional[str] = Field(None, max_length=10)
    current_generation: Optional[str] = Field(None, max_length=64)
    comment: Optional[str] = Field(None, max_length=500)
    test_status: Optional[str] = Field(None, max_length=100)
    config_repo: Optional[str] = Field(None, max_length=200)

    @field_validator("hostname")
    @classmethod
    def validate_hostname(cls, v: str) -> str:
        if not HOSTNAME_PATTERN.match(v):
            raise ValueError("Invalid hostname format")
        return v.lower()

    @field_validator("current_generation")
    @classmethod
    def validate_generation(cls, v: Optional[str]) -> Optional[str]:
        if v and not GENERATION_PATTERN.match(v):
            raise ValueError("Invalid generation format")
        return v


class HostStatus(BaseModel):
    """Model for host status updates."""
    status: str = Field(..., pattern="^(ok|error|unknown)$")
    current_generation: Optional[str] = Field(None, max_length=64)
    output: Optional[str] = Field(None, max_length=10000)
    test_status: Optional[str] = Field(None, max_length=100)

    @field_validator("output")
    @classmethod
    def sanitize_output(cls, v: Optional[str]) -> Optional[str]:
        if v:
            # Remove any control characters except newlines
            return "".join(c for c in v if c == "\n" or (ord(c) >= 32 and ord(c) < 127))
        return v


class HostUpdate(BaseModel):
    """Model for host metadata updates."""
    comment: Optional[str] = Field(None, max_length=500)
    criticality: Optional[str] = Field(None, pattern="^(low|medium|high)$")
    last_audit: Optional[str] = Field(None, max_length=30)
    last_fix: Optional[str] = Field(None, max_length=30)
    test_status: Optional[str] = Field(None, max_length=100)


class CommandRequest(BaseModel):
    """Model for command queue requests."""
    command: str = Field(..., pattern="^(pull|switch|pull-switch|test|stop)$")


# ============================================================================
# FastAPI App
# ============================================================================

app = FastAPI(
    title="NixFleet",
    description="Fleet management for NixOS and macOS hosts",
    version=VERSION,
)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
security = HTTPBearer(auto_error=False)


@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    """Add security headers to all responses."""
    response = await call_next(request)
    
    # Security headers (only in production)
    if not DEV_MODE:
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["X-XSS-Protection"] = "1; mode=block"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
    
    return response


def validate_host_id(host_id: str) -> str:
    """Validate and sanitize host_id parameter."""
    if not HOST_ID_PATTERN.match(host_id):
        raise HTTPException(status_code=400, detail="Invalid host ID format")
    return host_id.lower()


@app.on_event("startup")
async def startup():
    """Initialize database, validate config, and cleanup expired sessions."""
    # SECURITY: Validate required configuration
    errors = []
    
    if not BCRYPT_AVAILABLE:
        errors.append("bcrypt package not installed - required for password hashing")
    
    if not PASSWORD_HASH:
        errors.append("NIXFLEET_PASSWORD_HASH not set")
    elif not (PASSWORD_HASH.startswith("$2b$") or PASSWORD_HASH.startswith("$2a$")):
        errors.append("NIXFLEET_PASSWORD_HASH must be a bcrypt hash (starts with $2b$ or $2a$)")
    
    if not API_TOKEN and not DEV_MODE:
        errors.append("NIXFLEET_API_TOKEN not set (required in production)")
    
    if REQUIRE_TOTP and not TOTP_SECRET:
        errors.append("NIXFLEET_REQUIRE_TOTP is set but NIXFLEET_TOTP_SECRET is missing")
    
    if REQUIRE_TOTP and not TOTP_AVAILABLE:
        errors.append("NIXFLEET_REQUIRE_TOTP is set but pyotp is not installed")
    
    if errors:
        for err in errors:
            logger.error(f"Configuration error: {err}")
        raise RuntimeError(f"NixFleet startup failed: {', '.join(errors)}")
    
    init_db()
    cleanup_expired_sessions()
    logger.info(f"NixFleet v{VERSION} started")
    
    # Warnings for non-fatal issues
    if DEV_MODE:
        logger.warning("DEV_MODE enabled - security features relaxed for development")
    if not API_TOKEN:
        logger.warning("NIXFLEET_API_TOKEN not set - agents cannot connect")
    if not TOTP_SECRET:
        logger.info("TOTP not configured - 2FA disabled")


# ============================================================================
# Health Endpoint
# ============================================================================


@app.get("/health")
async def health_check():
    """
    Health check endpoint for monitoring.
    
    SECURITY: Does not expose configuration details (TOTP, API token status).
    Only returns operational health and sanitized metrics.
    """
    try:
        with get_db() as conn:
            conn.execute("SELECT 1").fetchone()
        
        # Only return minimal operational info - no security config leakage
        return {
            "status": "healthy",
            "version": VERSION,
        }
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        raise HTTPException(status_code=503, detail="Service unhealthy")


# ============================================================================
# Authentication Endpoints
# ============================================================================


@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request, error: str = ""):
    """Show login page."""
    token = get_session_token(request)
    if token and verify_session(token):
        return RedirectResponse(url="/", status_code=302)

    return render_template(
        "login.html",
        error=error,
        totp_enabled=bool(TOTP_SECRET and TOTP_AVAILABLE),
    )


@app.post("/login")
@limiter.limit("5/minute")  # Max 5 login attempts per minute per IP
async def login(request: Request, password: str = Form(...), totp: str = Form("")):
    """Process login with rate limiting."""
    logger.info(f"Login attempt from {get_remote_address(request)}")
    
    if not verify_password(password):
        logger.warning("Login failed: invalid password")
        return RedirectResponse(url="/login?error=Invalid+password", status_code=302)

    if TOTP_SECRET and TOTP_AVAILABLE and (not totp or not verify_totp(totp)):
        logger.warning("Login failed: invalid TOTP")
        return RedirectResponse(url="/login?error=Invalid+TOTP+code", status_code=302)

    session_token, _ = create_session()  # CSRF token stored in DB, retrieved per-request
    response = RedirectResponse(url="/", status_code=302)
    response.set_cookie(
        key="nixfleet_session",
        value=session_token,
        httponly=True,
        secure=not DEV_MODE,  # Disable secure in dev mode for localhost
        samesite="strict" if not DEV_MODE else "lax",
        max_age=int(SESSION_DURATION.total_seconds()),
    )
    
    logger.info("Login successful")
    return response


@app.post("/logout")
async def logout(request: Request, csrf_token: str = Form("")):
    """Logout and clear session. POST-only with CSRF protection."""
    session_token = get_session_token(request)
    
    # Validate CSRF token
    if session_token and not verify_csrf_token(session_token, csrf_token):
        logger.warning("Logout CSRF validation failed")
        raise HTTPException(status_code=403, detail="Invalid CSRF token")
    
    if session_token:
        delete_session(session_token)
        logger.info("User logged out")

    response = RedirectResponse(url="/login", status_code=302)
    response.delete_cookie("nixfleet_session")
    return response


# ============================================================================
# API Endpoints
# ============================================================================


def verify_agent_auth(credentials: Optional[HTTPAuthorizationCredentials] = Depends(security)):
    """Verify agent API token. Always required - fails closed."""
    if not credentials or not verify_api_token(credentials.credentials):
        logger.warning("Agent auth failed - missing or invalid token")
        raise HTTPException(status_code=401, detail="Invalid API token")
    return True


@app.get("/api/hosts")
async def list_hosts(request: Request):
    """List all registered hosts."""
    require_auth(request)
    with get_db() as conn:
        rows = conn.execute("SELECT * FROM hosts ORDER BY hostname").fetchall()
        hosts = []
        for row in rows:
            host = dict(row)
            if host["last_seen"]:
                last_seen = datetime.fromisoformat(host["last_seen"])
                host["online"] = datetime.utcnow() - last_seen < timedelta(minutes=5)
            else:
                host["online"] = False
            hosts.append(host)
        return {"hosts": hosts}


@app.post("/api/hosts/{host_id}/register")
@limiter.limit("30/minute")  # Limit registration attempts
async def register_host(request: Request, host_id: str, registration: HostRegistration, _: bool = Depends(verify_agent_auth)):
    """Register or update a host."""
    host_id = validate_host_id(host_id)
    logger.info(f"Host registration: {host_id} ({registration.hostname})")
    
    with get_db() as conn:
        existing = conn.execute("SELECT * FROM hosts WHERE id = ?", (host_id,)).fetchone()
        
        if existing:
            # Update existing host - agent is alive, update last_seen
            conn.execute("""
                UPDATE hosts SET
                    hostname = ?, host_type = ?, location = COALESCE(?, location),
                    current_generation = ?, last_seen = ?, status = 'ok',
                    config_repo = COALESCE(?, config_repo)
                WHERE id = ?
            """, (
                registration.hostname, registration.host_type, registration.location,
                registration.current_generation, datetime.utcnow().isoformat(),
                registration.config_repo, host_id,
            ))
        else:
            # New host - do NOT set last_seen (offline until agent actually polls)
            conn.execute("""
                INSERT INTO hosts (id, hostname, host_type, location, criticality, icon,
                    current_generation, last_seen, status, comment, config_repo)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 'ok', ?, ?)
            """, (
                host_id, registration.hostname, registration.host_type, registration.location,
                registration.criticality or "low", registration.icon,
                registration.current_generation,
                registration.comment, registration.config_repo,
            ))
        conn.commit()
    
    return {"status": "registered", "host_id": host_id}


@app.patch("/api/hosts/{host_id}")
async def update_host(host_id: str, update: HostUpdate, request: Request):
    """Update host metadata."""
    host_id = validate_host_id(host_id)
    require_auth(request)
    logger.info(f"Updating host metadata: {host_id}")
    
    with get_db() as conn:
        updates = []
        params = []
        
        if update.comment is not None:
            updates.append("comment = ?")
            params.append(update.comment)
        if update.criticality is not None:
            updates.append("criticality = ?")
            params.append(update.criticality)
        if update.last_audit is not None:
            updates.append("last_audit = ?")
            params.append(update.last_audit)
        if update.last_fix is not None:
            updates.append("last_fix = ?")
            params.append(update.last_fix)
        if update.test_status is not None:
            updates.append("test_status = ?")
            params.append(update.test_status)
        
        if updates:
            params.append(host_id)
            conn.execute(f"UPDATE hosts SET {', '.join(updates)} WHERE id = ?", params)
            conn.commit()
    
    return {"status": "updated"}


@app.get("/api/hosts/{host_id}/poll")
@limiter.limit("60/minute")  # Allow frequent polling
async def poll_commands(request: Request, host_id: str, _: bool = Depends(verify_agent_auth)):
    """Agent polls for pending commands."""
    host_id = validate_host_id(host_id)
    with get_db() as conn:
        conn.execute(
            "UPDATE hosts SET last_seen = ? WHERE id = ?",
            (datetime.utcnow().isoformat(), host_id)
        )
        conn.commit()
        
        row = conn.execute(
            "SELECT pending_command FROM hosts WHERE id = ?",
            (host_id,)
        ).fetchone()
        
        if row and row["pending_command"]:
            command = row["pending_command"]
            logger.info(f"Sending command to {host_id}: {command}")
            
            conn.execute("UPDATE hosts SET pending_command = NULL WHERE id = ?", (host_id,))
            conn.execute("""
                INSERT INTO command_log (host_id, command, status, created_at)
                VALUES (?, ?, 'running', ?)
            """, (host_id, command, datetime.utcnow().isoformat()))
            conn.commit()
            
            return {"command": command}
    
    return {"command": None}


@app.post("/api/hosts/{host_id}/status")
@limiter.limit("30/minute")  # Limit status updates
async def update_status(request: Request, host_id: str, status: HostStatus, _: bool = Depends(verify_agent_auth)):
    """Agent reports command result."""
    host_id = validate_host_id(host_id)
    logger.info(f"Status update from {host_id}: {status.status}")
    
    with get_db() as conn:
        conn.execute("""
            UPDATE hosts SET
                status = ?, current_generation = COALESCE(?, current_generation),
                last_seen = ?, test_status = COALESCE(?, test_status),
                last_switch = CASE WHEN ? IN ('ok', 'success') THEN ? ELSE last_switch END
            WHERE id = ?
        """, (
            status.status, status.current_generation, datetime.utcnow().isoformat(),
            status.test_status, status.status, datetime.utcnow().isoformat(), host_id,
        ))
        
        conn.execute("""
            UPDATE command_log SET status = ?, output = ?, completed_at = ?
            WHERE host_id = ? AND completed_at IS NULL
            ORDER BY created_at DESC LIMIT 1
        """, (status.status, status.output, datetime.utcnow().isoformat(), host_id))
        conn.commit()
    
    return {"status": "updated"}


class TestProgress(BaseModel):
    """Model for test progress updates from agent."""
    current: int = Field(..., ge=0, description="Current test number")
    total: int = Field(..., ge=0, description="Total number of tests")
    passed: int = Field(0, ge=0, description="Number of passed tests so far")
    running: bool = Field(True, description="Whether tests are still running")
    result: Optional[str] = Field(None, description="Final result summary")
    comment: Optional[str] = Field(None, description="Error message or notes")


@app.post("/api/hosts/{host_id}/test-progress")
@limiter.limit("60/minute")
async def update_test_progress(request: Request, host_id: str, progress: TestProgress, _: bool = Depends(verify_agent_auth)):
    """Agent reports test progress."""
    host_id = validate_host_id(host_id)
    logger.info(f"Test progress from {host_id}: {progress.current}/{progress.total} (passed: {progress.passed})")
    
    with get_db() as conn:
        if progress.running:
            # Test in progress
            conn.execute("""
                UPDATE hosts SET
                    test_running = 1,
                    test_current = ?,
                    test_total = ?,
                    test_passed_count = ?,
                    last_seen = ?
                WHERE id = ?
            """, (progress.current, progress.total, progress.passed, datetime.utcnow().isoformat(), host_id))
        else:
            # Test completed
            conn.execute("""
                UPDATE hosts SET
                    test_running = 0,
                    test_current = ?,
                    test_total = ?,
                    test_passed_count = ?,
                    test_result = ?,
                    test_status = ?,
                    comment = COALESCE(?, comment),
                    last_seen = ?,
                    last_audit = ?,
                    pending_command = NULL
                WHERE id = ?
            """, (
                progress.current, progress.total, progress.passed,
                progress.result,
                f"{progress.passed}/{progress.total} passed",
                progress.comment,
                datetime.utcnow().isoformat(),
                datetime.utcnow().isoformat(),  # Tests complete = audit done
                host_id
            ))
        conn.commit()
    
    return {"status": "updated"}


@app.post("/api/hosts/{host_id}/command")
async def queue_command(host_id: str, request_body: CommandRequest, request: Request):
    """Queue a command for a host. Requires session auth + CSRF token."""
    host_id = validate_host_id(host_id)
    require_auth(request)
    
    # Validate CSRF token from header
    session_token = get_session_token(request)
    csrf_token = request.headers.get("X-CSRF-Token", "")
    if not verify_csrf_token(session_token, csrf_token):
        logger.warning(f"CSRF validation failed for command to {host_id}")
        raise HTTPException(status_code=403, detail="Invalid CSRF token")
    
    logger.info(f"Queueing command for {host_id}: {request_body.command}")
    
    with get_db() as conn:
        if request_body.command == "stop":
            # Stop command clears test state
            result = conn.execute(
                """UPDATE hosts SET 
                    pending_command = 'stop',
                    test_running = 0
                WHERE id = ?""",
                (host_id,)
            )
        elif request_body.command == "test":
            # Test command initializes test state
            result = conn.execute(
                """UPDATE hosts SET 
                    pending_command = 'test',
                    test_running = 1,
                    test_current = 0,
                    test_total = 0,
                    test_passed_count = 0,
                    test_result = NULL
                WHERE id = ?""",
                (host_id,)
            )
        else:
            result = conn.execute(
                "UPDATE hosts SET pending_command = ? WHERE id = ?",
                (request_body.command, host_id)
            )
        if result.rowcount == 0:
            raise HTTPException(status_code=404, detail="Host not found")
        conn.commit()
    
    return {"status": "queued", "command": request_body.command}


@app.get("/api/hosts/{host_id}/logs")
async def get_logs(host_id: str, request: Request, limit: int = 20):
    """Get command logs for a host."""
    host_id = validate_host_id(host_id)
    require_auth(request)
    
    with get_db() as conn:
        rows = conn.execute("""
            SELECT * FROM command_log
            WHERE host_id = ?
            ORDER BY created_at DESC
            LIMIT ?
        """, (host_id, min(limit, 100))).fetchall()
        return {"logs": [dict(row) for row in rows]}


# ============================================================================
# Web UI
# ============================================================================


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    """Render the dashboard."""
    token = get_session_token(request)
    if not token or not verify_session(token):
        return RedirectResponse(url="/login", status_code=302)

    with get_db() as conn:
        rows = conn.execute("""
            SELECT * FROM hosts ORDER BY
                CASE criticality WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
                hostname
        """).fetchall()
        
        hosts = []
        for row in rows:
            host = dict(row)
            
            # Calculate online status and add ISO timestamps for JS
            if host["last_seen"]:
                last_seen = datetime.fromisoformat(host["last_seen"])
                host["online"] = datetime.utcnow() - last_seen < timedelta(minutes=5)
                host["last_seen_relative"] = relative_time(last_seen)
                host["last_seen_iso"] = host["last_seen"]  # ISO format for JS
            else:
                host["online"] = False
                host["last_seen_relative"] = "never"
                host["last_seen_iso"] = None
            
            # Format other times with ISO for tooltips
            if host["last_switch"]:
                host["last_switch_relative"] = relative_time(
                    datetime.fromisoformat(host["last_switch"])
                )
            else:
                host["last_switch_relative"] = "never"
            
            if host["last_audit"]:
                host["last_audit_relative"] = relative_time(
                    datetime.fromisoformat(host["last_audit"])
                )
                host["last_audit_iso"] = host["last_audit"]
            else:
                host["last_audit_relative"] = None
                host["last_audit_iso"] = None
            
            # Test state - convert SQLite int to Python bool
            host["test_running"] = bool(host.get("test_running", 0))
            host["test_current"] = host.get("test_current", 0)
            host["test_total"] = host.get("test_total", 0)
            host["test_passed_count"] = host.get("test_passed_count", 0)
            host["test_total_count"] = host.get("test_total", 0)
            host["test_passed"] = (host["test_passed_count"] == host["test_total_count"]) if host["test_total_count"] > 0 else None
            host["poll_interval"] = host.get("poll_interval", 60)
            
            hosts.append(host)

    # Calculate stats
    stats = {
        "total": len(hosts),
        "online": sum(1 for h in hosts if h["online"]),
        "audited": sum(1 for h in hosts if h.get("last_audit")),
    }

    # Get CSRF token for this session
    csrf_token = get_csrf_token(token) or ""
    
    return render_template(
        "dashboard.html", 
        hosts=hosts, 
        stats=stats, 
        version=VERSION,
        csrf_token=csrf_token
    )


def relative_time(dt: datetime) -> str:
    """Format datetime as relative time string."""
    diff = datetime.utcnow() - dt
    seconds = diff.total_seconds()
    
    if seconds < 60:
        return "just now"
    elif seconds < 3600:
        return f"{int(seconds / 60)} min ago"
    elif seconds < 86400:
        return f"{int(seconds / 3600)}h ago"
    else:
        return f"{int(seconds / 86400)}d ago"

# NixFleet - Fleet management dashboard
FROM python:3.12-slim

WORKDIR /app

# Build argument for git hash (passed at build time)
ARG GIT_HASH=unknown

# Install dependencies
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY app/ .

# Create version.json with build-time info (like pidicon)
RUN echo "{\"version\": \"0.1.0\", \"gitCommit\": \"${GIT_HASH}\"}" > version.json

# Create data directory
RUN mkdir -p /data

# Run as non-root user
RUN useradd -m nixfleet && chown -R nixfleet:nixfleet /app /data
USER nixfleet

# Set git hash as environment variable (backup)
ENV NIXFLEET_GIT_HASH=${GIT_HASH}

# Expose port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

# Run the application
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

# Nitro Turtles Leaderboard Web UI

A web interface for displaying leaderboard data from the Nitro Turtles game API.

## Quick Start with Docker Compose

1. **Create a `.env` file** (optional, uses defaults if not present):
   ```bash
   cp .env.example .env
   # Edit .env with your configuration
   ```

2. **Build and run**:
   ```bash
   docker-compose up -d
   ```

3. **Access the web UI**:
   Open http://localhost:5003 in your browser

## Configuration

The application can be configured via environment variables:

- `BASE_API_URL`: The base URL for the leaderboard API (default: `http://127.0.0.1:8000/leaderboard`)
- `STEAM_API_KEY`: Your Steam API key for fetching player profiles
- `FLASK_ENV`: Flask environment (default: `production`)

## Docker Commands

- **Build**: `docker-compose build`
- **Start**: `docker-compose up -d`
- **Stop**: `docker-compose down`
- **View logs**: `docker-compose logs -f`
- **Rebuild**: `docker-compose up -d --build`

## Production Deployment

The Docker container uses Gunicorn as the WSGI server with:
- 4 worker processes
- 2 threads per worker
- 120 second timeout
- Runs on port 5003

## Local Development

For local development without Docker:

```bash
pip install -r requirements.txt
python webui.py
```

The app will run on http://localhost:5003

## Notes

- The API server should be accessible from the container. Use `host.docker.internal` on Mac/Windows or `172.17.0.1` on Linux to access the host machine.
- Rate limiting is set to 10 requests per 10-second window per IP address.

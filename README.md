# SecureOpenCode

Runs [OpenCode](https://opencode.ai) inside a Docker container pre-configured with the XQAI provider. Any local project directory is bind-mounted into the container at `/workspace`. A Flask management server provides a dark-themed web UI for monitoring and managing sessions.

---

## Overview

![OpenCode Console](resources/aileon.png)

```
soc [path]
  │
  ├─ Ensures Flask management server is running (auto-starts it)
  ├─ Builds the Docker image on first run
  ├─ Mounts [path] → /workspace inside a new container
  ├─ Opens http://localhost:5000 in the browser
  └─ Attaches to OpenCode interactively (docker exec -it)
```

Containers stay alive after OpenCode exits so you can reconnect or inspect them from the web UI. Each container is tracked via Docker labels (`opencode.managed=true`, `opencode.host_path=<path>`). Running `soc` on a directory that already has a running container reuses it instead of creating a new one.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **Docker Desktop** | https://docker.com — must be running |
| **Python 3.8+** | Windows: 3.10+ recommended, resolved via `py` launcher |
| **Admin rights** | Not required — user-level PATH only |

---

## Installation

### Windows (CMD)

```cmd
install.cmd
```

Open a new terminal window after installation completes.

### Unix / Git Bash / macOS

```bash
bash install.sh
```

Open a new shell (or `source ~/.bashrc`) after installation completes.

### What the installer does

1. Adds the project directory to the **user** PATH (Windows registry `HKCU`, no admin required) or creates `~/.local/bin/soc` symlink (Unix).
2. Creates a Python virtual environment at `.venv/`.
3. Installs `Flask==3.0.3` and `docker==7.1.0` into the venv.
4. Builds the `secure-opencode` Docker image (first time, ~1 minute).

---

## Usage

### `soc` — run OpenCode on a directory

```bash
soc                       # mounts the current directory
soc /path/to/project      # mounts the specified directory
soc C:\path\to\project    # Windows
```

**Workflow:**

1. `soc` auto-starts the Flask management server if it is not already running.
2. On first run, it builds the Docker image.
3. A container named `soc-<dirname>-<suffix>` is started with the directory bind-mounted at `/workspace`.
4. The browser opens at `http://localhost:5000`.
5. OpenCode launches interactively in the container working directory.
6. Typing `exit` in OpenCode detaches but leaves the container running.
7. Running `soc` again on the same directory reattaches to the existing container.

### Reconnect to an existing session

```bash
docker exec -it -w /workspace <container-name> opencode
```

The connect command is shown on every session card in the web UI with a copy button.

### Stop a session

Either click **Stop** in the web UI, or:

```bash
docker stop <container-name> && docker rm <container-name>
```

---

## Management Web UI

Start the server standalone (without launching OpenCode):

```cmd
start-server.cmd          # Windows
bash start-server.sh      # Unix / Git Bash
```

Then open **http://localhost:5000**.

### UI features

| Feature | Details |
|---|---|
| **Docker / Image status** | Navbar badges — live connection and image state |
| **Active Sessions** | Card per running container, auto-refreshes every 5 seconds |
| **Session card** | Container name, status, live uptime, started datetime, container ID, mount path, connect command with copy button |
| **New Session** | Create a session by entering an absolute directory path |
| **Stop** | Stops and removes the container |
| **Build Image** | Shown when the `secure-opencode` image is missing; triggers a build |

The session list uses DOM diffing — cards update in-place without flickering. Uptime ticks every 10 seconds independently of the 5-second data refresh.

![Management Web UI](resources/webui.png)

---

## Project Structure

```
SecureOpenCode/
├── docker/
│   ├── Dockerfile          # Ubuntu 24.04 + OpenCode + XQAI config
│   └── opencode.jsonc      # OpenCode provider configuration
├── templates/
│   └── index.html          # Flask template — dark SPA
├── app.py                  # Flask management server
├── requirements.txt        # Flask==3.0.3, docker==7.1.0
├── soc.cmd                 # Windows CLI entry point
├── soc.sh                  # Unix / Git Bash CLI entry point
├── start-server.cmd        # Start management server only (Windows)
├── start-server.sh         # Start management server only (Unix)
├── install.cmd             # Windows installer
└── install.sh              # Unix installer
```

---

## Docker Image

**Base image:** `ubuntu:24.04`

**Installed:**
- `curl`, `git`, `ca-certificates`, `nodejs`, `npm`
- OpenCode via `curl -fsSL https://opencode.ai/install | bash` (installs to `/root/.opencode/bin/`)

**Configuration:** `/root/.config/opencode/opencode.jsonc`

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "enabled_providers": ["xqai"],
  "disabled_providers": ["opencode"],
  "provider": {
    "xqai": {
      "name": "XQAI",
      "npm": "@ai-sdk/openai-compatible",
      "models": {
        "AiLeonFlash": { "name": "AiLeonFlash" },
        "AiLeon":      { "name": "AiLeon" }
      },
      "options": { "baseURL": "http://10.56.190.50:11434/v1" }
    }
  }
}
```

To rebuild the image after changing `opencode.jsonc` or `Dockerfile`:

```bash
docker build -t secure-opencode docker/
```

Or use the **Build Image** button in the web UI.

---

## Flask API

The management server runs on port `5000` by default (override with `PORT` env var).

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Web UI |
| `GET` | `/api/status` | Docker connectivity and image state |
| `POST` | `/api/image/build` | Build the `secure-opencode` image |
| `GET` | `/api/sessions` | List all managed containers |
| `POST` | `/api/sessions` | Create a new session — body: `{"path": "/abs/path"}` |
| `DELETE` | `/api/sessions/<id>` | Stop and remove a session |

Sessions are identified by the Docker label `opencode.managed=true`. The `opencode.host_path` label stores the host directory path for container reuse detection.

---

## Troubleshooting

**`soc` not found after install**
Open a new terminal window. On Unix, run `source ~/.bashrc` or equivalent. Verify with `which soc` (Unix) or `where soc` (Windows).

**Docker image build fails**
Requires internet access during build to download OpenCode. Check Docker Desktop is running. Retry via the web UI **Build Image** button.

**OpenCode does not see the project files**
The container must be started with the directory bind-mounted at `/workspace`. Always use `docker exec -it -w /workspace <name> opencode` (the `-w /workspace` flag is required).

**Port 5000 already in use**
```bash
PORT=5001 python app.py          # Unix
set PORT=5001 && python app.py   # Windows CMD
```

**Python venv creation fails on Windows**
The installer kills any running `python.exe` psocesses before creating the venv. If it still fails, manually delete `.venv\` and re-run `install.cmd`.

**Inkscape Python 3.9 selected instead of Python 3.13**
The installer uses the `py -3` launcher to resolve Python, which skips non-dev interpreters. If you see version 3.9, ensure the Windows `py` launcher is installed with your Python 3.13 distribution.

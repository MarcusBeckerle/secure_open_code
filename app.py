import os
import sys
import uuid
import json
import time
import shutil
import string
import subprocess
import docker
import docker.errors
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
IMAGE_NAME = "secure-opencode"
LABEL_MANAGED = "opencode.managed"
LABEL_HOST_PATH = "opencode.host_path"
MAPPINGS_FILE = os.path.join(SCRIPT_DIR, "docker", "mappings.json")
CONTAINER_MAPPINGS_FILE = os.path.join(SCRIPT_DIR, "docker", "container_mappings.json")


def get_client():
    return docker.from_env(timeout=300)


def _is_pipe_error(exc):
    s = str(exc)
    return '109' in s or 'GetOverlappedResult' in s


# ── Mappings storage ──────────────────────────────────────────────────────────

def load_global_mappings():
    try:
        with open(MAPPINGS_FILE) as f:
            return json.load(f).get("host_mappings", [])
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def save_global_mappings(mappings):
    with open(MAPPINGS_FILE, "w") as f:
        json.dump({"host_mappings": mappings}, f, indent=2)


def load_container_mappings():
    try:
        with open(CONTAINER_MAPPINGS_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_container_mappings(data):
    with open(CONTAINER_MAPPINGS_FILE, "w") as f:
        json.dump(data, f, indent=2)


def state_volume_name(container_name):
    return f"{container_name}-state"


def build_volumes(workspace_path, container_name=None):
    volumes = {workspace_path: {"bind": "/workspace", "mode": "rw"}}
    if container_name:
        # Named volume persists OpenCode session data across container recreations
        volumes[state_volume_name(container_name)] = {"bind": "/root/.local/share/opencode", "mode": "rw"}
    for m in load_global_mappings():
        if m.get("host_path") and m.get("container_path"):
            volumes[m["host_path"]] = {"bind": m["container_path"], "mode": "rw"}
    if container_name:
        cm = load_container_mappings()
        for m in cm.get(container_name, []):
            if m.get("host_path") and m.get("container_path"):
                volumes[m["host_path"]] = {"bind": m["container_path"], "mode": "rw"}
    return volumes


def recreate_container(container):
    name = container.name
    path = container.labels.get(LABEL_HOST_PATH, "")
    if not path:
        raise ValueError(f"Container {name} has no host path label")

    volumes = build_volumes(path, name)

    # Remove orphaned temp containers left by any previous failed recreation.
    # Pattern: {name}-r{4 hex chars}
    try:
        prefix = f"{name}-r"
        for tc in get_client().containers.list(all=True, filters={"label": f"{LABEL_MANAGED}=true"}):
            if tc.name.startswith(prefix) and len(tc.name) == len(name) + 6:
                try:
                    tc.remove(force=True)
                except Exception:
                    pass
    except Exception:
        pass

    new_container = None
    temp_name = None

    for attempt in range(3):
        attempt_name = f"{name}-r{uuid.uuid4().hex[:4]}"
        try:
            new_container = get_client().containers.run(
                IMAGE_NAME,
                name=attempt_name,
                volumes=volumes,
                labels={LABEL_MANAGED: "true", LABEL_HOST_PATH: path},
                command=["sleep", "infinity"],
                detach=True,
                tty=True,
                stdin_open=True,
            )
            temp_name = attempt_name
            break
        except Exception as e:
            if not (_is_pipe_error(e) and attempt < 2):
                raise
            # Pipe dropped — retry the state check until the pipe recovers.
            time.sleep(1.5 * (attempt + 1))
            for _try in range(5):
                try:
                    c = get_client().containers.get(attempt_name)
                    if c.status == "running":
                        new_container = c
                        temp_name = attempt_name
                    else:
                        c.remove(force=True)
                    break
                except docker.errors.NotFound:
                    break
                except Exception:
                    if _try < 4:
                        time.sleep(1.0)
            if new_container is not None:
                break
            # Container absent or cleaned up — retry with a fresh name

    if new_container is None:
        raise RuntimeError("Failed to create replacement container after retries")
    new_container.reload()
    if new_container.status != "running":
        try:
            new_container.remove(force=True)
        except Exception:
            pass
        raise RuntimeError(f"New container failed to start (status: {new_container.status})")

    # New container confirmed running — stop and remove old with a fresh client reference
    try:
        old = get_client().containers.get(name)
        if old.status == "running":
            old.stop(timeout=5)
        old.remove()
        get_client().containers.get(temp_name).rename(name)
    except Exception:
        try:
            get_client().containers.get(temp_name).remove(force=True)
        except Exception:
            pass
        raise
    return new_container


def recreate_all_containers():
    c = get_client()
    containers = c.containers.list(all=True, filters={"label": f"{LABEL_MANAGED}=true"})
    results = []
    for container in containers:
        try:
            recreate_container(container)
            results.append({"name": container.name, "status": "recreated"})
        except Exception as e:
            results.append({"name": container.name, "status": "error", "error": str(e)})
    return results


def find_container(session_id):
    c = get_client()
    for container in c.containers.list(filters={"label": f"{LABEL_MANAGED}=true"}):
        if container.short_id == session_id or container.name == session_id:
            return container
    return None


# ── Core routes ───────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    try:
        c = get_client()
        try:
            img = c.images.get(IMAGE_NAME)
            image_info = {"built": True, "id": img.short_id, "tags": img.tags}
        except docker.errors.ImageNotFound:
            image_info = {"built": False}
        return jsonify({"docker": True, "image": image_info})
    except Exception as e:
        return jsonify({"docker": False, "error": str(e)})


@app.route("/api/image/build", methods=["POST"])
def api_build_image():
    dockerfile_path = os.path.join(SCRIPT_DIR, "docker")
    try:
        c = get_client()
        image, _ = c.images.build(path=dockerfile_path, tag=IMAGE_NAME, rm=True)
        return jsonify({"status": "built", "id": image.short_id})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ── Filesystem browser ────────────────────────────────────────────────────────

@app.route("/api/browse")
def api_browse():
    path = request.args.get("path", "").strip()
    try:
        if not path:
            if os.name == "nt":
                drives = [
                    {"name": f"{d}:\\", "path": f"{d}:\\", "is_dir": True}
                    for d in string.ascii_uppercase
                    if os.path.exists(f"{d}:\\")
                ]
                return jsonify({"path": "", "entries": drives, "parent": None})
            path = "/"

        path = os.path.abspath(path)
        if not os.path.isdir(path):
            return jsonify({"error": "Not a directory"}), 400

        entries = []
        try:
            for entry in sorted(os.scandir(path), key=lambda e: (not e.is_dir(), e.name.lower())):
                if entry.is_dir():
                    entries.append({"name": entry.name, "path": entry.path, "is_dir": True})
        except PermissionError:
            pass

        parent_path = os.path.dirname(path)
        if os.name == "nt" and parent_path == path:
            parent = ""
        elif parent_path == path:
            parent = None
        else:
            parent = parent_path

        return jsonify({"path": path, "entries": entries, "parent": parent})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ── Global mappings ───────────────────────────────────────────────────────────

@app.route("/api/mappings", methods=["GET"])
def api_get_mappings():
    return jsonify(load_global_mappings())


@app.route("/api/mappings", methods=["POST"])
def api_add_mapping():
    data = request.get_json() or {}
    host_path = data.get("host_path", "").strip()
    container_path = data.get("container_path", "").strip()
    if not host_path or not container_path:
        return jsonify({"error": "host_path and container_path required"}), 400
    if not os.path.isdir(host_path):
        return jsonify({"error": f"Directory not found: {host_path}"}), 400

    mappings = load_global_mappings()
    entry = {"id": uuid.uuid4().hex[:8], "host_path": host_path, "container_path": container_path}
    mappings.append(entry)
    save_global_mappings(mappings)
    recreated = recreate_all_containers()
    return jsonify({"mapping": entry, "recreated": recreated})


@app.route("/api/mappings/<mapping_id>", methods=["PUT"])
def api_update_mapping(mapping_id):
    data = request.get_json() or {}
    host_path = data.get("host_path", "").strip()
    container_path = data.get("container_path", "").strip()
    if not host_path or not container_path:
        return jsonify({"error": "host_path and container_path required"}), 400
    if not os.path.isdir(host_path):
        return jsonify({"error": f"Directory not found: {host_path}"}), 400

    mappings = load_global_mappings()
    for m in mappings:
        if m["id"] == mapping_id:
            m["host_path"] = host_path
            m["container_path"] = container_path
            save_global_mappings(mappings)
            recreated = recreate_all_containers()
            return jsonify({"mapping": m, "recreated": recreated})
    return jsonify({"error": "Mapping not found"}), 404


@app.route("/api/mappings/<mapping_id>", methods=["DELETE"])
def api_delete_mapping(mapping_id):
    mappings = load_global_mappings()
    new_mappings = [m for m in mappings if m["id"] != mapping_id]
    if len(new_mappings) == len(mappings):
        return jsonify({"error": "Mapping not found"}), 404
    save_global_mappings(new_mappings)
    recreated = recreate_all_containers()
    return jsonify({"status": "deleted", "recreated": recreated})


# ── Sessions ──────────────────────────────────────────────────────────────────

@app.route("/api/sessions")
def api_get_sessions():
    try:
        c = get_client()
        containers = c.containers.list(all=True, filters={"label": f"{LABEL_MANAGED}=true"})
        cm = load_container_mappings()
        sessions = []
        for container in containers:
            raw_mounts = [
                {"host": m["Source"], "container": m["Destination"]}
                for m in container.attrs.get("Mounts", [])
                if m.get("Type") == "bind"
            ]
            # /workspace always first, then alphabetical by container path
            raw_mounts.sort(key=lambda m: (m["container"] != "/workspace", m["container"]))
            sessions.append({
                "id": container.short_id,
                "name": container.name,
                "status": container.status,
                "mounts": raw_mounts,
                "created": container.attrs.get("Created", ""),
                "extra_mappings": cm.get(container.name, []),
            })
        sessions.sort(key=lambda s: s["name"])
        return jsonify(sessions)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/sessions", methods=["POST"])
def api_create_session():
    data = request.get_json() or {}
    path = data.get("path", "").strip()
    if not path:
        return jsonify({"error": "path is required"}), 400

    path = os.path.abspath(path)
    if not os.path.isdir(path):
        return jsonify({"error": f"Directory not found: {path}"}), 400

    try:
        c = get_client()
        # Reuse existing container (running or stopped) for this path
        for container in c.containers.list(all=True, filters={"label": f"{LABEL_MANAGED}=true"}):
            if container.labels.get(LABEL_HOST_PATH) == path:
                if container.status != "running":
                    container.start()
                name = container.name
                return jsonify({
                    "id": container.short_id,
                    "name": name,
                    "path": path,
                    "attach_cmd": f"docker exec -it -w /workspace {name} opencode --continue",
                })

        name = f"soc-{uuid.uuid4().hex[:8]}"
        volumes = build_volumes(path, name)
        container = c.containers.run(
            IMAGE_NAME,
            name=name,
            volumes=volumes,
            labels={LABEL_MANAGED: "true", LABEL_HOST_PATH: path},
            command=["sleep", "infinity"],
            detach=True,
            tty=True,
            stdin_open=True,
        )
        return jsonify({
            "id": container.short_id,
            "name": name,
            "path": path,
            "attach_cmd": f"docker exec -it -w /workspace {name} opencode --continue",
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/sessions/<session_id>/stop", methods=["POST"])
def api_stop_session(session_id):
    try:
        c = get_client()
        for container in c.containers.list(filters={"label": f"{LABEL_MANAGED}=true"}):
            if container.short_id == session_id or container.name == session_id:
                try:
                    container.stop(timeout=5)
                except Exception:
                    pass
                return jsonify({"status": "stopped"})
        return jsonify({"error": "Session not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/sessions/<session_id>/start", methods=["POST"])
def api_start_session(session_id):
    try:
        c = get_client()
        for container in c.containers.list(all=True, filters={"label": f"{LABEL_MANAGED}=true"}):
            if container.short_id == session_id or container.name == session_id:
                container.start()
                return jsonify({"status": "running"})
        return jsonify({"error": "Session not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/sessions/<session_id>", methods=["DELETE"])
def api_delete_session(session_id):
    try:
        c = get_client()
        for container in c.containers.list(all=True, filters={"label": f"{LABEL_MANAGED}=true"}):
            if container.short_id == session_id or container.name == session_id:
                name = container.name
                try:
                    if container.status == "running":
                        container.stop(timeout=5)
                except Exception:
                    pass
                try:
                    container.remove()
                except Exception:
                    pass
                cm = load_container_mappings()
                if name in cm:
                    del cm[name]
                    save_container_mappings(cm)
                try:
                    get_client().volumes.get(state_volume_name(name)).remove()
                except Exception:
                    pass
                return jsonify({"status": "removed"})
        return jsonify({"error": "Session not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ── Per-container mappings ────────────────────────────────────────────────────

@app.route("/api/sessions/<session_id>/mappings", methods=["GET"])
def api_get_session_mappings(session_id):
    container = find_container(session_id)
    if not container:
        return jsonify({"error": "Session not found"}), 404
    cm = load_container_mappings()
    return jsonify(cm.get(container.name, []))


@app.route("/api/sessions/<session_id>/mappings", methods=["POST"])
def api_add_session_mapping(session_id):
    container = find_container(session_id)
    if not container:
        return jsonify({"error": "Session not found"}), 404

    data = request.get_json() or {}
    host_path = data.get("host_path", "").strip()
    container_path = data.get("container_path", "").strip()
    if not host_path or not container_path:
        return jsonify({"error": "host_path and container_path required"}), 400
    if not os.path.isdir(host_path):
        return jsonify({"error": f"Directory not found: {host_path}"}), 400

    cm = load_container_mappings()
    name = container.name
    cm.setdefault(name, [])
    entry = {"id": uuid.uuid4().hex[:8], "host_path": host_path, "container_path": container_path}
    cm[name].append(entry)
    save_container_mappings(cm)

    try:
        recreate_container(container)
        return jsonify({"mapping": entry, "recreated": [{"name": name, "status": "recreated"}]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/sessions/<session_id>/mappings/<mapping_id>", methods=["PUT"])
def api_update_session_mapping(session_id, mapping_id):
    container = find_container(session_id)
    if not container:
        return jsonify({"error": "Session not found"}), 404

    data = request.get_json() or {}
    host_path = data.get("host_path", "").strip()
    container_path = data.get("container_path", "").strip()
    if not host_path or not container_path:
        return jsonify({"error": "host_path and container_path required"}), 400
    if not os.path.isdir(host_path):
        return jsonify({"error": f"Directory not found: {host_path}"}), 400

    cm = load_container_mappings()
    name = container.name
    for m in cm.get(name, []):
        if m["id"] == mapping_id:
            m["host_path"] = host_path
            m["container_path"] = container_path
            save_container_mappings(cm)
            try:
                recreate_container(container)
                return jsonify({"mapping": m, "recreated": [{"name": name, "status": "recreated"}]})
            except Exception as e:
                return jsonify({"error": str(e)}), 500
    return jsonify({"error": "Mapping not found"}), 404


@app.route("/api/sessions/<session_id>/mappings/<mapping_id>", methods=["DELETE"])
def api_delete_session_mapping(session_id, mapping_id):
    container = find_container(session_id)
    if not container:
        return jsonify({"error": "Session not found"}), 404

    cm = load_container_mappings()
    name = container.name
    original = cm.get(name, [])
    new_list = [m for m in original if m["id"] != mapping_id]
    if len(new_list) == len(original):
        return jsonify({"error": "Mapping not found"}), 404
    cm[name] = new_list
    save_container_mappings(cm)

    try:
        recreate_container(container)
        return jsonify({"status": "deleted", "recreated": [{"name": name, "status": "recreated"}]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/sessions/<session_id>/open", methods=["POST"])
def api_open_session(session_id):
    try:
        c = get_client()
        for container in c.containers.list(filters={"label": f"{LABEL_MANAGED}=true"}):
            if container.short_id == session_id or container.name == session_id:
                name = container.name
                cmd = f"docker exec -it -w /workspace {name} opencode --continue"
                if sys.platform == "win32":
                    subprocess.Popen(
                        f'start "OpenCode — {name}" cmd /k {cmd}',
                        shell=True,
                    )
                elif sys.platform == "darwin":
                    subprocess.Popen([
                        "osascript", "-e",
                        f'tell application "Terminal" to do script "{cmd}"',
                    ])
                else:
                    for term in ["x-terminal-emulator", "gnome-terminal", "xterm", "konsole"]:
                        if shutil.which(term):
                            subprocess.Popen([term, "-e", cmd])
                            break
                return jsonify({"status": "launched"})
        return jsonify({"error": "Session not found or not running"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"\n  SecureOpenCode -> http://localhost:{port}\n")
    app.run(host="0.0.0.0", port=port, debug=False)

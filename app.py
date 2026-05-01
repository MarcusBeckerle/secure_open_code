import os
import uuid
import docker
import docker.errors
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
IMAGE_NAME = "secure-opencode"
LABEL_MANAGED = "opencode.managed"
LABEL_HOST_PATH = "opencode.host_path"


def get_client():
    return docker.from_env()


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


@app.route("/api/sessions")
def api_get_sessions():
    try:
        c = get_client()
        containers = c.containers.list(filters={"label": f"{LABEL_MANAGED}=true"})
        sessions = []
        for container in containers:
            mounts = [
                {"host": m["Source"], "container": m["Destination"]}
                for m in container.attrs.get("Mounts", [])
                if m.get("Type") == "bind"
            ]
            sessions.append({
                "id": container.short_id,
                "name": container.name,
                "status": container.status,
                "mounts": mounts,
                "created": container.attrs.get("Created", ""),
            })
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
        name = f"soc-{uuid.uuid4().hex[:8]}"
        container = c.containers.run(
            IMAGE_NAME,
            name=name,
            volumes={path: {"bind": "/workspace", "mode": "rw"}},
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
            "attach_cmd": f"docker exec -it -w /workspace {name} opencode",
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/sessions/<session_id>", methods=["DELETE"])
def api_delete_session(session_id):
    try:
        c = get_client()
        containers = c.containers.list(filters={"label": f"{LABEL_MANAGED}=true"})
        for container in containers:
            if container.short_id == session_id or container.name == session_id:
                container.stop(timeout=5)
                container.remove()
                return jsonify({"status": "stopped"})
        return jsonify({"error": "Session not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"\n  SecureOpenCode -> http://localhost:{port}\n")
    app.run(host="0.0.0.0", port=port, debug=False)

import os
import requests
from flask import Flask, jsonify, request, render_template, send_from_directory

app = Flask(__name__)

ROBLOX_VALIDATE = "https://auth.roblox.com/v1/usernames/validate"
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; RobloxUsernameCheck/1.0)"}


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/check")
def check():
    username = request.args.get("username", "").strip()
    if not username or len(username) > 20:
        return jsonify({"code": -1, "error": "invalid username"}), 400
    try:
        r = requests.get(
            ROBLOX_VALIDATE,
            params={"birthday": "2000-01-01", "context": "signup", "username": username},
            headers=HEADERS,
            timeout=8,
        )
        return jsonify(r.json()), r.status_code
    except requests.Timeout:
        return jsonify({"code": -1, "error": "timeout"}), 504
    except Exception as e:
        return jsonify({"code": -1, "error": str(e)}), 500


@app.route("/static/<path:filename>")
def static_files(filename):
    return send_from_directory("static", filename)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 10000))
    app.run(host="0.0.0.0", port=port)

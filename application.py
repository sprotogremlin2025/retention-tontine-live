from flask import Flask, send_from_directory
app = Flask(__name__, static_folder="static")

@app.route("/")
def index():
    return send_from_directory("templates", "app.html")

# Optional: serve other static files (css/js)
@app.route("/<path:path>")
def static_proxy(path):
    return send_from_directory("templates", path)


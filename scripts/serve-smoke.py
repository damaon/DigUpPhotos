"""Smoke test of `digup serve` as it runs, without the model: it indexes a folder (file names and document words are
searchable before the model is there), and the page's API finds a document, makes a thumbnail and serves a file.
    python3 scripts/serve-smoke.py <digup> <folder with sample.docx and photo.jpg>
CI runs it on Windows, where paths are C:\\..., and it runs on Linux and macOS alike."""
import http.cookiejar, json, os, subprocess, sys, tempfile, time, urllib.parse, urllib.request

digup, folder = sys.argv[1], os.path.abspath(sys.argv[2])
index = tempfile.mkdtemp(prefix="digup-smoke-")
port = 7899
server = subprocess.Popen([digup, "serve", folder, "--index", index, "--port", str(port)])
base = f"http://127.0.0.1:{port}"
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
def get(path, raw=False):
    response = opener.open(base + path, timeout=30)
    data = response.read()
    return (response, data) if raw else json.loads(data)
try:
    for _ in range(60):
        try:
            opener.open(base + "/", timeout=5).read()
            break
        except OSError:
            time.sleep(1)
    status = {}
    for _ in range(90):
        status = get("/api/status")
        if status.get("lastSync") and status.get("phase") != "syncing" and status.get("files"):
            break
        time.sleep(2)
    print("status:", {k: status.get(k) for k in ("phase", "files", "error", "missing")})
    assert status.get("files", {}).get("doc") == 1, "the document wasn't found"
    hits = get("/api/search?q=" + urllib.parse.quote_plus("sample"))["results"]
    print("search:", [(h["name"], h["kind"]) for h in hits])
    names = {h["name"] for h in hits}
    assert "sample.docx" in names, "no sample.docx among the results"
    photo = next(h for h in get("/api/search?q=photo.jpg")["results"] if h["name"] == "photo.jpg")
    response, data = get("/api/thumb?size=200&path=" + urllib.parse.quote(photo["path"]), raw=True)
    print("thumbnail:", response.status, response.headers["Content-Type"], len(data))
    assert data[:2] == b"\xff\xd8", "the thumbnail isn't a JPEG"
    response, data = get("/api/file?path=" + urllib.parse.quote(photo["path"]), raw=True)
    assert data == open(os.path.join(folder, "photo.jpg"), "rb").read(), "the file served isn't the file"
    print("serve works:", photo["path"])
finally:
    server.terminate()

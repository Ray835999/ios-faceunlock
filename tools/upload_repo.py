#!/usr/bin/env python3
"""Upload FaceUnlock project to GitHub via the Contents API (github.com is unreachable
from this network; api.github.com works; git push via gh-proxy strips auth)."""
import base64, json, os, sys, urllib.request, time

ROOT = sys.argv[1]
REPO = sys.argv[2]          # owner/name
TOKEN = os.environ["GH_TOKEN"]
API = "https://api.github.com"

def api(method, path, payload=None):
    url = f"{API}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read()
            return r.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]

# collect files (skip VCS dirs by PATH COMPONENT - '.git' substring also matches '.github')
files = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    rel_dir = os.path.relpath(dirpath, ROOT)
    parts = [] if rel_dir == "." else rel_dir.split(os.sep)
    dirnames[:] = [d for d in dirnames if d != ".git"]
    for fn in filenames:
        if fn.endswith((".deb", ".tar.xz", ".sdk")):
            continue
        files.append(os.path.join(dirpath, fn))

print(f"uploading {len(files)} files to {REPO}")
ok = fail = 0
for path in sorted(files):
    rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
    with open(path, "rb") as f:
        content = base64.b64encode(f.read()).decode()
    st, resp = api("PUT", f"/repos/{REPO}/contents/{rel}",
                   {"message": f"add {rel}", "content": content, "branch": "main"})
    if st in (200, 201):
        ok += 1
        print(f"  OK   {rel}")
    else:
        fail += 1
        print(f"  FAIL {rel}: {st} {resp}")
    time.sleep(0.3)

print(f"done: ok={ok} fail={fail}")
sys.exit(1 if fail else 0)

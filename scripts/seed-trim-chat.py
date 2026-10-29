#!/usr/bin/env python3
"""Seed a chat that trips the image-budget guard, for ImageTrimLiveTests.

Creates a chat with 55 image-bearing user turns (one also carrying a PDF, so
the live test can prove non-image files survive a trim) on the server the
simulator is signed into, and writes its id to /tmp/tiai_trim_chat.txt — the
file the live test skips itself without.

Auth: the Open WebUI token, written to /tmp/tiai_token.txt. On a simulator
that is signed in, the fastest honest way to get it is the app's own session
(a DEBUG-only dump next to TIAI_DEBUG_DUMP, or the keychain on a jailbroken
box); paste it into that file by hand rather than storing it anywhere durable.

Delete the chat afterwards (the script prints the id):

    curl -X DELETE -H "Authorization: Bearer $TOKEN" \
        https://your.server/api/v1/chats/<id>
"""
import json
import time
import urllib.request

BASE = "https://chat.wobker.co/api/v1"
PNG = ("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
       "AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
N = 55  # > maxImagesPerRequest (50), so the guard trips on the next send


def req(method, path, body=None):
    r = urllib.request.Request(
        BASE + path, method=method,
        headers={"Authorization": f"Bearer {TOKEN}",
                 "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(r, timeout=20) as resp:
        return json.loads(resp.read())


TOKEN = open("/tmp/tiai_token.txt").read().strip()

created = req("POST", "/chats/new", {"chat": {
    "title": "TRIM SIM (delete me)", "models": [], "messages": [], "tags": [],
    "timestamp": int(time.time() * 1000),
    "history": {"currentId": None, "messages": {}}}})
cid = created["id"]

msgs, prev = {}, None
for i in range(1, N + 1):
    u, a = f"u{i}", f"a{i}"
    m = {"id": u, "role": "user", "done": True, "parentId": prev,
         "childrenIds": [a],
         "content": [{"type": "text", "text": f"pic {i}"},
                     {"type": "image_url", "image_url": {"url": PNG}}]}
    if i == 1:  # the oldest message also carries a PDF the trim must keep
        m["files"] = [{"id": "doc-1", "name": "report.pdf",
                       "file": {"id": "doc-1",
                                "meta": {"content_type": "application/pdf"}}}]
    msgs[u] = m
    msgs[a] = {"id": a, "role": "assistant", "done": True, "parentId": u,
               "childrenIds": [], "content": f"answer {i}"}
    prev = a

req("POST", f"/chats/{cid}", {"chat": {
    "title": "TRIM SIM (delete me)",
    "history": {"messages": msgs, "currentId": f"a{N}"}}})

open("/tmp/tiai_trim_chat.txt", "w").write(cid)
print(f"seeded {cid} with {N} images — delete it when the test run is done:")
print(f"  curl -X DELETE -H 'Authorization: Bearer $TOKEN' {BASE}/chats/{cid}")

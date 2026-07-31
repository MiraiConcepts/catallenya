#!/usr/bin/env python3
"""Fake Anthropic Messages endpoint, for exercising api_post's retry path offline.

Started by run.sh with a scripted list of status codes, e.g. "429,429,200": the
first request gets 429, the second 429, the third 200. That is the only way to
prove the retry loop actually retries and actually stops — a real API failure
cannot be summoned on demand, and paying for one to test would defeat the point.

Serves every consumer of ai.lib.sh, not just capture: point API_URL at it and the
same loop that drives a screenshot triage drives a document classification.

Prints the listening port on stdout, then serves until killed.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

CODES = [int(c) for c in sys.argv[1].split(",")]
STATE = {"n": 0}
LOCK = threading.Lock()

# Minimal well-formed reply: a consumer reads .stop_reason and the first text block,
# and parses that block as its structured answer.
#
# Extra argv are JSON payloads, returned one per request and then the last repeating.
# That is what lets documents drive a two-call sequence — classify, then the
# adversarial verify, which has a DIFFERENT schema — from the same sink capture uses
# for a single call. Without arguments it serves the capture-shaped proposal below,
# so the existing api_post cases are unaffected.
DEFAULT = {
    "is_event": True, "needs_human": False, "calendar": "general",
    "title": "Sink Lunch", "date": "2026-07-26", "start_time": "13:00",
    "end_time": "14:00", "all_day": False, "timezone": "Asia/Singapore",
    "recurrence": "none", "location": None, "description": None,
    "reason": None, "alternatives": [],
}
PAYLOADS = [json.loads(a) for a in sys.argv[2:]] or [DEFAULT]


def ok_body(i):
    p = PAYLOADS[i] if i < len(PAYLOADS) else PAYLOADS[-1]
    return json.dumps({
        "stop_reason": "end_turn",
        "content": [{"type": "text", "text": json.dumps(p)}],
    }).encode()


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        with LOCK:
            i = STATE["n"]
            STATE["n"] += 1
        code = CODES[i] if i < len(CODES) else CODES[-1]
        body = ok_body(i) if code == 200 else json.dumps(
            {"type": "error", "error": {"type": "sink", "message": f"forced {code}"}}
        ).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()

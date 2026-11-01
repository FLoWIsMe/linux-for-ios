#!/usr/bin/env python3
# Minimal mock of the Anthropic Messages streaming API for exercising Tern's `claude` command.
# Turn 1 (no tool_result in the request): stream some text, then a run_command tool_use.
# Turn 2 (request carries a tool_result): stream a final text and end the turn.
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def sse(block):
    return f"event: {block['type']}\ndata: {json.dumps(block)}\n\n".encode()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        messages = body.get("messages", [])
        has_tool_result = any(
            isinstance(m.get("content"), list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in m["content"]
            )
            for m in messages
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def send(b):
            self.wfile.write(sse(b)); self.wfile.flush()

        send({"type": "message_start", "message": {"id": "msg", "type": "message", "role": "assistant", "content": [], "stop_reason": None, "usage": {"input_tokens": 1, "output_tokens": 1}}})
        send({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        if not has_tool_result:
            for piece in ["On it. ", "Running the echo now."]:
                send({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": piece}})
            send({"type": "content_block_stop", "index": 0})
            send({"type": "content_block_start", "index": 1, "content_block": {"type": "tool_use", "id": "toolu_1", "name": "run_command", "input": {}}})
            send({"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": json.dumps({"command": "echo hello-from-claude"})}})
            send({"type": "content_block_stop", "index": 1})
            send({"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 5}})
        else:
            for piece in ["All done. ", "The command printed hello-from-claude."]:
                send({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": piece}})
            send({"type": "content_block_stop", "index": 0})
            send({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 5}})
        send({"type": "message_stop"})

ThreadingHTTPServer(("127.0.0.1", 8099), Handler).serve_forever()

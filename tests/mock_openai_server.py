import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        request_body = self.rfile.read(content_length).decode("utf-8", errors="replace")

        response = {
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "created": 0,
            "model": "mock-model",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": json.dumps(
                            {
                                "verdict": "approve",
                                "review_markdown": "## Summary\nMock reviewer completed successfully.\n\n## Validation\n- OpenAI-compatible endpoint contract worked\n- PR corpus was assembled and analyzed\n\n## Request Snapshot\n- Request bytes: %s"
                                % len(request_body),
                                "packages": [],
                            }
                        ),
                    },
                    "finish_reason": "stop",
                }
            ],
        }

        body = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 18080), Handler)
    server.serve_forever()

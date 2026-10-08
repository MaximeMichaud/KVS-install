"""A loopback HTTP server standing in for GitHub in the release script suites.

    python3 http-stub.py <routes> <port-file> <request-log>

It answers GET requests from <routes>, a tab separated file read again on
every request, so a suite can change the answers between two runs:

    <path and query><TAB><status><TAB><body file or -><TAB><Location or ->[<TAB>cut]

With "cut", the answer announces its body but stops right after the
headers, as a dropped connection leaves it. A path the file does not list
gets a 404. Every request is appended to <request-log> as
"<path and query><TAB><Authorization header or ->". The server listens on
127.0.0.1, on a port the system picks, and writes that port to <port-file>
once it accepts connections.
"""

import http.server
import os
import sys

routes_path, port_path, log_path = sys.argv[1:4]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log_path, "a", encoding="utf-8") as log:
            log.write("%s\t%s\n" % (self.path, self.headers.get("Authorization", "-")))
        status, body, location, cut = 404, b"Not Found", None, False
        with open(routes_path, encoding="utf-8") as routes:
            for line in routes:
                fields = line.rstrip("\n").split("\t")
                if len(fields) in (4, 5) and fields[0] == self.path:
                    status = int(fields[1])
                    body = b""
                    if fields[2] != "-":
                        with open(fields[2], "rb") as source:
                            body = source.read()
                    if fields[3] != "-":
                        location = fields[3]
                    cut = len(fields) == 5 and fields[4] == "cut"
                    break
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not cut:
            self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_path + ".tmp", "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_address[1]))
os.rename(port_path + ".tmp", port_path)
server.serve_forever()

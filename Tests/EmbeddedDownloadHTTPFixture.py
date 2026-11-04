#!/usr/bin/env python3
"""Loopback-only disposable HTTP/TLS fixtures; no third-party data or services."""
import argparse, collections, gzip, http.server, json, socket, ssl, threading, time, urllib.parse
BODY = bytes(range(256)) * 2048
SLOW = BODY * 4
COUNTS = collections.Counter()
RANGES = collections.Counter()
ACTIVE = collections.Counter()
MAX_ACTIVE = collections.Counter()
LOCK = threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        with LOCK:
            COUNTS[path] += 1
            count = COUNTS[path]
            if self.headers.get('Range'): RANGES[path] += 1
        if path == '/stats':
            data = json.dumps({'counts':dict(COUNTS),'ranges':dict(RANGES),'maxActive':dict(MAX_ACTIVE)}).encode()
            self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data); return
        if path == '/loop': self.send_response(302); self.send_header('Location','/loop'); self.send_header('Content-Length','0'); self.end_headers(); return
        if path == '/retry-date':
            self.send_response(429); self.send_header('Content-Length','0'); self.send_header('Retry-After','Fri, 01 Jan 2100 00:00:00 GMT'); self.end_headers(); return
        if path in ('/retry-long','/retry-inf'):
            self.send_response(429); self.send_header('Content-Length','0'); self.send_header('Retry-After','2592000' if path == '/retry-long' else 'inf'); self.end_headers(); return
        if path in ('/auth','/forbidden','/missing','/server','/retry'):
            status = {'/auth':401,'/forbidden':403,'/missing':404,'/server':503,'/retry':429}[path]
            if path != '/retry' or count == 1:
                self.send_response(status); self.send_header('Content-Length','0'); self.send_header('Retry-After','1'); self.end_headers(); return
        if path == '/compressed':
            data = gzip.compress(BODY); self.send_response(200); self.send_header('Content-Encoding','gzip'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data); return
        data = SLOW if path.startswith('/slow') or path in ('/range','/ignore','/wrong','/changed','/changed-length','/norange','/short-range','/416') else BODY
        start = 0; etag = '"fixture-v1"'; status = 200
        if self.headers.get('Range'):
            start = int(self.headers['Range'].split('=')[1].split('-')[0])
            if path == '/ignore': start = 0
            elif path == '/changed': etag = '"fixture-v2"'; status = 206
            elif path == '/416': self.send_response(416); self.send_header('Content-Length','0'); self.end_headers(); return
            else: status = 206
        payload = data[start:]
        if path == '/short-range' and status == 206: payload = payload[:32768]
        self.send_response(status)
        if path != '/norange': self.send_header('ETag',etag)
        if path == '/long-name': self.send_header('Content-Disposition',"attachment; filename*=UTF-8''" + urllib.parse.quote('下载文件' * 100 + '.txt'))
        if path == '/names': self.send_header('Content-Disposition','attachment; filename="../../forbidden.txt"')
        if status == 206:
            begin = start+1 if path == '/wrong' else start
            total = len(data)+1024 if path == '/changed-length' else len(data)
            self.send_header('Content-Range',f'bytes {begin}-{start+len(payload)-1}/{total}')
        if path != '/unknown': self.send_header('Content-Length',str(len(payload)+(1024 if path == '/truncated' or path == '/network-once' and count == 1 else 0)))
        else: self.send_header('Connection','close')
        self.end_headers()
        with LOCK:
            ACTIVE['all'] += 1; MAX_ACTIVE['all'] = max(MAX_ACTIVE['all'],ACTIVE['all'])
            ACTIVE[self.headers.get('Host','')] += 1; MAX_ACTIVE[self.headers.get('Host','')] = max(MAX_ACTIVE[self.headers.get('Host','')],ACTIVE[self.headers.get('Host','')])
        try:
            for offset in range(0,len(payload),16384):
                self.wfile.write(payload[offset:offset+16384]); self.wfile.flush()
                if len(data) == len(SLOW): time.sleep(.015)
            if path in ('/unknown','/truncated') or path == '/network-once' and count == 1:
                self.close_connection = True
                try: self.connection.shutdown(socket.SHUT_RDWR)
                except OSError: pass
        except (BrokenPipeError,ConnectionResetError,ssl.SSLError): pass
        finally:
            with LOCK: ACTIVE['all'] -= 1; ACTIVE[self.headers.get('Host','')] -= 1
class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self,request,client_address): pass
if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('--info',required=True); p.add_argument('--cert'); p.add_argument('--key'); a=p.parse_args()
    http=Server(('127.0.0.1',0),Handler)
    info={'http':http.server_port}
    if a.cert:
        tls=Server(('127.0.0.1',0),Handler); ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(a.cert,a.key); tls.socket=ctx.wrap_socket(tls.socket,server_side=True); info['tls']=tls.server_port; threading.Thread(target=tls.serve_forever,daemon=True).start()
    with open(a.info,'w') as f: json.dump(info,f)
    http.serve_forever()

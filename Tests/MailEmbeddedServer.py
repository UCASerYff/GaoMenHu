#!/usr/bin/env python3
"""Isolated TLS IMAP/SMTP fixtures. Binds only loopback; never sends external mail."""
import base64
import json
from pathlib import Path
import socketserver
import ssl
import sys
import threading

root = Path(sys.argv[1])
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(root / 'cert.pem', root / 'key.pem')
headers = ('Date: Tue, 06 Oct 2026 18:20:00 +0800\r\n'
           'From: Local Test <sender@example.invalid>\r\n'
           'To: test@example.invalid\r\n'
           'Reply-To: reply@example.invalid\r\n'
           'Subject: =?UTF-8?B?5rWL6K+V6YKu5Lu2?=\r\n'
           'Message-ID: <fixture@example.invalid>\r\n')
body = headers + 'Content-Type: text/plain; charset=utf-8\r\n\r\nHello from local TLS IMAP.'
state = {'commands': [], 'recipients': [], 'message': '', 'messages': [], 'append': '', 'auth_count': 0}
lock = threading.Lock()

def save():
    (root / 'state.json').write_text(json.dumps(state))

class Server(socketserver.ThreadingTCPServer):
    immediate_tls = True
    allow_reuse_address = True
    daemon_threads = True
    def get_request(self):
        sock, address = super().get_request()
        return (context.wrap_socket(sock, server_side=True) if self.immediate_tls else sock), address
    def handle_error(self, request, client_address):
        pass

class StartTLSServer(Server):
    immediate_tls = False

class Base(socketserver.StreamRequestHandler):
    def line(self, text):
        self.wfile.write((text + '\r\n').encode())
        self.wfile.flush()
    def read(self):
        return self.rfile.readline().decode(errors='replace').rstrip('\r\n')
    def upgrade(self):
        self.connection = context.wrap_socket(self.connection, server_side=True)
        self.rfile = self.connection.makefile("rb")
        self.wfile = self.connection.makefile("wb")
    def auth(self, token):
        try: return base64.b64decode(token).split(b'\0')[-1] == b'test-pass'
        except Exception: return False

class IMAP(Base):
    def handle(self):
        self.line('* OK local IMAP fixture')
        while True:
            line = self.read()
            if not line: return
            tag, _, cmd = line.partition(' ')
            upper = cmd.upper()
            if not upper.startswith(('LOGIN', 'AUTHENTICATE')):
                with lock: state['commands'].append('IMAP ' + cmd); save()
            if upper.startswith('CAPABILITY'):
                self.line('* CAPABILITY IMAP4rev1 AUTH=PLAIN UIDPLUS MOVE STARTTLS')
            elif upper == 'STARTTLS':
                self.line(tag + ' OK begin TLS')
                self.upgrade()
                continue
            elif upper.startswith('AUTHENTICATE PLAIN'):
                self.line('+ ')
                if not self.auth(self.read()):
                    self.line(tag + ' NO invalid authentication'); continue
                with lock: state['auth_count'] += 1; save()
            elif upper.startswith('LOGIN'):
                if 'test-pass' not in cmd:
                    self.line(tag + ' NO invalid authentication'); continue
            elif upper.startswith('LIST'):
                self.line('* LIST (\\HasNoChildren) "/" "INBOX"')
                self.line('* LIST (\\Sent) "/" "Sent"')
                self.line('* LIST (\\Trash) "/" "Trash"')
            elif upper.startswith('SELECT'):
                self.line('* 2 EXISTS')
                self.line('* FLAGS (\\Seen \\Flagged \\Deleted)')
                self.line('* OK [UIDVALIDITY 42] valid')
                self.line('* OK [UIDNEXT 13] next')
            elif upper.startswith('UID SEARCH'):
                self.line('* SEARCH 11 12')
            elif upper.startswith('UID FETCH'):
                payload = (headers + '\r\n' if 'HEADER.FIELDS' in upper else body).encode()
                self.line('* 2 FETCH (UID 12 FLAGS (\\Seen) INTERNALDATE "06-Oct-2026 18:20:00 +0800" RFC822.SIZE ' + str(len(body.encode())) + ' BODY[] {' + str(len(payload)) + '}')
                self.wfile.write(payload)
                self.line(')')
            elif upper.startswith('APPEND'):
                if 'FailSent' in cmd:
                    self.line(tag + ' NO Sent unavailable')
                    continue
                n = int(cmd.rsplit('{', 1)[1].rstrip('}'))
                self.line('+ Ready for literal data')
                payload = self.rfile.read(n)
                self.rfile.readline()
                with lock: state['append'] = payload.decode(errors='replace'); save()
            elif upper.startswith('LOGOUT'):
                self.line('* BYE logout')
                self.line(tag + ' OK logout'); return
            elif upper.startswith(('UID STORE', 'UID MOVE', 'NOOP')):
                pass
            else:
                self.line(tag + ' BAD unsupported fixture command'); continue
            self.line(tag + ' OK completed')

class SMTP(Base):
    def handle(self):
        self.drop_response = False
        self.reject_data = False
        self.line('220 localhost ESMTP fixture')
        while True:
            cmd = self.read()
            if not cmd: return
            upper = cmd.upper()
            if not upper.startswith('AUTH'):
                with lock: state['commands'].append('SMTP ' + cmd); save()
            if upper.startswith(('EHLO', 'HELO')):
                self.line('250-localhost')
                self.line('250-STARTTLS')
                self.line('250-AUTH PLAIN')
                self.line('250 SIZE 40000000')
            elif upper == 'STARTTLS':
                self.line('220 Begin TLS')
                self.upgrade()
            elif upper.startswith('AUTH PLAIN'):
                parts = cmd.split(' ')
                if len(parts) > 2: token = parts[2]
                else: self.line('334 '); token = self.read()
                self.line('235 2.7.0 Accepted' if self.auth(token) else '535 5.7.8 Authentication failed')
            elif upper.startswith('MAIL FROM:'):
                self.line('250 2.1.0 sender accepted')
            elif upper.startswith('RCPT TO:'):
                if 'reject@example.invalid' in cmd:
                    self.line('550 5.1.1 Unknown recipient')
                    continue
                if 'drop@example.invalid' in cmd: self.drop_response = True
                if 'rejectdata@example.invalid' in cmd: self.reject_data = True
                with lock: state['recipients'].append(cmd.split(':', 1)[1]); save()
                self.line('250 2.1.5 recipient accepted')
            elif upper == 'DATA':
                self.line('354 End data with <CR><LF>.<CR><LF>')
                chunks = []
                while True:
                    line = self.rfile.readline()
                    if line == b'.\r\n': break
                    if line.startswith(b'..'): line = line[1:]
                    chunks.append(line)
                with lock:
                    state['message'] = b''.join(chunks).decode()
                    state['messages'].append(state['message'])
                    save()
                if self.drop_response: return
                if self.reject_data:
                    self.line('550 5.7.1 Rejected after content inspection')
                    continue
                self.line('250 2.0.0 Accepted')
            elif upper == 'QUIT': self.line('221 Bye'); return
            elif upper == 'NOOP': self.line('250 OK')
            else: self.line('500 unsupported fixture command')

imap = Server(('127.0.0.1', 0), IMAP)
smtp = Server(('127.0.0.1', 0), SMTP)
startimap = StartTLSServer(('127.0.0.1', 0), IMAP)
startsmtp = StartTLSServer(('127.0.0.1', 0), SMTP)
for server in (imap, smtp, startimap, startsmtp): threading.Thread(target=server.serve_forever, daemon=True).start()
(root / 'ports.json').write_text(json.dumps([imap.server_address[1], smtp.server_address[1], startimap.server_address[1], startsmtp.server_address[1]]))
print('Local TLS fixtures ready', flush=True)
threading.Event().wait()

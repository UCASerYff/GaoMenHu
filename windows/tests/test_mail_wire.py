import base64
import json
import shlex
import socketserver
import ssl
import threading
import urllib.error
import urllib.request
from contextlib import ExitStack, contextmanager
from datetime import datetime, timedelta, timezone
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from ipaddress import ip_address

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from gaomenhu.server import PortalServer
from gaomenhu.service import PortalService

ACCOUNT = "fixture@example.test"
PASSWORD = "isolated-mail-password"


def localhost_tls(tmp_path, monkeypatch):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, "127.0.0.1")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(hours=1))
            .not_valid_after(now + timedelta(hours=2))
            .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ip_address("127.0.0.1"))]), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True).sign(key, hashes.SHA256()))
    certificate = tmp_path / "localhost-test.pem"
    certificate.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    secret = tmp_path / "localhost-test-key.pem"
    secret.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    monkeypatch.setenv("SSL_CERT_FILE", str(certificate))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, secret)
    return context


class FixtureIMAP(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(8)
        with self.server.tls.wrap_socket(self.request, server_side=True) as connection, connection.makefile("rb") as incoming:
            connection.sendall(b"* OK isolated IMAP server\r\n")
            while data := incoming.readline(16384):
                tag, command, *arguments = data.strip().split(maxsplit=2)
                command = command.upper()
                args = arguments[0] if arguments else b""
                payload = b""
                result = b"OK fixture\r\n"
                if command == b"CAPABILITY":
                    payload = b"* CAPABILITY IMAP4rev1 MOVE\r\n"
                elif command == b"LOGIN":
                    assert shlex.split(args.decode()) == [ACCOUNT, PASSWORD]
                    self.server.logins += 1
                elif command == b"LIST":
                    payload = b'* LIST (\\HasNoChildren) "/" "INBOX"\r\n* LIST (\\HasNoChildren) "/" "Archive"\r\n'
                elif command in (b"SELECT", b"EXAMINE"):
                    payload = b"* 1 EXISTS\r\n* OK [UIDVALIDITY 42] fixture\r\n"
                elif command == b"UID" and args.startswith(b"SEARCH"):
                    payload = b"* SEARCH 7\r\n"
                elif command == b"UID" and args.startswith(b"FETCH"):
                    data = self.server.message
                    metadata = f"* 1 FETCH (UID 7 FLAGS () RFC822.SIZE {len(data)}".encode()
                    if b"HEADER.FIELDS" in args:
                        headers = data.split(b"\r\n\r\n", 1)[0] + b"\r\n\r\n"
                        payload = metadata + f" BODY[HEADER] {{{len(headers)}}}\r\n".encode() + headers + b")\r\n"
                    elif b"BODY.PEEK[]" in args:
                        payload = metadata + f" BODY[] {{{len(data)}}}\r\n".encode() + data + b")\r\n"
                    else:
                        payload = metadata + b")\r\n"
                elif command == b"UID" and args.startswith(b"STORE"):
                    self.server.flags.append(args)
                elif command == b"LOGOUT":
                    connection.sendall(b"* BYE fixture logout\r\n" + tag + b" OK done\r\n")
                    return
                else:
                    result = b"BAD unsupported fixture command\r\n"
                connection.sendall(payload + tag + b" " + result)


class FixtureSMTP(socketserver.BaseRequestHandler):
    def handle(self):
        connection = self.request
        connection.settimeout(8)
        incoming = connection.makefile("rb")
        secured = authorized = False
        try:
            connection.sendall(b"220 isolated SMTP server\r\n")
            while data := incoming.readline(16384):
                command, *arguments = data.strip().split(maxsplit=1)
                command = command.upper()
                if command == b"EHLO":
                    response = b"250-localhost\r\n250 AUTH PLAIN\r\n" if secured else b"250-localhost\r\n250 STARTTLS\r\n"
                elif command == b"STARTTLS" and not secured:
                    connection.sendall(b"220 begin TLS\r\n")
                    incoming.close()
                    connection = self.server.tls.wrap_socket(connection, server_side=True)
                    incoming = connection.makefile("rb")
                    secured = True
                    continue
                elif command == b"AUTH" and secured:
                    mode, token = arguments[0].split(maxsplit=1)
                    assert mode == b"PLAIN"
                    assert base64.b64decode(token) == f"\0{ACCOUNT}\0{PASSWORD}".encode()
                    self.server.logins += 1
                    authorized = True
                    response = b"235 authenticated\r\n"
                elif command in (b"MAIL", b"RCPT") and authorized:
                    response = b"250 accepted\r\n"
                elif command == b"DATA" and authorized:
                    connection.sendall(b"354 send message\r\n")
                    lines = []
                    while (line := incoming.readline(16384)) != b".\r\n":
                        if not line:
                            return
                        lines.append(line[1:] if line.startswith(b"..") else line)
                    self.server.messages.append(BytesParser(policy=policy.default).parsebytes(b"".join(lines)))
                    response = b"250 queued\r\n"
                elif command == b"QUIT":
                    connection.sendall(b"221 goodbye\r\n")
                    return
                else:
                    response = b"503 unexpected fixture command\r\n"
                connection.sendall(response)
        finally:
            incoming.close()
            connection.close()


@contextmanager
def fixture_server(handler, tls):
    with socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler) as server:
        server.tls, server.logins, server.messages, server.flags = tls, 0, [], []
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield server
        finally:
            server.shutdown()
            worker.join(timeout=3)


def test_mail_center_uses_real_isolated_imaps_and_smtp_starttls(tmp_path, monkeypatch):
    tls = localhost_tls(tmp_path, monkeypatch)
    service = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["edge"])
    portal = PortalServer(service)
    threading.Thread(target=portal.serve_forever, daemon=True).start()

    def api(action, **payload):
        request = urllib.request.Request(f"http://127.0.0.1:{portal.port}/api/mail/{action}",
            data=json.dumps(payload).encode(), headers={"Content-Type": "application/json", "X-Gao-Token": service.page_token})
        try:
            response = urllib.request.urlopen(request, timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return json.load(response)

    with ExitStack() as stack:
        stack.callback(portal.shutdown)
        imap = stack.enter_context(fixture_server(FixtureIMAP, tls))
        smtp = stack.enter_context(fixture_server(FixtureSMTP, tls))
        fixture = EmailMessage(policy=policy.SMTP)
        fixture["From"] = "fixture-sender@example.test"
        fixture["To"] = ACCOUNT
        fixture["Subject"] = "验证码 112233"
        fixture["Message-ID"] = "<fixture@example.test>"
        fixture.set_content("Isolated fixture body")
        fixture.add_attachment(b"download-attachment", maintype="text", subtype="plain", filename="received.txt")
        imap.message = fixture.as_bytes()
        account = api("account", password=PASSWORD, account={"email": ACCOUNT, "imapHost": "127.0.0.1",
            "smtpHost": "127.0.0.1", "imapPort": imap.server_address[1], "smtpPort": smtp.server_address[1]})["account"]
        account_id = account["id"]
        assert not api("sync", id=account_id)["ok"]
        assert (imap.logins, smtp.logins) == (0, 0)
        authorized = api("authorize", id=account_id, sync=True)
        assert authorized["ok"], authorized
        mail = authorized["messages"][0]
        assert mail["id"].endswith("|INBOX|42|7")
        assert api("state")["messages"][0]["code"] == "112233"
        detail = api("message", id=mail["id"], load=True)
        assert "Isolated fixture body" in detail["message"]["body"]
        attachment = api("attachment", id=mail["id"], attachmentID="0")["attachment"]
        assert base64.b64decode(attachment["base64"]) == b"download-attachment"
        assert api("message-flag", id=mail["id"], flag="read")["ok"]
        assert b"(\\Seen)" in imap.flags[-1]
        draft = api("draft", draft={"accountID": account_id, "to": "local-recipient@example.test", "subject": "Wire fixture",
            "body": "Send via STARTTLS", "attachments": [{"filename": "send.txt", "type": "text/plain", "base64": "eA=="}]})["draft"]
        sent = api("send", draftID=draft["id"])
        assert sent["ok"], sent
        assert sent["submission"]["phase"] == "completed"
        assert not api("send", draftID=draft["id"])["ok"]
        assert smtp.logins == 1 and len(smtp.messages) == 1
        assert smtp.messages[0]["Subject"] == "Wire fixture"
        assert next(smtp.messages[0].iter_attachments()).get_payload(decode=True) == b"x"

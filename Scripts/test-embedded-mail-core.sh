#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-all}"
case "$MODE" in all|core|oauth|transport) ;; *) echo "usage: test-embedded-mail-core.sh [all|core|oauth|transport]" >&2; exit 1 ;; esac
BUILD_TEMP="$(mktemp -d /private/tmp/gaomenhu-mail-tests.XXXXXX)"
BUILD_ROOT="$BUILD_TEMP/Tests.noindex"
mkdir -m 700 "$BUILD_ROOT"
server_pid=''
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf "$BUILD_TEMP"
}
trap cleanup EXIT
# Caller holds the shared build lease. Native module tests use memory credentials;
# OAuth/transport fixtures bind only loopback and never open a real browser.
if [[ "$MODE" != oauth ]]; then
clang -arch arm64 -mmacosx-version-min=14.0 -c "$PROJECT_DIR/Sources/Mail/MailNative.c" -o "$BUILD_ROOT/MailNative.o"
fi
if [[ "$MODE" == all || "$MODE" == core ]]; then
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$BUILD_ROOT/cache" \
  -import-objc-header "$PROJECT_DIR/Sources/Mail/MailNative.h" "$BUILD_ROOT/MailNative.o" -lcurl \
  "$PROJECT_DIR/Sources/Mail/MailModels.swift" "$PROJECT_DIR/Sources/Mail/MailStorage.swift" "$PROJECT_DIR/Sources/Mail/MailSubmission.swift" \
  "$PROJECT_DIR/Sources/Mail/MailCredentialVault.swift" "$PROJECT_DIR/Sources/Mail/MailOAuth.swift" \
  "$PROJECT_DIR/Sources/Mail/MailTransport.swift" "$PROJECT_DIR/Sources/Mail/MailStore.swift" \
  "$PROJECT_DIR/Tests/MailEmbeddedCoreTests.swift" -o "$BUILD_ROOT/core-tests"
"$BUILD_ROOT/core-tests" "$BUILD_ROOT/Fixtures"
fi
if [[ "$MODE" == all || "$MODE" == oauth ]]; then
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$BUILD_ROOT/cache" \
  "$PROJECT_DIR/Sources/Mail/MailCredentialVault.swift" "$PROJECT_DIR/Sources/Mail/MailOAuth.swift" \
  "$PROJECT_DIR/Tests/MailEmbeddedOAuthTests.swift" -o "$BUILD_ROOT/oauth-tests"
"$BUILD_ROOT/oauth-tests"
fi
if [[ "$MODE" == all || "$MODE" == transport ]]; then
cat > "$BUILD_ROOT/cert.cnf" <<'CERT'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=localhost
[v3]
subjectAltName=DNS:localhost,IP:127.0.0.1
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
CERT
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$BUILD_ROOT/key.pem" -out "$BUILD_ROOT/cert.pem" -days 1 -config "$BUILD_ROOT/cert.cnf" > "$BUILD_ROOT/openssl.log" 2>&1
/usr/bin/python3 "$PROJECT_DIR/Tests/MailEmbeddedServer.py" "$BUILD_ROOT" > "$BUILD_ROOT/server.log" 2>&1 &
server_pid="$!"
for attempt in {1..100}; do [[ -f "$BUILD_ROOT/ports.json" ]] && break; sleep 0.05; done
[[ -f "$BUILD_ROOT/ports.json" ]] || { cat "$BUILD_ROOT/server.log"; exit 1; }
ports="$(/usr/bin/python3 -c 'import json,sys; print(*json.load(open(sys.argv[1])))' "$BUILD_ROOT/ports.json")"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$BUILD_ROOT/cache" \
  -import-objc-header "$PROJECT_DIR/Sources/Mail/MailNative.h" "$BUILD_ROOT/MailNative.o" -lcurl \
  "$PROJECT_DIR/Sources/Mail/MailTransport.swift" "$PROJECT_DIR/Tests/MailEmbeddedTransportTests.swift" -o "$BUILD_ROOT/transport-tests"
# Intentional word split: ports are precisely four fixture-generated integers.
"$BUILD_ROOT/transport-tests" "$BUILD_ROOT/cert.pem" $ports
/usr/bin/python3 - "$BUILD_ROOT/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert len(state['messages']) == 4, 'Unexpected SMTP DATA count'
assert '<secret@example.invalid>' in state['recipients']
assert 'secret@example.invalid' not in state['message']
assert state['messages'][0] == state['append']
assert any('UID MOVE' in cmd for cmd in state['commands'])
assert any('BODY.PEEK[]' in cmd for cmd in state['commands'])
assert not any('UID STORE 999' in cmd or 'UID MOVE 999' in cmd or 'UID FETCH 999' in cmd for cmd in state['commands'])
assert not any('test-pass' in cmd for cmd in state['commands'])
print('Mail loopback server: 8 protocol/byte/privacy assertions passed.')
PY
fi

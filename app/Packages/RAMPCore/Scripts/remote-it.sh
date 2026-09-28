#!/bin/bash
# Integration tests for the FTP/SFTP clients (plan 09-02) against throwaway local servers:
#   - /usr/sbin/sshd as the current user (key auth only, temp host key, temp authorized_keys)
#   - pyftpdlib in a venv: plain FTP + FTPES (explicit TLS, self-signed cert)
# Everything lives in a temp work dir and is killed / removed on exit.
#
# Usage: Scripts/remote-it.sh [--scratch-path DIR] [extra swift test args…]
# Env:   RAMP_IT_WORK  work dir (default: mktemp under $TMPDIR)
#        RAMP_IT_VENV  reuse a venv with pyftpdlib + pyopenssl (default: <work>/venv, removed)
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scratch-path) SWIFT_ARGS+=(--scratch-path "$2"); shift 2 ;;
        *) SWIFT_ARGS+=("$1"); shift ;;
    esac
done

WORK="${RAMP_IT_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/ramp-remote-it.XXXXXX")}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
VENV="${RAMP_IT_VENV:-$WORK/venv}"
PIDS=()

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    for pid in "${PIDS[@]:-}"; do
        [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
wait_port() {
    for _ in $(seq 1 100); do
        if nc -z 127.0.0.1 "$1" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    echo "server on port $1 did not start" >&2
    return 1
}

# --- SSH ---------------------------------------------------------------------------------
SSH_DIR="$WORK/ssh"
mkdir -p "$SSH_DIR" "$WORK/sftp-root"
chmod 700 "$SSH_DIR"
ssh-keygen -q -t ed25519 -N '' -f "$SSH_DIR/host_ed25519"
ssh-keygen -q -t ed25519 -N '' -C it-ed25519 -f "$SSH_DIR/id_ed25519"
ssh-keygen -q -t ed25519 -N 'it-passphrase' -C it-enc -f "$SSH_DIR/id_ed25519_enc"
ssh-keygen -q -t rsa -b 3072 -N '' -C it-rsa -f "$SSH_DIR/id_rsa"
ssh-keygen -q -t rsa -b 3072 -N 'it-passphrase' -C it-rsa-enc -f "$SSH_DIR/id_rsa_enc"
ssh-keygen -q -t ed25519 -N '' -C it-unauthorized -f "$SSH_DIR/id_unauthorized"
ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -C it-pem -f "$SSH_DIR/id_pem"
cat "$SSH_DIR/id_ed25519.pub" "$SSH_DIR/id_ed25519_enc.pub" "$SSH_DIR/id_rsa.pub" "$SSH_DIR/id_rsa_enc.pub" \
    > "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
SSH_PORT="$(free_port)"
cat > "$SSH_DIR/sshd_config" <<EOF
ListenAddress 127.0.0.1
HostKey $SSH_DIR/host_ed25519
PidFile $SSH_DIR/sshd.pid
AuthorizedKeysFile $SSH_DIR/authorized_keys
PubkeyAuthentication yes
# Default (modern) PubkeyAcceptedAlgorithms on purpose: SHA-1 "ssh-rsa" is rejected, so RSA keys
# must sign with rsa-sha2-512/256 (RFC 8332).
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
EOF
/usr/sbin/sshd -D -e -f "$SSH_DIR/sshd_config" -p "$SSH_PORT" 2>"$SSH_DIR/sshd.log" &
PIDS+=($!)
wait_port "$SSH_PORT"
HOSTKEY_FP="$(ssh-keygen -lf "$SSH_DIR/host_ed25519.pub" | awk '{print $2}')"

# --- FTP ---------------------------------------------------------------------------------
if [[ ! -x "$VENV/bin/python" ]] || ! "$VENV/bin/python" -c 'import pyftpdlib, OpenSSL' 2>/dev/null; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check pyftpdlib pyopenssl
fi
FTP_DIR="$WORK/ftp"
mkdir -p "$FTP_DIR/root"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" \
    -keyout "$FTP_DIR/key.pem" -out "$FTP_DIR/cert.pem" 2>/dev/null
FTP_PORT="$(free_port)"
FTPES_PORT="$(free_port)"
cat > "$FTP_DIR/server.py" <<'EOF'
# One pyftpdlib server per process (its IOLoop is a process-wide singleton).
import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer

mode, root, cert, key, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
auth = DummyAuthorizer()
auth.add_user("ramp", "secret-ščť", root, perm="elradfmwMT")
if mode == "tls":
    handler = TLS_FTPHandler
    handler.certfile = cert
    handler.keyfile = key
    handler.tls_control_required = True
    handler.tls_data_required = True
else:
    handler = FTPHandler
handler.authorizer = auth
FTPServer(("127.0.0.1", port), handler).serve_forever()
EOF
"$VENV/bin/python" "$FTP_DIR/server.py" plain "$FTP_DIR/root" "$FTP_DIR/cert.pem" "$FTP_DIR/key.pem" \
    "$FTP_PORT" >"$FTP_DIR/ftpd.log" 2>&1 &
PIDS+=($!)
"$VENV/bin/python" "$FTP_DIR/server.py" tls "$FTP_DIR/root" "$FTP_DIR/cert.pem" "$FTP_DIR/key.pem" \
    "$FTPES_PORT" >"$FTP_DIR/ftpes.log" 2>&1 &
PIDS+=($!)
wait_port "$FTP_PORT"
wait_port "$FTPES_PORT"

# --- Run ---------------------------------------------------------------------------------
export RAMP_REMOTE_IT=1
export RAMP_IT_SSH_PORT="$SSH_PORT" RAMP_IT_SSH_USER="$(id -un)" RAMP_IT_SSH_HOSTKEY_FP="$HOSTKEY_FP"
export RAMP_IT_SFTP_ROOT="$WORK/sftp-root" RAMP_IT_CITADEL_PORT="$(free_port)"
export RAMP_IT_KEY_ED25519="$SSH_DIR/id_ed25519" RAMP_IT_KEY_ED25519_ENC="$SSH_DIR/id_ed25519_enc"
export RAMP_IT_KEY_PASSPHRASE="it-passphrase" RAMP_IT_KEY_RSA="$SSH_DIR/id_rsa"
export RAMP_IT_KEY_RSA_ENC="$SSH_DIR/id_rsa_enc"
export RAMP_IT_KEY_UNAUTHORIZED="$SSH_DIR/id_unauthorized" RAMP_IT_KEY_PEM="$SSH_DIR/id_pem"
export RAMP_IT_FTP_PORT="$FTP_PORT" RAMP_IT_FTPES_PORT="$FTPES_PORT"
export RAMP_IT_FTP_USER="ramp" RAMP_IT_FTP_PASS="secret-ščť"

cd "$PKG"
set +e
swift test "${SWIFT_ARGS[@]}" --filter RemoteIntegration
STATUS=$?
set -e
if [[ $STATUS -ne 0 ]]; then
    echo "--- sshd.log"; tail -20 "$SSH_DIR/sshd.log" || true
    echo "--- ftpd.log"; tail -40 "$FTP_DIR/ftpd.log" || true
    echo "--- ftpes.log"; tail -40 "$FTP_DIR/ftpes.log" || true
fi
exit $STATUS

# Sourced by the engine checks (run_http.sh; TLS=… for run_vod.sh, run_formats.sh and run_probe.sh): a certificate
# authority of the checks' own and the HTTPS fronts (tls_proxy.mjs, Node.js) of vod_server.py, all on 127.0.0.1.
#
#   tls_make_certs <dir>       makes <dir>/ca.pem (the authority), <dir>/server.pem and server.key (127.0.0.1 and
#                              localhost), <dir>/wrong-name.pem and .key (another name only), <dir>/self-signed.pem and
#                              .key (no authority); once.
#   tls_start <port> <backend-port> <log> <tls_proxy.mjs options>...
#                              starts an HTTPS front of the server on <backend-port>; sets TLS_PID (one per call, see
#                              tls_stop_all). Fails when it does not listen.
#   tls_front <mode> <port> <backend-port> <log>
#                              tls_start with the options of a mode: 1.2 (TLS 1.2 only), 1.3 (TLS 1.3 only), h2 (TLS 1.3
#                              and HTTP/2 only).
#
#   tls_wrap <backend-port> <work-dir>
#                              TLS=1.2|1.3|h2 in run_vod.sh, run_formats.sh and run_probe.sh: an HTTPS front (tls_front
#                              $TLS) of their media server on <backend-port> + 100, B set to its address, the test
#                              authority exported for the engine. AVPlayer trusts only the system's authorities, so a
#                              case it plays itself fails over to the engine, as in the app when AVPlayer fails (HLS
#                              playlists, which only AVPlayer plays, are left out).
#
# The test authority is trusted only by the checks: the engine built with -DFLUXO_ENGINE_TESTING reads FLUXO_TEST_CA_FILE
# (its only anchor; FFmpeg's TLS gets it as ca_file); in the iOS Simulator it is added to the clone's keychain
# (xcrun simctl keychain <udid> add-root-cert). Never the Mac's keychain, never the app.
#
# Needs Node.js (TLS 1.3 and HTTP/2; the system's Python has neither) and the system's openssl (LibreSSL).

NODE=${NODE:-$(command -v node || true)}
TLS_PIDS=

tls_make_certs() {
    dir=$1
    [ -f "$dir/ca.pem" ] && [ -f "$dir/wrong-name.pem" ] && [ -f "$dir/self-signed.pem" ] && return 0
    mkdir -p "$dir"
    cat > "$dir/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
[dn]
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1, DNS:localhost
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
[wrong]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:fluxo-wrong-name.invalid
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
[self]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1, DNS:localhost
CNF
    q="-sha256"
    openssl ecparam -name prime256v1 -genkey -noout -out "$dir/ca.key" 2>/dev/null
    openssl req -new -x509 $q -key "$dir/ca.key" -days 30 -subj "/CN=Fluxo Engine Test CA" -config "$dir/openssl.cnf" -extensions ca \
        -out "$dir/ca.pem" 2>/dev/null
    for name in server wrong-name; do
        section=server
        [ "$name" = wrong-name ] && section=wrong
        openssl ecparam -name prime256v1 -genkey -noout -out "$dir/$name.key" 2>/dev/null
        openssl req -new $q -key "$dir/$name.key" -subj "/CN=Fluxo Engine Test $name" -config "$dir/openssl.cnf" -out "$dir/$name.csr" 2>/dev/null
        openssl x509 -req $q -in "$dir/$name.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -CAcreateserial -days 30 \
            -extfile "$dir/openssl.cnf" -extensions "$section" -out "$dir/$name.pem" 2>/dev/null
    done
    openssl ecparam -name prime256v1 -genkey -noout -out "$dir/self-signed.key" 2>/dev/null
    openssl req -new -x509 $q -key "$dir/self-signed.key" -days 30 -subj "/CN=Fluxo Engine Test self-signed" -config "$dir/openssl.cnf" \
        -extensions self -out "$dir/self-signed.pem" 2>/dev/null
    [ -s "$dir/ca.pem" ] && [ -s "$dir/server.pem" ] && [ -s "$dir/wrong-name.pem" ] && [ -s "$dir/self-signed.pem" ]
}

tls_start() {
    port=$1
    backend=$2
    log=$3
    shift 3
    if [ -z "$NODE" ]; then
        echo "error: the TLS checks need Node.js (node)" >&2
        return 1
    fi
    "$NODE" "$ROOT/Tools/EngineSmokeTest/tls_proxy.mjs" --port "$port" --backend "$backend" "$@" > "$log" 2>&1 &
    TLS_PID=$!
    TLS_PIDS="$TLS_PIDS $TLS_PID"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q "127.0.0.1:$port" && return 0
        sleep 0.5
    done
    echo "error: the HTTPS front is not listening on 127.0.0.1:$port (log: $log)" >&2
    return 1
}

tls_front() {
    mode=$1
    port=$2
    backend=$3
    log=$4
    case $mode in
    1.2) tls_start "$port" "$backend" "$log" --cert "$TLS_DIR/server.pem" --key "$TLS_DIR/server.key" --tls 1.2 ;;
    1.3) tls_start "$port" "$backend" "$log" --cert "$TLS_DIR/server.pem" --key "$TLS_DIR/server.key" --tls 1.3 ;;
    h2) tls_start "$port" "$backend" "$log" --cert "$TLS_DIR/server.pem" --key "$TLS_DIR/server.key" --tls 1.3 --h2 ;;
    *)
        echo "error: TLS=$mode: use 1.2, 1.3 or h2" >&2
        return 1
        ;;
    esac
}

tls_stop_all() {
    for pid in $TLS_PIDS; do
        kill "$pid" 2>/dev/null || true
    done
    TLS_PIDS=
}

tls_wrap() {
    TLS_DIR=$2/tls
    tls_make_certs "$TLS_DIR" || return 1
    export FLUXO_TEST_CA_FILE="$TLS_DIR/ca.pem"
    tls_front "$TLS" $(($1 + 100)) "$1" "$2/tls-front.log" || return 1
    B=https://127.0.0.1:$(($1 + 100))
    echo "[tls] the cases go through $B (TLS $TLS) to http://127.0.0.1:$1"
}

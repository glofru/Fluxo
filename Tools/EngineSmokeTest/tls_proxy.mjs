#!/usr/bin/env node
// HTTPS front of vod_server.py for the engine's TLS checks (run_http.sh, and TLS=… for run_vod.sh, run_formats.sh and
// run_probe.sh). Bound to 127.0.0.1 only, with a certificate of the test authority run_http.sh makes (never a real
// one). Every request goes to the plain HTTP server on 127.0.0.1:<backend> as it came (Range, User-Agent, Cookie,
// Authorization, …), one backend connection per request, so that the one-connection modes (/busy, /oneconn) still see
// the client's connections; a client that cancels (closes its connection, or resets its HTTP/2 stream) ends the
// backend request too.
//
//   node tls_proxy.mjs --port <port> --backend <port> --cert <pem> --key <pem> [--tls 1.2|1.3|any] [--h2] [--client-cert <ca.pem>]
//
// --tls 1.2: TLS 1.2 only (as Secure Transport's maximum); 1.3: TLS 1.3 only (a server Secure Transport cannot talk to);
// any: both. --h2: HTTP/2 only (ALPN h2; clients without it fail); otherwise HTTP/1.1. --client-cert: asks for a client
// certificate from that authority and refuses connections without one (a failed handshake). Logs each request with its
// HTTP and TLS versions: "[tls-proxy] GET /path HTTP/2.0 TLSv1.3 206".
import fs from 'node:fs';
import http from 'node:http';
import http2 from 'node:http2';
import https from 'node:https';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
    options: {
        port: { type: 'string' },
        backend: { type: 'string' },
        cert: { type: 'string' },
        key: { type: 'string' },
        tls: { type: 'string', default: 'any' },
        h2: { type: 'boolean', default: false },
        'client-cert': { type: 'string' },
    },
});
const HOST = '127.0.0.1';
const versions = {
    '1.2': { minVersion: 'TLSv1.2', maxVersion: 'TLSv1.2' },
    '1.3': { minVersion: 'TLSv1.3', maxVersion: 'TLSv1.3' },
    any: { minVersion: 'TLSv1.2', maxVersion: 'TLSv1.3' },
}[values.tls];
if (!values.port || !values.backend || !values.cert || !values.key || !versions) {
    console.error('usage: tls_proxy.mjs --port <port> --backend <port> --cert <pem> --key <pem> [--tls 1.2|1.3|any] [--h2] [--client-cert <ca.pem>]');
    process.exit(2);
}
const options = { cert: fs.readFileSync(values.cert), key: fs.readFileSync(values.key), ...versions };
if (values['client-cert']) {
    Object.assign(options, { ca: fs.readFileSync(values['client-cert']), requestCert: true, rejectUnauthorized: true });
}

// Headers that belong to one connection (and that HTTP/2 forbids).
const hopByHop = new Set(['connection', 'keep-alive', 'transfer-encoding', 'upgrade', 'proxy-connection', 'te', 'trailer']);

// Ends the client's side abruptly: the HTTP/2 stream is reset, the HTTP/1.1 connection closed.
function breakOff(req, res) {
    if (req.stream) {
        req.stream.close(http2.constants.NGHTTP2_INTERNAL_ERROR);
    } else {
        (req.socket ?? res.socket)?.destroy();
    }
}

function handle(req, res) {
    const headers = {};
    for (const [name, value] of Object.entries(req.headers)) {
        if (!name.startsWith(':') && !hopByHop.has(name)) {
            headers[name] = value;
        }
    }
    headers.host = req.headers[':authority'] ?? req.headers.host;
    // vod_server.py makes its absolute redirections https:// with it.
    headers['x-forwarded-proto'] = 'https';
    let tlsVersion = '?';
    try {
        tlsVersion = req.socket.getProtocol();
    } catch {
        // (Not a TLS socket.)
    }
    const upstream = http.request({ host: HOST, port: Number(values.backend), method: req.method, path: req.url, headers, agent: false }, (response) => {
        console.log(`[tls-proxy] ${req.method} ${req.url} HTTP/${req.httpVersion} ${tlsVersion} ${response.statusCode}`);
        const out = {};
        for (const [name, value] of Object.entries(response.headers)) {
            if (!hopByHop.has(name)) {
                out[name] = value;
            }
        }
        res.writeHead(response.statusCode, out);
        // A response the backend breaks off (/flaky/<bytes>/...) breaks off here at the same byte: the client's
        // connection (or HTTP/2 stream) ends abruptly. (The backend's reset itself reaches Node only once it reads again.)
        const flaky = /^\/flaky\/(\d+)\//.exec(req.url);
        let left = flaky ? Number(flaky[1]) : Infinity;
        response.on('data', (chunk) => {
            if (left <= 0) {
                return;
            }
            const part = chunk.length > left ? chunk.subarray(0, left) : chunk;
            left -= part.length;
            if (!res.write(part)) {
                response.pause();
                res.once('drain', () => response.resume());
            }
            if (left <= 0) {
                upstream.destroy();
                breakOff(req, res);
            }
        });
        response.on('end', () => res.end());
        response.on('error', () => breakOff(req, res));
    });
    upstream.on('error', () => breakOff(req, res));
    res.on('close', () => upstream.destroy());
    upstream.end();
}

const server = values.h2 ? http2.createSecureServer({ ...options, allowHTTP1: false }, handle) : https.createServer(options, handle);
server.on('tlsClientError', (error) => console.log(`[tls-proxy] TLS handshake failed: ${error.code ?? error.message}`));
server.listen(Number(values.port), HOST, () => {
    console.log(`[tls-proxy] https://${HOST}:${values.port} (TLS ${values.tls}${values.h2 ? ', HTTP/2 only' : ''}) -> http://${HOST}:${values.backend}`);
});

'use strict';
// Node built-ins only. SOCKS5 -> loopback HTTPS, restricted to ab.chatgpt.com:443.
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const https = require('node:https');
const { X509Certificate } = require('node:crypto');
const root = __dirname;
const file = name => path.join(root, name);
process.on('uncaughtException', fail);
const settings = JSON.parse(fs.readFileSync(file('runtime.json'), 'utf8').replace(/^\uFEFF/, ''));
const mode = settings.mode || 's5';
if (!['hosts', 's5'].includes(mode)) throw Error('Invalid runtime mode');
const HOST = 'ab.chatgpt.com', SOCKS_PORT = 1089, TLS_PORT = mode === 'hosts' ? 443 : 18443;

if (process.argv[2] === 'status') {
  const req = https.get({host: '127.0.0.1', port: TLS_PORT, path: '/health',
    servername: HOST, ca: new X509Certificate(fs.readFileSync(file('server.cer'))).toString(),
    timeout: 1500}, res => {
    let body = '';
    res.on('data', chunk => { body += chunk; });
    res.on('end', () => {
      try {
        const data = JSON.parse(body);
        if (res.statusCode !== 200 || data.service !== 'codex-local-mock-minimal' || data.root !== root) throw Error('Different service');
        console.log(JSON.stringify(data));
      } catch { process.exitCode = 1; }
    });
  });
  req.on('timeout', () => req.destroy());
  req.on('error', () => { process.exitCode = 1; });
  return;
}

function payload() {
  const input = JSON.parse(fs.readFileSync(file('overrides.json'), 'utf8').replace(/^\uFEFF/, ''));
  const out = {feature_gates: {}, dynamic_configs: {}, layer_configs: {},
    has_updates: true, time: Date.now(), hash_used: 'none', sdkParams: {}};
  for (const group of ['feature_gates', 'dynamic_configs', 'layer_configs']) {
    for (const [name, value] of Object.entries(input[group] || {})) {
      const entry = {name, value, rule_id: 'local-ui-test', secondary_exposures: [], id_type: 'stableID'};
      if (group === 'layer_configs') Object.assign(entry, {
        explicit_parameters: Object.keys(value), undelegated_secondary_exposures: []});
      out[group][name] = entry;
    }
  }
  return out;
}
payload(); // Fail early on invalid configuration.
let initialize = 0;
function record(req, status) {
  fs.appendFileSync(file('requests.jsonl'), JSON.stringify({time: new Date().toISOString(),
    method: req.method, path: req.url.split('?')[0], status}) + '\n');
}
const api = https.createServer({pfx: fs.readFileSync(file('server.pfx')),
  passphrase: settings.password, minVersion: 'TLSv1.2'}, (req, res) => {
  const url = req.url.split('?')[0];
  const origin = req.headers.origin;
  if (['app://-', 'null'].includes(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader('Vary', 'Origin');
  }
  const send = (status, body) => {
    const data = body === undefined ? '' : JSON.stringify(body);
    res.writeHead(status, {'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(data), 'Cache-Control': 'no-store', 'X-Local-Init-Mock': '1'});
    res.end(data);
    if (url !== '/health') record(req, status);
  };
  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', req.headers['access-control-request-headers'] || 'content-type');
    return send(204);
  }
  let size = 0;
  req.on('error', () => {});
  req.on('data', chunk => {
    size += chunk.length;
    if (size > 4 * 1024 * 1024) req.destroy();
  });
  req.on('end', () => {
    if (req.method === 'GET' && url === '/health') return send(200, {
      service: 'codex-local-mock-minimal', pid: process.pid, parent_pid: process.ppid, root, mode, initialize});
    if ((req.method === 'POST' && url === '/v1/initialize') || (req.method === 'GET' && url === '/response')) {
      try {
        const result = payload();
        if (req.method === 'POST') initialize++;
        return send(200, result);
      } catch { return send(503, {error: 'Invalid overrides.json'}); }
    }
    if (req.method === 'POST' && ['/v1/sdk_exception', '/v1/rgstr', '/v1/log_event', '/otlp/v1/metrics'].includes(url)) return send(204);
    send(404, {error: 'Initialization mock only'});
  });
});
api.requestTimeout = 15000;
api.headersTimeout = 15000;
function proxyLog(event, details = {}) {
  fs.appendFileSync(file('socks.jsonl'), JSON.stringify({time: new Date().toISOString(), event, ...details}) + '\n');
}
api.on('tlsClientError', error => proxyLog('tls_error', {code: error.code || 'TLS_ERROR'}));

const proxy = net.createServer(client => {
  let buffer = Buffer.alloc(0), stage = 0, upstream;
  const connection = client.remotePort;
  proxyLog('connected', {connection});
  client.setTimeout(15000, () => {
    proxyLog('timeout', {connection, stage});
    client.destroy();
  });
  client.on('error', () => {});
  client.on('close', () => { if (upstream) upstream.destroy(); });
  const reject = (code, reason) => {
    proxyLog('rejected', {connection, code, reason});
    client.removeListener('data', handshake);
    client.end(Buffer.from([5, code, 0, 1, 0, 0, 0, 0, 0, 0]));
  };
  function handshake(chunk) {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length > 65536) return client.destroy();
    if (stage === 0) {
      if (buffer.length < 2) return;
      if (buffer[0] !== 5) {
        proxyLog('rejected', {connection, reason: 'not_socks5'});
        return client.destroy();
      }
      const length = 2 + buffer[1];
      if (buffer.length < length) return;
      if (!buffer.subarray(2, length).includes(0)) {
        proxyLog('rejected', {connection, reason: 'no_authentication_free_method'});
        return client.end(Buffer.from([5, 255]));
      }
      client.write(Buffer.from([5, 0]));
      buffer = buffer.subarray(length);
      stage = 1;
    }
    if (buffer.length < 4) return;
    if (buffer[0] !== 5 || buffer[2] !== 0) return reject(1, 'invalid_request');
    if (buffer[1] !== 1) return reject(7, 'connect_only');
    if (buffer[3] !== 3) return reject(8, 'domain_required_enable_proxy_dns');
    if (buffer.length < 5) return;
    const length = 7 + buffer[4];
    if (buffer.length < length) return;
    const domain = buffer.subarray(5, length - 2).toString('ascii').toLowerCase();
    if (domain !== HOST || buffer.readUInt16BE(length - 2) !== 443) return reject(2, 'target_not_allowed');
    const pending = buffer.subarray(length);
    client.pause();
    client.removeListener('data', handshake);
    upstream = net.connect(TLS_PORT, '127.0.0.1');
    upstream.on('error', error => {
      proxyLog('upstream_error', {connection, code: error.code});
      client.destroy();
    });
    upstream.on('close', () => client.destroy());
    upstream.on('connect', () => {
      if (client.destroyed) return upstream.destroy();
      stage = 2;
      proxyLog('tunnel_ready', {connection});
      client.setTimeout(120000);
      client.write(Buffer.from([5, 0, 0, 1, 127, 0, 0, 1, TLS_PORT >> 8, TLS_PORT & 255]));
      if (pending.length) upstream.write(pending);
      client.pipe(upstream).pipe(client);
      client.resume();
    });
  }
  client.on('data', handshake);
});
function fail(error) {
  fs.appendFileSync(file('server-error.log'), `${new Date().toISOString()} ${error.stack || error}\n`);
  process.exit(1);
}
api.on('error', fail);
proxy.on('error', fail);
api.listen(TLS_PORT, '127.0.0.1', () => {
  const ready = () => fs.writeFileSync(file('server.pid'), String(process.pid));
  if (mode === 's5') proxy.listen(SOCKS_PORT, '127.0.0.1', ready);
  else ready();
});

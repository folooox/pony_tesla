import { request as httpsRequest } from 'node:https';
import { X509Certificate } from 'node:crypto';
import { SafeError, validVin } from './core.mjs';

const integer = (min, max) => v => Number.isInteger(v) && v >= min && v <= max;
const number = (min, max) => v => typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max;
const bool = v => typeof v === 'boolean';
const oneOf = values => v => values.includes(v);
// Intentionally independent of native-commands.mjs (which loads node:sqlite).
// Keep this defensive boundary aligned with that module's official Fleet registry.
const schemas = Object.freeze({
  door_lock: {}, door_unlock: {}, auto_conditioning_start: {}, auto_conditioning_stop: {},
  actuate_trunk: { which_trunk: oneOf(['front', 'rear']) },
  set_sentry_mode: { on: bool }, honk_horn: {}, flash_lights: {},
  window_control: { command: oneOf(['vent', 'close']) },
  charge_port_door_open: {}, charge_port_door_close: {},
  set_charge_limit: { percent: integer(50, 100) }, charge_start: {}, charge_stop: {},
  set_temps: { driver_temp: number(15, 28), passenger_temp: number(15, 28) },
  set_climate_keeper_mode: { climate_keeper_mode: integer(0, 3) },
  set_preconditioning_max: { on: bool },
  remote_seat_heater_request: { heater: oneOf([0, 1]), level: integer(0, 3) },
  remote_steering_wheel_heater_request: { on: bool },
});
export const SIGNED_PROXY_COMMANDS = Object.freeze(Object.keys(schemas));
const MAX_RESPONSE_BYTES = 16 * 1024;
const plain = v => v !== null && typeof v === 'object'
  && [Object.prototype, null].includes(Object.getPrototypeOf(v));
const outcome = (status, cause) => Object.freeze({ status, cause,
  ...(status === 'accepted' ? { result: true } : status === 'rejected' ? { result: false, rejected: true } : {}) });
const invalidConfig = () => { throw new SafeError('Signed proxy configuration invalid', 503); };

function bodyFor(command, params) {
  if (typeof command !== 'string' || !Object.hasOwn(schemas, command) || !plain(params)) return null;
  const schema = schemas[command], keys = Object.keys(schema);
  if (Reflect.ownKeys(params).length !== keys.length) return null;
  const copy = Object.create(null);
  for (const key of keys) {
    // Do not invoke caller getters or serialize arbitrary objects/toJSON functions.
    const field = Object.getOwnPropertyDescriptor(params, key);
    if (!field || !Object.hasOwn(field, 'value') || !schema[key](field.value)) return null;
    copy[key] = field.value;
  }
  return JSON.stringify(copy);
}

/** Trusted server-side construction only; no env defaults or caller tokens. */
export class NativeSignedProxy {
  #config; #accessToken; #request; #setTimer; #clearTimer;
  constructor(config = {}, { accessToken, request = httpsRequest, setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
    const allowed = ['enabled', 'port', 'ca', 'deadlineMs', 'audit'];
    if (!plain(config) || Reflect.ownKeys(config).some(k => !allowed.includes(k))) invalidConfig();
    const { enabled = false, port, ca, deadlineMs = 10_000, audit } = config;
    if (typeof enabled !== 'boolean' || !integer(1, 30_000)(deadlineMs)) invalidConfig();
    // Disabled instances need no live configuration. Enabling always needs ALL evidence.
    if (enabled) {
      if (!integer(1, 65535)(port) || typeof ca !== 'string' || ca.length > 65536
        || !/^-----BEGIN CERTIFICATE-----[\s\S]+-----END CERTIFICATE-----\s*$/.test(ca)
        || !plain(audit) || typeof audit.release !== 'string'
        || !/^[A-Za-z0-9._-]{1,128}$/.test(audit.release)
        || /^(main|master|latest|head)$/i.test(audit.release)
        || !/^sha256:[a-f0-9]{64}$/.test(audit.sourceDigest)
        || audit.officialSourceReviewed !== true || audit.retransmissionPolicyReviewed !== true) invalidConfig();
      try { if (!new X509Certificate(ca).ca) invalidConfig(); } catch { invalidConfig(); }
    }
    if (typeof accessToken !== 'function' || typeof request !== 'function' || typeof setTimer !== 'function' || typeof clearTimer !== 'function') invalidConfig();
    this.#accessToken = accessToken;
    this.#config = Object.freeze({ enabled, port, ca, deadlineMs });
    this.#request = request; this.#setTimer = setTimer; this.#clearTimer = clearTimer;
  }

  /** Account and VIN must already be authorized by the native command service. */
  async sendSigned(account, vin, command, params = {}) {
    if (!this.#config.enabled) return outcome('rejected', 'disabled');
    let body;
    try {
      if (typeof account !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(account)
        || !validVin(vin) || (body = bodyFor(command, params)) === null) return outcome('rejected', 'invalid_request');
    } catch { return outcome('rejected', 'invalid_request'); }
    if (!this.#accessToken) return outcome('rejected', 'token_provider_missing');
    return new Promise(resolve => {
      let settled = false, req, res, timer;
      const destroy = stream => { try { stream?.destroy(); } catch { /* no raw errors */ } };
      const finish = (status, cause, abort = false) => {
        if (settled) return;
        settled = true;
        this.#clearTimer(timer);
        if (abort) { destroy(res); destroy(req); }
        resolve(outcome(status, cause));
      };
      // Wall-clock deadline covers credential lookup, connect, TLS, upload and body.
      timer = this.#setTimer(() => finish('unknown', 'deadline', true), this.#config.deadlineMs);
      Promise.resolve().then(() => this.#accessToken(account)).then(token => {
        if (settled) return;
        if (typeof token !== 'string' || !/^[A-Za-z0-9._~+\/-]{1,16384}={0,2}$/.test(token)) {
          finish('rejected', 'token_unavailable'); return;
        }
        try {
          req = this.#request({
            protocol: 'https:', hostname: '127.0.0.1', family: 4, port: this.#config.port,
            servername: 'localhost', ca: this.#config.ca, rejectUnauthorized: true,
            agent: false, method: 'POST',
            path: `/api/1/vehicles/${vin}/command/${command}`,
            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body),
              Authorization: `Bearer ${token}` },
          }, response => {
            res = response;
            res.on('error', () => finish('unknown', 'response_error', true));
            res.on('aborted', () => finish('unknown', 'response_aborted', true));
            res.on('close', () => { if (!res.complete) finish('unknown', 'response_aborted', true); });
            if (settled) { destroy(res); return; }
            // No redirects, retries, wake-ups, response header/body forwarding or logging.
            if (res.statusCode !== 200) { finish('unknown', 'http_status', true); return; }
            const chunks = []; let bytes = 0;
            res.on('data', chunk => {
              if (settled) return;
              try {
                const part = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
                bytes += part.length;
                if (bytes > MAX_RESPONSE_BYTES) { finish('unknown', 'response_too_large', true); return; }
                chunks.push(part);
              } catch { finish('unknown', 'invalid_response', true); }
            });
            res.on('end', () => {
              if (settled) return;
              try {
                const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
                if (plain(parsed) && plain(parsed.response) && parsed.response.result === true) {
                  finish('accepted', 'proxy_acknowledged');
                } else if (plain(parsed) && plain(parsed.response) && parsed.response.result === false) {
                  // Proxy/SDK may already have retransmitted. A negative final reply
                  // alone does not prove every earlier attempt was rejected.
                  finish('unknown', 'proxy_negative_result');
                } else finish('unknown', 'invalid_response');
              } catch { finish('unknown', 'invalid_response'); }
            });
          });
          req.on('error', () => finish('unknown', 'transport_error', true));
          req.on('timeout', () => finish('unknown', 'deadline', true));
          req.on('abort', () => finish('unknown', 'request_aborted', true));
          req.on('close', () => { if (!res) finish('unknown', 'request_aborted', true); });
          if (settled) destroy(req);
          else req.end(body);
        } catch { finish('unknown', 'transport_error', true); }
      }, () => finish('rejected', 'token_unavailable'));
    });
  }
}

/** Ergonomic factory: construction requires the trusted credential callback. */
export function createNativeSignedProxy(config = {}, { accessToken, ...transport } = {}) {
  if (typeof accessToken !== 'function') invalidConfig();
  return new NativeSignedProxy(config, { accessToken, ...transport });
}

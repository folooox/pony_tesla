import { createPublicKey, verify } from 'node:crypto';

export const RECOVERY_DOMAIN = 'pony.command-owner-quiescence.v1';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
// Incarnations identify runtimes, not PIDs, leases or proof of termination.
export function validatedOwner(value) {
  if (!value || Object.keys(value).sort().join(',') !== 'proxyIncarnation,senderIncarnation'
    || !uuid.test(value.senderIncarnation) || !uuid.test(value.proxyIncarnation)) throw new Error('Invalid dispatch owner');
  return JSON.stringify({ senderIncarnation: value.senderIncarnation, proxyIncarnation: value.proxyIncarnation });
}
export function recoveryTrust(value) {
  if (!value || typeof value.issuer !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(value.issuer)
    || typeof value.keyVersion !== 'string' || !/^[A-Za-z0-9_-]{1,40}$/.test(value.keyVersion)) return null;
  try {
    const publicKey = value.publicKey?.type === 'public' ? value.publicKey : createPublicKey(value.publicKey);
    return publicKey.asymmetricKeyType === 'ed25519' ? { issuer: value.issuer, keyVersion: value.keyVersion, publicKey } : null;
  } catch { return null; }
}
function decode(value, max) {
  if (typeof value !== 'string' || value.length > max || !/^[A-Za-z0-9_-]+$/.test(value)) throw new Error('Invalid receipt');
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.toString('base64url') !== value) throw new Error('Invalid receipt');
  return bytes;
}
// No issuer: only a real supervisor with irreversible admission revocation and
// complete sender/proxy queue/retry/drain termination may possess the signing key.
export function verifyRecoveryReceipt(envelope, challenge, trust, now) {
  try {
    if (!trust || !envelope || Object.keys(envelope).sort().join(',') !== 'payload,signature') return null;
    const bytes = decode(envelope.payload, 8192), signature = decode(envelope.signature, 86);
    if (signature.length !== 64 || !verify(null, bytes, trust.publicKey, signature)) return null;
    const receipt = JSON.parse(bytes.toString('utf8'));
    const expected = { ...challenge, domain: RECOVERY_DOMAIN, issuer: trust.issuer, keyVersion: trust.keyVersion };
    if (Object.keys(receipt).length !== Object.keys(expected).length + 3
      || Object.entries(expected).some(([k, v]) => receipt[k] !== v)) return null;
    const { issuedAt, expiresAt, quiescentAt } = receipt;
    if (![now, issuedAt, expiresAt, quiescentAt].every(Number.isSafeInteger)
      || issuedAt > now || expiresAt <= now || expiresAt <= issuedAt || expiresAt - issuedAt > 30_000
      || quiescentAt < challenge.dispatchedAt || quiescentAt > issuedAt) return null;
    return receipt;
  } catch { return null; }
}

import jwt from 'jsonwebtoken';
import prisma from '../db.js';
import config from '../config.js';

const COOKIE = 'clovyre_session';
const MAX_AGE_DAYS = 30;

export function issueSession(res, user) {
  const token = jwt.sign({ sub: user.id }, config.jwtSecret, {
    expiresIn: `${MAX_AGE_DAYS}d`,
  });

  res.cookie(COOKIE, token, {
    httpOnly: true,
    secure: config.isProd,
    sameSite: config.isProd ? 'none' : 'lax',
    maxAge: MAX_AGE_DAYS * 24 * 60 * 60 * 1000,
    path: '/',
  });
}

export function clearSession(res) {
  res.clearCookie(COOKIE, { path: '/' });
}

function readToken(req) {
  if (req.cookies?.[COOKIE]) return req.cookies[COOKIE];
  const header = req.headers.authorization;
  if (header?.startsWith('Bearer ')) return header.slice(7);
  return null;
}

/** Attaches req.user when a valid session exists; never rejects. */
export async function attachUser(req, _res, next) {
  const token = readToken(req);
  if (!token) return next();

  try {
    const { sub } = jwt.verify(token, config.jwtSecret);
    req.user = await prisma.user.findUnique({ where: { id: sub } });
  } catch {
    // Expired or tampered — treat as signed out.
  }
  next();
}

/** Rejects the request when there is no session. */
export function requireAuth(req, res, next) {
  if (!req.user) return res.status(401).json({ error: 'Not signed in' });
  next();
}

/** Guards the cron endpoints with a shared secret. */
export function requireCronSecret(req, res, next) {
  const provided =
    req.headers['x-cron-secret'] ??
    req.headers.authorization?.replace(/^Bearer /, '');
  if (provided !== config.cronSecret) {
    return res.status(401).json({ error: 'Bad cron secret' });
  }
  next();
}

export default { attachUser, requireAuth, requireCronSecret, issueSession, clearSession };

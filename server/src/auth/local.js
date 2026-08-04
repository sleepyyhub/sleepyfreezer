import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import prisma from '../db.js';
import { issueSession } from '../middleware/auth.js';

/**
 * Email + username + password sign-in.
 *
 * There is no email confirmation step: an address is stored as given and
 * never verified, so treat it as a label rather than proof of anything.
 */

const router = Router();

const PUBLIC_FIELDS = {
  id: true,
  email: true,
  name: true,
  username: true,
  avatarUrl: true,
  nsfwEnabled: true,
  language: true,
  proactiveEnabled: true,
};

// Trim before validating — a pasted address with a trailing space is a typo,
// not an invalid email, and rejecting it reads as a bug to the person typing.
const registerInput = z.object({
  email: z.string().trim().email('Enter a valid email address'),
  username: z
    .string()
    .trim()
    .min(3, 'Username must be at least 3 characters')
    .max(24, 'Username must be at most 24 characters')
    .regex(/^[a-zA-Z0-9_.-]+$/, 'Use only letters, numbers, and _ . -'),
  password: z.string().min(8, 'Password must be at least 8 characters').max(200),
});

const loginInput = z.object({
  // Either an email address or a username.
  identifier: z.string().trim().min(1, 'Enter your email or username'),
  password: z.string().min(1, 'Enter your password'),
});

const firstIssue = (result) => result.error.issues[0]?.message ?? 'Invalid details';

/** POST /api/auth/register */
router.post('/register', async (req, res, next) => {
  try {
    const parsed = registerInput.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: firstIssue(parsed) });

    const email = parsed.data.email.trim().toLowerCase();
    const username = parsed.data.username.trim();

    const clash = await prisma.user.findFirst({
      where: { OR: [{ email }, { username }] },
      select: { email: true, username: true },
    });
    if (clash) {
      return res.status(409).json({
        error: clash.email === email
          ? 'An account with that email already exists'
          : 'That username is taken',
      });
    }

    const user = await prisma.user.create({
      data: {
        email,
        username,
        name: username,
        passwordHash: await bcrypt.hash(parsed.data.password, 10),
      },
      select: PUBLIC_FIELDS,
    });

    issueSession(res, user);
    res.status(201).json({ user });
  } catch (err) {
    next(err);
  }
});

/** POST /api/auth/login */
router.post('/login', async (req, res, next) => {
  try {
    const parsed = loginInput.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: firstIssue(parsed) });

    const identifier = parsed.data.identifier.trim();
    const user = await prisma.user.findFirst({
      where: {
        OR: [{ email: identifier.toLowerCase() }, { username: identifier }],
      },
    });

    // One message for both branches so this cannot be used to enumerate accounts.
    const invalid = () => res.status(401).json({ error: 'Incorrect login details' });
    if (!user?.passwordHash) return invalid();

    const ok = await bcrypt.compare(parsed.data.password, user.passwordHash);
    if (!ok) return invalid();

    issueSession(res, user);
    res.json({
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        username: user.username,
        avatarUrl: user.avatarUrl,
        nsfwEnabled: user.nsfwEnabled,
        language: user.language,
        proactiveEnabled: user.proactiveEnabled,
      },
    });
  } catch (err) {
    next(err);
  }
});

export default router;

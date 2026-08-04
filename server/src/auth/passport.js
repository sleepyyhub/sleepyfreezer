import passport from 'passport';
import { Strategy as GoogleStrategy } from 'passport-google-oauth20';
import { Strategy as DiscordStrategy } from 'passport-discord';
import prisma from '../db.js';
import config from '../config.js';

/**
 * Find or create the user behind an OAuth identity.
 * Accounts are linked by email, so signing in with Discord and later with
 * Google on the same address lands on one user rather than two.
 */
async function upsertUser({ provider, providerAccountId, email, name, avatarUrl }) {
  if (!email) throw new Error(`${provider} returned no email address`);

  const existing = await prisma.account.findUnique({
    where: { provider_providerAccountId: { provider, providerAccountId } },
    include: { user: true },
  });
  if (existing) return existing.user;

  const user = await prisma.user.upsert({
    where: { email },
    update: {
      name: name ?? undefined,
      avatarUrl: avatarUrl ?? undefined,
    },
    create: { email, name, avatarUrl },
  });

  await prisma.account.create({
    data: { userId: user.id, provider, providerAccountId },
  });

  return user;
}

if (config.oauth.google.clientId) {
  passport.use(
    new GoogleStrategy(
      {
        clientID: config.oauth.google.clientId,
        clientSecret: config.oauth.google.clientSecret,
        callbackURL: '/api/auth/google/callback',
        scope: ['profile', 'email'],
      },
      async (_accessToken, _refreshToken, profile, done) => {
        try {
          const user = await upsertUser({
            provider: 'google',
            providerAccountId: profile.id,
            email: profile.emails?.[0]?.value,
            name: profile.displayName,
            avatarUrl: profile.photos?.[0]?.value,
          });
          done(null, user);
        } catch (err) {
          done(err);
        }
      },
    ),
  );
}

if (config.oauth.discord.clientId) {
  passport.use(
    new DiscordStrategy(
      {
        clientID: config.oauth.discord.clientId,
        clientSecret: config.oauth.discord.clientSecret,
        callbackURL: '/api/auth/discord/callback',
        scope: ['identify', 'email'],
      },
      async (_accessToken, _refreshToken, profile, done) => {
        try {
          const avatarUrl = profile.avatar
            ? `https://cdn.discordapp.com/avatars/${profile.id}/${profile.avatar}.png`
            : null;
          const user = await upsertUser({
            provider: 'discord',
            providerAccountId: profile.id,
            email: profile.email,
            name: profile.global_name ?? profile.username,
            avatarUrl,
          });
          done(null, user);
        } catch (err) {
          done(err);
        }
      },
    ),
  );
}

export const enabledProviders = [
  config.oauth.google.clientId && 'google',
  config.oauth.discord.clientId && 'discord',
].filter(Boolean);

export default passport;

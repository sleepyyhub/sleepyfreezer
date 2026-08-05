import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowLeft,
  ArrowRight,
  Bookmark,
  Check,
  ChevronDown,
  Clock3,
  Feather,
  Globe2,
  Image as ImageIcon,
  Info,
  Languages,
  Loader2,
  Lock,
  LogOut,
  Menu,
  MessageCircle,
  PenLine,
  Plus,
  Search,
  Send,
  Settings as SettingsIcon,
  Share2,
  Shield,
  SlidersHorizontal,
  Tag,
  Trash2,
  User,
  UserPlus,
  Users,
  X,
} from 'lucide-react';

import { api } from './lib/api.js';
import {
  adaptCharacter,
  adaptMessage,
  formatRelative,
  gradientFor,
  initialsOf,
  sampleLinesFrom,
} from './lib/adapt.js';
import { SessionProvider, useAsync, useDebounced, useSession } from './lib/hooks.jsx';
import { channels, subscribe } from './lib/realtime.js';
import { useTypewriter } from './lib/typewriter.js';
import { splitRoleplay, stripRoleplay } from './lib/roleplay.js';
import { CloverMark } from './lib/Mark.jsx';

/* ------------------------------------------------------------------ */
/* routing                                                             */
/* ------------------------------------------------------------------ */

// Which modifier to print in the search hint. Reading the platform is the
// only way to avoid showing Mac users Ctrl or Windows users ⌘.
const IS_APPLE = typeof navigator !== 'undefined'
  && /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

function useRoute() {
  const read = () => window.location.hash.replace(/^#\/?/, '') || 'home';
  const [route, setRoute] = useState(read);
  useEffect(() => {
    const onChange = () => setRoute(read());
    window.addEventListener('hashchange', onChange);
    return () => window.removeEventListener('hashchange', onChange);
  }, []);
  const go = (next) => {
    window.location.hash = `/${next}`;
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };
  return [route, go];
}

/* ------------------------------------------------------------------ */
/* primitives                                                          */
/* ------------------------------------------------------------------ */

function Logo({ onClick, compact = false }) {
  return (
    <button className={`brand ${compact ? 'brand-compact' : ''}`} onClick={onClick} aria-label="Clovyre home">
      <span className="brand-mark"><CloverMark size={15} /></span>
      {!compact && <span className="brand-word">clovyre</span>}
    </button>
  );
}

// No presence dot. There was one, hardcoded to green on every character
// everywhere — a status indicator with nothing behind it.
function Avatar({ character, size = 'md', className = '' }) {
  const person = character ?? {};
  const [broken, setBroken] = useState(false);
  const showImage = Boolean(person.imageUrl) && !broken;

  return (
    <span
      className={`avatar avatar-${size} ${showImage ? 'has-image' : ''} ${className}`}
      style={{ '--avatar-a': person.colors?.[0] || '#34d399', '--avatar-b': person.colors?.[1] || '#a3e635' }}
      aria-label={person.name}
    >
      {showImage
        // Falling back to initials on error means a missing image never leaves
        // an empty circle.
        ? <img src={person.imageUrl} alt="" onError={() => setBroken(true)} />
        : <span>{person.initials || initialsOf(person.name)}</span>}
    </span>
  );
}

function UserAvatar({ user, className = 'user-avatar' }) {
  return <span className={className}>{initialsOf(user?.name || user?.email || 'You')}</span>;
}

function Toggle({ checked, onChange, danger = false, label }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      onClick={() => onChange(!checked)}
      className={`toggle ${checked ? 'is-on' : ''} ${danger ? 'toggle-danger' : ''}`}
    >
      <span />
    </button>
  );
}

function NsfwPill({ checked, onChange }) {
  return (
    <button
      className={`nsfw-pill ${checked ? 'is-on' : ''}`}
      type="button"
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
    >
      <span className="nsfw-dot" />
      NSFW
      <span className="mini-switch"><i /></span>
    </button>
  );
}

function Toast({ message, onClose }) {
  useEffect(() => {
    if (!message) return undefined;
    const timer = setTimeout(onClose, 3200);
    return () => clearTimeout(timer);
  }, [message, onClose]);
  if (!message) return null;
  return (
    <div className="toast" role="status">
      <span className="toast-check"><Check size={14} /></span>
      <span>{message}</span>
      <button onClick={onClose} aria-label="Dismiss"><X size={15} /></button>
    </div>
  );
}

function Spinner({ label = 'Loading' }) {
  return (
    <div className="loading-state" role="status">
      <Loader2 size={22} className="spin" />
      <span>{label}</span>
    </div>
  );
}

function ErrorState({ error, onRetry }) {
  return (
    <div className="empty-state">
      <span><Info size={23} /></span>
      <h3>Something went wrong</h3>
      <p>{error?.message ?? 'Please try again.'}</p>
      {onRetry && <button className="secondary-button" onClick={onRetry}>Try again</button>}
    </div>
  );
}

function Modal({ title, onClose, children, footer }) {
  useEffect(() => {
    const onKey = (e) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal-card" role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h3>{title}</h3>
          <button className="icon-button" onClick={onClose} aria-label="Close"><X size={18} /></button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-foot">{footer}</div>}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* sign in                                                             */
/* ------------------------------------------------------------------ */

function SignInPage() {
  const { refresh } = useSession();
  const { data, loading } = useAsync(() => api.auth.providers(), []);
  const providers = data?.providers ?? [];

  // Most people arriving here have no account yet, so opening on "Sign in"
  // sends them into a guaranteed failure whose message reads as a rejected
  // password. Anyone returning has a session cookie and never sees this page.
  const [mode, setMode] = useState('register');
  const [form, setForm] = useState({ identifier: '', email: '', username: '', password: '' });
  const [error, setError] = useState(null);
  const [offerSignUp, setOfferSignUp] = useState(false);
  const [busy, setBusy] = useState(false);

  const set = (key) => (e) => setForm((f) => ({ ...f, [key]: e.target.value }));

  const submit = async (e) => {
    e.preventDefault();
    setError(null);
    setOfferSignUp(false);

    // Checked here rather than with the input's minLength, which makes the
    // browser block submission with a native tooltip and no visible reason.
    if (mode === 'register') {
      if (form.username.trim().length < 3) {
        setError('Username must be at least 3 characters');
        return;
      }
      if (form.password.length < 8) {
        setError('Password must be at least 8 characters');
        return;
      }
    }

    setBusy(true);
    try {
      if (mode === 'login') {
        await api.auth.login(form.identifier, form.password);
      } else {
        await api.auth.register({
          email: form.email,
          username: form.username,
          password: form.password,
        });
      }
      await refresh();
    } catch (err) {
      setError(err.message);
      // The API deliberately cannot say whether the account exists, so offer
      // the other path instead of leaving a dead end.
      setOfferSignUp(mode === 'login');
      setBusy(false);
    }
  };

  const switchTo = (next) => {
    setMode(next);
    setError(null);
    setOfferSignUp(false);
    // Carry what they already typed across, so nothing is retyped.
    setForm((f) => (next === 'register'
      ? { ...f, email: f.email || (f.identifier.includes('@') ? f.identifier : ''),
                username: f.username || (f.identifier.includes('@') ? '' : f.identifier) }
      : { ...f, identifier: f.identifier || f.username || f.email }));
  };

  return (
    <main className="signin-page">
      <div className="ambient ambient-one" />
      <div className="ambient ambient-two" />
      <div className="signin-card">
        <span className="brand-mark signin-mark"><CloverMark size={22} /></span>
        <h1>{mode === 'login' ? 'Welcome back' : 'Welcome to Clovyre'}</h1>
        <p>
          {mode === 'login'
            ? 'Sign in to pick up where you left off.'
            : 'Characters who hold a conversation and remember it afterwards.'}
        </p>

        <div className="segmented-control signin-tabs">
          <button type="button" className={mode === 'login' ? 'active' : ''} onClick={() => switchTo('login')}>Sign in</button>
          <button type="button" className={mode === 'register' ? 'active' : ''} onClick={() => switchTo('register')}>Create account</button>
        </div>

        <form className="signin-form" onSubmit={submit}>
          {mode === 'login' ? (
            <label className="form-field">
              <span>Email or username</span>
              <input
                value={form.identifier}
                onChange={set('identifier')}
                autoComplete="username"
                placeholder="you@example.com"
                required
              />
            </label>
          ) : (
            <>
              <label className="form-field">
                <span>Email</span>
                <input
                  type="email"
                  value={form.email}
                  onChange={set('email')}
                  autoComplete="email"
                  placeholder="you@example.com"
                  required
                />
              </label>
              <label className="form-field">
                <span>Username</span>
                <input
                  value={form.username}
                  onChange={set('username')}
                  autoComplete="username"
                  placeholder="letters, numbers, _ . -"
                  maxLength={24}
                  required
                />
              </label>
            </>
          )}

          <label className="form-field">
            <span>
              Password
              {mode === 'register' && <small>At least 8 characters</small>}
            </span>
            <input
              type="password"
              value={form.password}
              onChange={set('password')}
              autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
              required
            />
          </label>

          {error && (
            <div className="form-error">
              <p>{error}</p>
              {offerSignUp && (
                <button type="button" className="form-error-action" onClick={() => switchTo('register')}>
                  Create an account instead
                </button>
              )}
            </div>
          )}

          <button className="primary-button signin-button" type="submit" disabled={busy}>
            {busy
              ? (mode === 'login' ? 'Signing in…' : 'Creating account…')
              : (mode === 'login' ? 'Sign in' : 'Create account')}
            <ArrowRight size={17} />
          </button>
        </form>

        {!loading && providers.length > 0 && (
          <>
            <div className="signin-divider"><span>or</span></div>
            <div className="signin-actions">
              {providers.includes('google') && (
                <a className="secondary-button signin-button" href={api.auth.signInUrl('google')}>
                  Continue with Google
                </a>
              )}
              {providers.includes('discord') && (
                <a className="secondary-button signin-button" href={api.auth.signInUrl('discord')}>
                  Continue with Discord
                </a>
              )}
            </div>
          </>
        )}

        <span className="signin-note"><Lock size={12} /> Your conversations stay private.</span>
      </div>
    </main>
  );
}

/* ------------------------------------------------------------------ */
/* header                                                              */
/* ------------------------------------------------------------------ */

function AppHeader({ route, go }) {
  const { user } = useSession();
  const nav = [
    { label: 'Explore', to: 'home' },
    { label: 'Chats', to: 'chats' },
    { label: 'Create', to: 'create' },
  ];
  return (
    <header className="site-header">
      <div className="header-inner">
        <Logo onClick={() => go('home')} />
        <nav className="main-nav" aria-label="Primary navigation">
          {nav.map((item) => (
            <button
              key={item.to}
              className={route.startsWith(item.to.split('/')[0]) ? 'active' : ''}
              onClick={() => go(item.to)}
            >
              {item.label}
            </button>
          ))}
        </nav>
        <div className="header-actions">
          <button className="icon-button header-search" onClick={() => go('home')} aria-label="Search"><Search size={18} /></button>
          <button className="user-chip" onClick={() => go('settings')} aria-label="Open settings">
            <UserAvatar user={user} />
            <ChevronDown size={14} />
          </button>
        </div>
      </div>
    </header>
  );
}

/* ------------------------------------------------------------------ */
/* discovery                                                           */
/* ------------------------------------------------------------------ */

function CharacterCard({ character, onOpen, saved, onSave }) {
  return (
    <article
      className="character-card"
      onClick={onOpen}
      tabIndex={0}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') onOpen(); }}
    >
      <div className="card-glow" style={{ '--glow': character.colors[0] }} />
      <div className="card-topline">
        <Avatar character={character} size="lg" />
        {onSave && (
          <button
            className={`save-button ${saved ? 'saved' : ''}`}
            onClick={(e) => { e.stopPropagation(); onSave(character.id); }}
            aria-label={saved ? 'Remove bookmark' : 'Bookmark character'}
          >
            <Bookmark size={17} fill={saved ? 'currentColor' : 'none'} />
          </button>
        )}
      </div>
      <div className="card-title-row">
        <div>
          <h3>{character.name}</h3>
          <p className="role">{character.role}</p>
        </div>
        {character.nsfwAllowed
          ? <span className="small-badge nsfw-badge">18+</span>
          : character.badge && <span className="small-badge">{character.badge}</span>}
      </div>
      <p className="card-description">{character.description}</p>
      <div className="tag-row">
        {character.tags.slice(0, 3).map((tag) => <span className="tag" key={tag}>{tag}</span>)}
      </div>
      <div className="card-footer">
        <span>
          <MessageCircle size={14} />
          {character.messages > 0 ? `${character.chats} messages` : 'No messages yet'}
        </span>
        <span className="open-character">View <ArrowRight size={14} /></span>
      </div>
    </article>
  );
}

const FILTERS = [
  { label: 'Popular', value: 'popular' },
  { label: 'New', value: 'new' },
  { label: 'Saved', value: 'saved' },
  { label: 'Community', value: 'community' },
  { label: 'Mine', value: 'mine' },
];

function HomePage({ go, notify }) {
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState('popular');
  const search = useDebounced(query, 350);
  const searchRef = useRef(null);

  const { data, loading, error, reload, setData } = useAsync(
    () => api.characters.list({ filter, q: search }),
    [filter, search],
  );

  const visible = useMemo(() => (data?.characters ?? []).map(adaptCharacter), [data]);

  // The hint next to the search box promised this; a keyboard shortcut printed
  // on screen and not bound to anything is worse than no hint at all.
  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== 'k' || !(e.metaKey || e.ctrlKey)) return;
      e.preventDefault();
      searchRef.current?.focus();
      searchRef.current?.select();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const toggleSave = async (id) => {
    const wasSaved = data?.characters?.find((c) => c.id === id)?.saved ?? false;

    // Flip first, reconcile after — a bookmark that waits on the network reads
    // as a broken button.
    setData({
      ...data,
      characters: data.characters.map((c) => (c.id === id ? { ...c, saved: !wasSaved } : c)),
    });

    try {
      await api.characters.setSaved(id, !wasSaved);
      // The Saved tab is a filtered list, so unsaving from it must drop the row.
      if (filter === 'saved' && wasSaved) reload();
    } catch (err) {
      notify(err.message);
      reload();
    }
  };

  return (
    <main className="home-page">
      <section className="home-hero page-shell">
        <div className="ambient ambient-one" />
        <div className="ambient ambient-two" />
        <h1>Talk to anyone.<br className="desktop-break" /> They remember.</h1>
        <p>Characters with their own voice, their own opinions, and a memory of
          everything you have told them.</p>
        <div className="hero-search">
          <Search size={20} />
          <input
            ref={searchRef}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search by name, world, or trait"
            aria-label="Search characters"
          />
          {query && <button onClick={() => setQuery('')} aria-label="Clear search"><X size={17} /></button>}
          <kbd>{IS_APPLE ? '⌘' : 'Ctrl'} K</kbd>
        </div>
        <div className="hero-suggestions">
          <span>Try</span>
          {['Quintuplets', 'tsundere', 'shy'].map((item) => (
            <button key={item} onClick={() => setQuery(item)}>{item}</button>
          ))}
        </div>
      </section>

      <section className="discover-section page-shell">
        <div className="section-heading">
          <div>
            <p className="section-kicker">Discover</p>
            <h2>Who do you want to talk to?</h2>
          </div>
          <button className="secondary-button compact" onClick={() => go('create')}><Plus size={16} /> New character</button>
        </div>
        <div className="filter-tabs" role="tablist" aria-label="Character filters">
          {FILTERS.map((item) => (
            <button
              role="tab"
              aria-selected={filter === item.value}
              key={item.value}
              className={filter === item.value ? 'active' : ''}
              onClick={() => setFilter(item.value)}
            >
              {item.label}
            </button>
          ))}
          <span className="result-count">
            {loading ? '…' : `${visible.length} ${visible.length === 1 ? 'character' : 'characters'}`}
          </span>
        </div>

        {loading && <Spinner label="Loading characters" />}
        {error && !loading && <ErrorState error={error} onRetry={reload} />}

        {!loading && !error && (visible.length ? (
          <div className="character-grid">
            {visible.map((character) => (
              <CharacterCard
                key={character.id}
                character={character}
                saved={character.saved}
                onSave={toggleSave}
                onOpen={() => go(`character/${character.id}`)}
              />
            ))}
          </div>
        ) : (
          <div className="empty-state">
            <span>{filter === 'saved' ? <Bookmark size={23} /> : <Search size={23} />}</span>
            {filter === 'saved' && !search ? (
              <>
                <h3>Nothing saved yet</h3>
                <p>The bookmark on a character keeps them here.</p>
                <button className="secondary-button" onClick={() => setFilter('popular')}>Browse characters</button>
              </>
            ) : (
              <>
                <h3>No characters found</h3>
                <p>Try a different name, trait, or world.</p>
                <button className="secondary-button" onClick={() => { setQuery(''); setFilter('popular'); }}>Clear search</button>
              </>
            )}
          </div>
        ))}
      </section>

      {/* No Safety / Guidelines / Privacy links here. There are no such pages,
          and three buttons that go nowhere are worse than an honest footer. */}
      <footer className="site-footer page-shell">
        <Logo onClick={() => window.scrollTo({ top: 0, behavior: 'smooth' })} />
        <p>Built for conversations worth keeping.</p>
        <span>© {new Date().getFullYear()} Clovyre</span>
      </footer>
    </main>
  );
}

/* ------------------------------------------------------------------ */
/* character profile                                                   */
/* ------------------------------------------------------------------ */

/**
 * Character-sheet prose as real paragraphs.
 *
 * These fields are hard-wrapped in the source — the seed file breaks at about
 * seventy characters and models copy that habit. Rendered with the line breaks
 * preserved, the text came out ragged and half the column wide. Blank lines
 * are the only breaks that carry meaning here, so only those become paragraphs.
 */
function Prose({ text = '' }) {
  const paragraphs = text.split(/\n\s*\n/).map((p) => p.replace(/\s*\n\s*/g, ' ').trim()).filter(Boolean);
  return paragraphs.map((paragraph, i) => <p key={i}>{paragraph}</p>);
}

function CharacterProfile({ id, go, notify }) {
  const { data, loading, error, reload, setData } = useAsync(() => api.characters.get(id), [id]);
  const { data: health } = useAsync(() => api.health(), []);
  const { user } = useSession();
  const [starting, setStarting] = useState(false);
  const [groupOpen, setGroupOpen] = useState(false);
  const [drawing, setDrawing] = useState(false);

  const character = data ? adaptCharacter(data.character) : null;
  const saved = Boolean(character?.saved);
  const sampleLines = useMemo(
    () => sampleLinesFrom(character?.speakingStyle ?? ''),
    [character?.speakingStyle],
  );

  const toggleSave = async () => {
    setData({ ...data, character: { ...data.character, saved: !saved } });
    try {
      await api.characters.setSaved(id, !saved);
    } catch (err) {
      notify(err.message);
      reload();
    }
  };
  const canDraw = Boolean(health?.images)
    && (!data?.character?.creatorId || data.character.creatorId === user?.id);

  const drawAvatar = async () => {
    setDrawing(true);
    try {
      const res = await api.characters.generateAvatar(id, Boolean(character?.imageUrl));
      notify(
        res.provider === 'openrouter'
          ? 'Portrait drawn — that one used paid credit.'
          : 'Portrait drawn.',
      );
      reload();
    } catch (err) {
      notify(err.message);
    } finally {
      setDrawing(false);
    }
  };

  const startChat = async () => {
    setStarting(true);
    try {
      const { conversation } = await api.conversations.open(character.id);
      go(`chat/${conversation.id}`);
    } catch (err) {
      notify(err.message);
      setStarting(false);
    }
  };

  if (loading) return <main className="profile-page page-shell"><Spinner label="Loading character" /></main>;
  if (error) return <main className="profile-page page-shell"><ErrorState error={error} onRetry={reload} /></main>;

  return (
    <main className="profile-page page-shell">
      <button className="back-link" onClick={() => go('home')}><ArrowLeft size={16} /> Back to explore</button>
      <section className="profile-hero">
        <div className="profile-aura" style={{ '--profile-color': character.colors[0] }} />
        <div className="profile-avatar-wrap">
          <Avatar character={character} size="xl" />
          {canDraw && (
            <button className="draw-avatar" onClick={drawAvatar} disabled={drawing}>
              {drawing
                ? <><Loader2 size={13} className="spin" /> Drawing…</>
                : <><ImageIcon size={13} /> {character.imageUrl ? 'Redraw' : 'Draw portrait'}</>}
            </button>
          )}
        </div>
        <div className="profile-main-info">
          <div className="profile-name-line">
            <div>
              <div className="creator-line">
                <span>AI character</span><i />
                {character.creator ? `by ${character.creator.name ?? 'a member'}` : 'official'}
              </div>
              <h1>{character.name}</h1>
              <p className="profile-role">{character.role}</p>
            </div>
            <button
              className={`icon-button profile-save ${saved ? 'active' : ''}`}
              onClick={toggleSave}
              aria-label={saved ? 'Remove bookmark' : 'Bookmark character'}
            ><Bookmark size={19} fill={saved ? 'currentColor' : 'none'} /></button>
            <button
              className="icon-button"
              onClick={() => { navigator.clipboard?.writeText(window.location.href); notify('Link copied'); }}
              aria-label="Copy link"
            ><Share2 size={19} /></button>
          </div>
          <p className="profile-description">{character.description}</p>
          <div className="tag-row profile-tags">
            {character.tags.map((tag) => <span className="tag" key={tag}>{tag}</span>)}
            {character.nsfwAllowed && <span className="tag tag-nsfw">18+</span>}
          </div>
          {/* One real number. There were three here — a fabricated follower
              count and a tag tally — which existed to fill the row. */}
          {character.messages > 0 && (
            <p className="profile-usage">
              {character.chats} messages exchanged so far
            </p>
          )}
          <div className="profile-actions">
            <button className="primary-button" onClick={startChat} disabled={starting}>
              <MessageCircle size={18} /> {starting ? 'Opening…' : 'Start chat'} <ArrowRight size={17} />
            </button>
            <button className="secondary-button" onClick={() => setGroupOpen(true)}>
              <UserPlus size={18} /> Add to group
            </button>
          </div>
        </div>
      </section>

      <section className="profile-content-grid">
        <div className="profile-about">
          <div className="content-block">
            <p className="section-kicker">About</p>
            <h2>Who they are</h2>
            <Prose text={character.personality} />
          </div>
          {character.lore && (
            <div className="content-block">
              <p className="section-kicker">Background</p>
              <h2>Their world</h2>
              <Prose text={character.lore} />
            </div>
          )}
          <div className="content-block detail-list">
            <div><span><Tag size={16} /> Traits</span><p>{character.tags.join(' · ') || 'Not set'}</p></div>
            <div><span><Globe2 size={16} /> Universe</span><p>{character.role}</p></div>
            {character.createdAt && (
              <div>
                <span><Clock3 size={16} /> Added</span>
                <p>{new Date(character.createdAt).toLocaleDateString([], { day: 'numeric', month: 'long', year: 'numeric' })}</p>
              </div>
            )}
          </div>
        </div>
        {/* This aside used to explain the product's inner-thoughts feature on
            every character's page. Their own sample lines are more use: it is
            the closest thing to hearing them before you start. */}
        <aside className="preview-panel">
          <div className="preview-heading">
            <div><h3>How they talk</h3></div>
          </div>
          {sampleLines.length ? (
            <ul className="sample-lines">
              {sampleLines.map((line) => <li key={line}>{line}</li>)}
            </ul>
          ) : (
            <p className="sample-lines-empty">
              No sample lines written for {character.name} yet.
            </p>
          )}
          <button className="preview-cta" onClick={startChat} disabled={starting}>
            {starting ? 'Opening…' : 'Start chatting'} <ArrowRight size={16} />
          </button>
        </aside>
      </section>

      {groupOpen && (
        <GroupModal
          preselect={character}
          onClose={() => setGroupOpen(false)}
          onCreated={(group) => { setGroupOpen(false); go(`group/${group.id}`); }}
          notify={notify}
        />
      )}
    </main>
  );
}

/* ------------------------------------------------------------------ */
/* group creation                                                      */
/* ------------------------------------------------------------------ */

function GroupModal({ preselect, onClose, onCreated, notify }) {
  const [name, setName] = useState(preselect ? `${preselect.name} & co.` : 'New group');
  const [picked, setPicked] = useState(() => new Set(preselect ? [preselect.id] : []));
  const [saving, setSaving] = useState(false);
  const { data, loading } = useAsync(() => api.characters.list({ filter: 'popular' }), []);
  const options = useMemo(() => (data?.characters ?? []).map(adaptCharacter), [data]);

  const toggle = (id) => setPicked((current) => {
    const next = new Set(current);
    if (next.has(id)) next.delete(id); else next.add(id);
    return next;
  });

  const submit = async () => {
    if (picked.size < 2) { notify('Pick at least two characters'); return; }
    setSaving(true);
    try {
      const { group } = await api.groups.create(name.trim() || 'New group', [...picked]);
      onCreated(group);
    } catch (err) {
      notify(err.message);
      setSaving(false);
    }
  };

  return (
    <Modal
      title="Create a group"
      onClose={onClose}
      footer={
        <>
          <span className="modal-hint">{picked.size} selected · minimum 2</span>
          <button className="secondary-button" onClick={onClose}>Cancel</button>
          <button className="primary-button small-primary" onClick={submit} disabled={saving || picked.size < 2}>
            {saving ? 'Creating…' : 'Create group'}
          </button>
        </>
      }
    >
      <label className="form-field">
        <span>Group name</span>
        <input value={name} onChange={(e) => setName(e.target.value)} maxLength={60} placeholder="e.g. The Nakano sisters" />
      </label>
      <p className="modal-label">Characters</p>
      {loading ? <Spinner label="Loading characters" /> : (
        <div className="picker-grid">
          {options.map((c) => (
            <button
              key={c.id}
              type="button"
              className={`picker-item ${picked.has(c.id) ? 'active' : ''}`}
              onClick={() => toggle(c.id)}
            >
              <Avatar character={c} size="sm" />
              <span><strong>{c.name}</strong><small>{c.role}</small></span>
              {picked.has(c.id) && <Check size={16} />}
            </button>
          ))}
        </div>
      )}
    </Modal>
  );
}

/* ------------------------------------------------------------------ */
/* chat shell                                                          */
/* ------------------------------------------------------------------ */

function ChatSidebar({ go, active, mobileOpen, onClose, conversations, groups, onNewGroup, reload }) {
  const { user } = useSession();
  const [search, setSearch] = useState('');
  const filtered = conversations.filter((c) =>
    !search || c.character.name.toLowerCase().includes(search.toLowerCase()));

  const removeConversation = async (e, id) => {
    e.stopPropagation();
    try { await api.conversations.remove(id); reload(); } catch { /* already gone */ }
  };

  return (
    <aside className={`chat-sidebar ${mobileOpen ? 'mobile-open' : ''}`}>
      <div className="sidebar-brand-row">
        <Logo onClick={() => go('home')} />
        <button className="mobile-close" onClick={onClose} aria-label="Close conversations"><X size={19} /></button>
      </div>
      <button className="new-chat-button" onClick={() => go('home')}><Plus size={17} /> New conversation</button>
      <div className="sidebar-search">
        <Search size={15} />
        <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search chats" />
      </div>

      <div className="conversation-label"><span>Recent</span></div>
      <div className="conversation-list">
        {filtered.length === 0 && <p className="sidebar-empty">No conversations yet.</p>}
        {filtered.map((item) => {
          const character = adaptCharacter(item.character);
          return (
            <button
              key={item.id}
              className={active === item.id ? 'active' : ''}
              onClick={() => { go(`chat/${item.id}`); onClose?.(); }}
            >
              <Avatar character={character} size="sm" />
              <span className="conversation-copy">
                <span><strong>{character.name}</strong><time>{formatRelative(item.lastMessageAt)}</time></span>
                <small>{stripRoleplay(item.lastMessage?.content ?? '').slice(0, 42) || 'Say hello'}</small>
              </span>
              <i
                className="row-delete"
                onClick={(e) => removeConversation(e, item.id)}
                title={`Delete chat with ${character.name}`}
              ><Trash2 size={13} /></i>
            </button>
          );
        })}
      </div>

      <div className="conversation-label group-label">
        <span>Groups</span>
        <button onClick={onNewGroup} aria-label="New group"><Plus size={15} /></button>
      </div>
      {groups.length === 0 && <p className="sidebar-empty">No groups yet.</p>}
      {groups.map((group) => (
        <button
          key={group.id}
          className={`group-conversation ${active === group.id ? 'active' : ''}`}
          onClick={() => { go(`group/${group.id}`); onClose?.(); }}
        >
          <span className="stacked-avatars small-stack">
            {group.members.slice(0, 3).map((m) => <Avatar key={m.id} character={adaptCharacter(m)} size="xs" />)}
          </span>
          <span>
            <strong>{group.name}</strong>
            <small>
              {stripRoleplay(group.lastMessage?.content ?? '').slice(0, 30)
                || `${group.members.length} characters`}
            </small>
          </span>
          <time>{formatRelative(group.lastMessageAt)}</time>
        </button>
      ))}

      <div className="sidebar-user">
        <UserAvatar user={user} />
        {/* Said "Free plan" — there are no plans, paid or otherwise. */}
        <span><strong>{user?.name ?? 'You'}</strong><small>{user?.email}</small></span>
        <button onClick={() => go('settings')} aria-label="Settings"><SettingsIcon size={17} /></button>
      </div>
    </aside>
  );
}

/** Renders speech as-is and roleplay action in its own style, markers removed. */
function RoleplayText({ text }) {
  const segments = useMemo(() => splitRoleplay(text), [text]);
  return segments.map((seg, i) => (
    seg.type === 'action'
      // Index keys are safe here: the list is regenerated wholesale from the
      // text on every change and never reordered.
      // eslint-disable-next-line react/no-array-index-key
      ? <em className="rp-action" key={i}>{seg.value}</em>
      // eslint-disable-next-line react/no-array-index-key
      : <span key={i}>{seg.value}</span>
  ));
}

function ChatMessage({ message, animate = false, onTick }) {
  // Only messages that arrive while you are watching get typed out; history
  // loaded from the server appears at once, as already-read text should.
  const { shown, done } = useTypewriter(message.text, { enabled: animate });

  useEffect(() => { onTick?.(); }, [shown, onTick]);

  if (message.speaker === 'user') {
    return (
      <div className="message-row user-message">
        <div>
          <p className="preserve-lines"><RoleplayText text={message.text} /></p>
          <time>{message.time}</time>
        </div>
      </div>
    );
  }

  const character = message.character ?? {};
  return (
    <div className="message-row character-message">
      <Avatar character={character} size="sm" />
      <div className="message-content">
        <span className="message-author">
          {character.name}
          <time>{message.time}</time>
          {message.isProactive && <em className="proactive-tag">reached out</em>}
        </span>
        {message.thought && (
          <div className="thought-bubble">
            <span>INNER THOUGHT</span>
            <em><RoleplayText text={message.thought} /></em>
          </div>
        )}
        {(shown || !message.sceneUrl) && (
          <div className="message-bubble">
            <p className="preserve-lines">
              <RoleplayText text={shown} />
              {!done && <span className="type-caret" aria-hidden="true" />}
            </p>
          </div>
        )}
        {message.sceneUrl && (
          // Held back until the line has finished typing, so the picture lands
          // as a reveal rather than spoiling what is still being said.
          <figure className={`scene ${done ? 'scene-in' : 'scene-pending'}`}>
            <img src={message.sceneUrl} alt={message.sceneCaption ?? 'Scene'} loading="lazy" />
          </figure>
        )}
      </div>
    </div>
  );
}

function ChatComposer({ nsfw, setNsfw, onSend, placeholder, typing, typingLabel }) {
  const [text, setText] = useState('');
  const submit = () => {
    if (!text.trim() || typing) return;
    onSend(text.trim());
    setText('');
  };
  return (
    <div className="composer-wrap">
      {typing && <div className="typing-line"><span /><span /><span /> {typingLabel}</div>}
      <div className="composer">
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(); }
          }}
          rows={1}
          placeholder={placeholder}
        />
        <div className="composer-bottom">
          {/* Attach, image, and microphone buttons lived here and did nothing.
              There is no upload endpoint and no speech input. */}
          <div className="composer-tools">
            <NsfwPill checked={nsfw} onChange={setNsfw} />
          </div>
          <div className="send-area">
            <span>↵ to send</span>
            <button className="send-button" disabled={!text.trim() || typing} onClick={submit} aria-label="Send message"><Send size={17} /></button>
          </div>
        </div>
      </div>
      <p className="chat-disclaimer">Characters can make things up. Keep personal information private.</p>
    </div>
  );
}

/** Shared data for every chat surface: the sidebar's two lists. */
function useChatShell() {
  const conversations = useAsync(() => api.conversations.list(), []);
  const groups = useAsync(() => api.groups.list(), []);
  const reloadConversations = conversations.reload;
  const reloadGroups = groups.reload;
  const reload = useCallback(() => {
    reloadConversations();
    reloadGroups();
  }, [reloadConversations, reloadGroups]);

  return {
    conversations: conversations.data?.conversations ?? [],
    groups: groups.data?.groups ?? [],
    reload,
  };
}

/**
 * Track which messages landed while the reader was watching. Only those get
 * typed out — reopening a conversation should not replay it.
 */
function useLiveMessages() {
  const [liveIds, setLiveIds] = useState(() => new Set());
  const markLive = useCallback((...ids) => {
    setLiveIds((current) => {
      const next = new Set(current);
      for (const id of ids.flat()) if (id) next.add(id);
      return next;
    });
  }, []);
  return { liveIds, markLive };
}

/** Merge incoming rows into state without ever duplicating an id. */
function mergeMessages(current, rows) {
  const next = [...current];
  for (const row of rows) {
    if (!next.some((m) => m.id === row.id)) next.push(adaptMessage(row));
  }
  return next;
}

/* ------------------------------------------------------------------ */
/* 1-on-1 chat                                                         */
/* ------------------------------------------------------------------ */

function ChatPage({ id, go, nsfw, setNsfw, notify }) {
  const shell = useChatShell();
  const { liveIds, markLive } = useLiveMessages();
  const [messages, setMessages] = useState([]);
  const [character, setCharacter] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [typing, setTyping] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [groupOpen, setGroupOpen] = useState(false);
  const endRef = useRef(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    api.conversations.messages(id)
      .then(({ conversation, messages: rows }) => {
        if (!live) return;
        setCharacter(adaptCharacter(conversation.character));
        setMessages(rows.map(adaptMessage));
        setLoading(false);
      })
      .catch((err) => { if (live) { setError(err); setLoading(false); } });
    return () => { live = false; };
  }, [id]);

  const scrollToEnd = useCallback(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  }, []);
  useEffect(() => { scrollToEnd(); }, [messages, typing, scrollToEnd]);

  // Proactive messages, and anything sent from another tab, arrive here.
  useEffect(() => subscribe(channels.conversation(id), {
    message: (row) => {
      markLive(row.id);
      setMessages((current) => mergeMessages(current, [row]));
    },
  }), [id, markLive]);

  const send = async (text) => {
    const tempId = `tmp-${Date.now()}`;
    setMessages((current) => [...current, { id: tempId, speaker: 'user', text, time: 'now' }]);
    setTyping(true);
    try {
      const { userMessage, characterMessage } = await api.conversations.send(id, text);
      markLive(characterMessage?.id);
      setMessages((current) =>
        mergeMessages(current.filter((m) => m.id !== tempId), [userMessage, characterMessage]));
      shell.reload();
    } catch (err) {
      setMessages((current) => current.filter((m) => m.id !== tempId));
      notify(err.message);
    } finally {
      setTyping(false);
    }
  };

  return (
    <main className="chat-layout">
      {sidebarOpen && <button className="drawer-overlay" onClick={() => setSidebarOpen(false)} aria-label="Close menu" />}
      <ChatSidebar
        go={go} active={id} mobileOpen={sidebarOpen} onClose={() => setSidebarOpen(false)}
        conversations={shell.conversations} groups={shell.groups}
        onNewGroup={() => setGroupOpen(true)} reload={shell.reload}
      />
      <section className="chat-main">
        <header className="chat-header">
          <div className="chat-title">
            <button className="mobile-menu" onClick={() => setSidebarOpen(true)} aria-label="Open conversations"><Menu size={20} /></button>
            <Avatar character={character ?? {}} size="sm" />
            {/* Was "Online · Remembers your story", with a green presence dot.
                A character is never offline, so the dot said nothing. */}
            <span><strong>{character?.name ?? 'Loading…'}</strong><small>{character?.role}</small></span>
          </div>
          <div className="chat-header-actions">
            <button className="secondary-button compact group-add" onClick={() => setGroupOpen(true)}><Users size={15} /> Add to group</button>
            <button
              className="icon-button"
              onClick={() => character && go(`character/${character.id}`)}
              aria-label="Conversation info"
            ><Info size={18} /></button>
          </div>
        </header>
        <div className="messages-scroll">
          {loading && <Spinner label="Loading conversation" />}
          {error && <ErrorState error={error} />}
          {!loading && !error && (
            <>
              <div className="conversation-start">
                <Avatar character={character ?? {}} size="lg" />
                <h2>{character?.name}</h2>
                <p>{character?.description}</p>
                <span><Lock size={12} /> This conversation is private</span>
              </div>
              <div className="messages-list">
                {messages.map((message) => (
                  <ChatMessage
                    key={message.id}
                    message={message}
                    animate={liveIds.has(message.id)}
                    onTick={scrollToEnd}
                  />
                ))}
                <div ref={endRef} />
              </div>
            </>
          )}
        </div>
        <ChatComposer
          nsfw={nsfw} setNsfw={setNsfw} onSend={send} typing={typing}
          typingLabel={`${character?.name ?? 'Character'} is thinking`}
          placeholder={`Message ${character?.name ?? '...'}`}
        />
      </section>

      {groupOpen && (
        <GroupModal
          preselect={character}
          onClose={() => setGroupOpen(false)}
          onCreated={(group) => { setGroupOpen(false); shell.reload(); go(`group/${group.id}`); }}
          notify={notify}
        />
      )}
    </main>
  );
}

/* ------------------------------------------------------------------ */
/* group chat                                                          */
/* ------------------------------------------------------------------ */

function MemberPanel({ group, open, onClose, onChanged, notify }) {
  const { user } = useSession();
  const members = (group?.members ?? []).map(adaptCharacter);

  const remove = async (characterId) => {
    try {
      await api.groups.removeMember(group.id, characterId);
      notify('Removed from group');
      onChanged();
    } catch (err) { notify(err.message); }
  };

  return (
    <aside className={`member-panel ${open ? 'mobile-open' : ''}`}>
      <div className="member-panel-head"><h3>Group details</h3><button onClick={onClose}><X size={18} /></button></div>
      <div className="group-visual">
        <span className="stacked-avatars">
          {members.slice(0, 4).map((member) => <Avatar key={member.id} character={member} size="md" />)}
        </span>
        <h3>{group?.name}</h3>
        <p>{members.length} characters</p>
      </div>
      <div className="member-section-head"><span>Characters · {members.length}</span></div>
      <div className="member-list">
        {members.map((member) => (
          <div key={member.id}>
            <Avatar character={member} size="sm" />
            <span><strong>{member.name}</strong><small>{member.role}</small></span>
            {members.length > 2 && (
              <button onClick={() => remove(member.id)} aria-label={`Remove ${member.name}`}><X size={15} /></button>
            )}
          </div>
        ))}
      </div>
      <div className="member-section-head"><span>You</span></div>
      <div className="member-list">
        <div>
          <UserAvatar user={user} />
          <span><strong>{user?.name ?? 'You'}</strong><small>{user?.email}</small></span>
          <em>Owner</em>
        </div>
      </div>
    </aside>
  );
}

function GroupChatPage({ id, go, nsfw, setNsfw, notify }) {
  const shell = useChatShell();
  const { liveIds, markLive } = useLiveMessages();
  const [group, setGroup] = useState(null);
  const [messages, setMessages] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [typing, setTyping] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [membersOpen, setMembersOpen] = useState(false);
  const [groupOpen, setGroupOpen] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);
  const endRef = useRef(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    api.groups.messages(id)
      .then(({ group: g, messages: rows }) => {
        if (!live) return;
        setGroup(g);
        setMessages(rows.map(adaptMessage));
        setLoading(false);
      })
      .catch((err) => { if (live) { setError(err); setLoading(false); } });
    return () => { live = false; };
  }, [id, reloadKey]);

  const scrollToEnd = useCallback(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  }, []);
  useEffect(() => { scrollToEnd(); }, [messages, typing, scrollToEnd]);

  // Characters replying to one another stream in one at a time.
  useEffect(() => subscribe(channels.group(id), {
    message: (row) => {
      markLive(row.id);
      setMessages((current) => mergeMessages(current, [row]));
    },
  }), [id, markLive]);

  const send = async (text) => {
    const tempId = `tmp-${Date.now()}`;
    setMessages((current) => [...current, { id: tempId, speaker: 'user', text, time: 'now' }]);
    setTyping(true);
    try {
      const { userMessage, replies } = await api.groups.send(id, text);
      markLive(replies.map((r) => r.id));
      setMessages((current) =>
        mergeMessages(current.filter((m) => m.id !== tempId), [userMessage, ...replies]));
      shell.reload();
    } catch (err) {
      setMessages((current) => current.filter((m) => m.id !== tempId));
      notify(err.message);
    } finally {
      setTyping(false);
    }
  };

  const members = (group?.members ?? []).map(adaptCharacter);

  return (
    <main className="chat-layout group-layout">
      {(sidebarOpen || membersOpen) && (
        <button
          className="drawer-overlay"
          onClick={() => { setSidebarOpen(false); setMembersOpen(false); }}
          aria-label="Close panel"
        />
      )}
      <ChatSidebar
        go={go} active={id} mobileOpen={sidebarOpen} onClose={() => setSidebarOpen(false)}
        conversations={shell.conversations} groups={shell.groups}
        onNewGroup={() => setGroupOpen(true)} reload={shell.reload}
      />
      <section className="chat-main">
        <header className="chat-header">
          <div className="chat-title">
            <button className="mobile-menu" onClick={() => setSidebarOpen(true)} aria-label="Open conversations"><Menu size={20} /></button>
            <span className="stacked-avatars header-stack">
              {members.slice(0, 3).map((member) => <Avatar key={member.id} character={member} size="xs" />)}
            </span>
            <span><strong>{group?.name ?? 'Loading…'}</strong><small>{members.length} characters · 1 human</small></span>
          </div>
          <div className="chat-header-actions">
            <button className="icon-button mobile-members" onClick={() => setMembersOpen(true)} aria-label="View members"><Users size={18} /></button>
          </div>
        </header>
        <div className="messages-scroll">
          {loading && <Spinner label="Loading group" />}
          {error && <ErrorState error={error} />}
          {!loading && !error && (
            <>
              <div className="conversation-start group-start">
                <span className="stacked-avatars large-stack">
                  {members.slice(0, 4).map((member) => <Avatar key={member.id} character={member} size="lg" />)}
                </span>
                <h2>{group?.name}</h2>
                <p>{members.map((m) => m.name).join(', ')}, and you</p>
                <span><Users size={12} /> They talk to each other, not just to you</span>
              </div>
              <div className="messages-list">
                {messages.map((message) => (
                  <ChatMessage
                    key={message.id}
                    message={message}
                    animate={liveIds.has(message.id)}
                    onTick={scrollToEnd}
                  />
                ))}
                <div ref={endRef} />
              </div>
            </>
          )}
        </div>
        <ChatComposer
          nsfw={nsfw} setNsfw={setNsfw} onSend={send} typing={typing}
          typingLabel="The group is talking" placeholder="Message the group..."
        />
      </section>
      <MemberPanel
        group={group} open={membersOpen} onClose={() => setMembersOpen(false)}
        onChanged={() => setReloadKey((k) => k + 1)} notify={notify}
      />

      {groupOpen && (
        <GroupModal
          onClose={() => setGroupOpen(false)}
          onCreated={(g) => { setGroupOpen(false); shell.reload(); go(`group/${g.id}`); }}
          notify={notify}
        />
      )}
    </main>
  );
}

/** Landing spot for the "Chats" nav item, before a thread is chosen. */
function ChatsIndex({ go, notify }) {
  const shell = useChatShell();
  const [groupOpen, setGroupOpen] = useState(false);

  return (
    <main className="chat-layout">
      <ChatSidebar
        go={go} active={null} mobileOpen={false} onClose={() => {}}
        conversations={shell.conversations} groups={shell.groups}
        onNewGroup={() => setGroupOpen(true)} reload={shell.reload}
      />
      <section className="chat-main">
        <div className="empty-state chat-empty">
          <span><MessageCircle size={23} /></span>
          <h3>No conversation open</h3>
          <p>Pick a chat on the left, or find someone new to talk to.</p>
          <button className="primary-button" onClick={() => go('home')}>Explore characters <ArrowRight size={16} /></button>
        </div>
      </section>
      {groupOpen && (
        <GroupModal
          onClose={() => setGroupOpen(false)}
          onCreated={(g) => { setGroupOpen(false); shell.reload(); go(`group/${g.id}`); }}
          notify={notify}
        />
      )}
    </main>
  );
}

/* ------------------------------------------------------------------ */
/* create                                                              */
/* ------------------------------------------------------------------ */

function Field({ label, hint, children, required }) {
  return (
    <label className="form-field">
      <span>{label}{required && <em>*</em>}{hint && <small>{hint}</small>}</span>
      {children}
    </label>
  );
}

const COLOR_OPTIONS = ['#34d399', '#38bdf8', '#a3e635', '#fbbf24', '#f472b6', '#c084fc'];

function CreatePage({ go, notify }) {
  const [draft, setDraft] = useState({
    name: '',
    universe: '',
    tagline: '',
    personality: '',
    lore: '',
    speakingStyle: '',
    tags: '',
    nsfwAllowed: false,
    isPublic: true,
    color: 0,
  });
  const [saving, setSaving] = useState(false);
  const [seed, setSeed] = useState({ name: '', universe: '' });
  const [composing, setComposing] = useState(false);
  const [composeNote, setComposeNote] = useState(null);
  const update = (key, value) => setDraft((current) => ({ ...current, [key]: value }));

  const tags = draft.tags.split(',').map((t) => t.trim()).filter(Boolean).slice(0, 10);

  const compose = async () => {
    if (!seed.name.trim()) { notify('Enter a character name first'); return; }
    setComposing(true);
    setComposeNote(null);
    try {
      const { draft: sheet } = await api.characters.compose(seed.name, seed.universe);
      const colorIndex = COLOR_OPTIONS.indexOf(sheet.themeColor);
      setDraft((current) => ({
        ...current,
        name: sheet.name,
        universe: sheet.universe,
        tagline: sheet.tagline,
        personality: sheet.personality,
        lore: sheet.lore,
        speakingStyle: sheet.speakingStyle,
        tags: sheet.tags.join(', '),
        color: colorIndex >= 0 ? colorIndex : current.color,
      }));
      if (sheet.incomplete?.length) {
        setComposeNote({
          kind: 'warn',
          text: `The model ran out of room and left ${sheet.incomplete.join(' and ')} blank. `
            + 'Fill those in, or press Draft it again for a fresh attempt.',
        });
      } else if (!sheet.known) {
        setComposeNote({
          kind: 'warn',
          text: `The model did not recognise ${sheet.name}, so this is invented rather than recalled. Worth checking closely.`,
        });
      } else {
        setComposeNote({
          kind: 'ok',
          text: `Drafted ${sheet.name}. Read it over and change anything that feels off.`,
        });
      }
    } catch (err) {
      setComposeNote({ kind: 'error', text: err.message });
    } finally {
      setComposing(false);
    }
  };

  const previewCharacter = {
    id: 'preview',
    name: draft.name || 'Untitled character',
    initials: initialsOf(draft.name || 'AI'),
    role: draft.universe || 'Original character',
    description: draft.tagline || 'Your tagline will appear here.',
    tags,
    messages: 0,
    chats: '0',
    badge: null,
    colors: gradientFor(COLOR_OPTIONS[draft.color]),
    nsfwAllowed: draft.nsfwAllowed,
  };

  const filled = [draft.name, draft.tagline, draft.personality, draft.lore, draft.speakingStyle].filter(Boolean).length;
  const canSubmit = draft.name.trim().length > 0 && draft.personality.trim().length >= 20;

  const submit = async () => {
    if (!canSubmit) { notify('A name and at least 20 characters of personality are required'); return; }
    setSaving(true);
    try {
      const { character } = await api.characters.create({
        name: draft.name.trim(),
        universe: draft.universe.trim() || 'Original',
        tagline: draft.tagline.trim(),
        personality: draft.personality.trim(),
        lore: draft.lore.trim(),
        speakingStyle: draft.speakingStyle.trim(),
        tags,
        themeColor: COLOR_OPTIONS[draft.color],
        nsfwAllowed: draft.nsfwAllowed,
        isPublic: draft.isPublic,
      });
      notify(`${character.name} created`);
      go(`character/${character.id}`);
    } catch (err) {
      notify(err.message);
      setSaving(false);
    }
  };

  return (
    <main className="create-page page-shell">
      <div className="create-title-row">
        <div>
          <button className="back-link" onClick={() => go('home')}><ArrowLeft size={16} /> Back to explore</button>
          <h1>New character</h1>
          <p>A name and a few paragraphs of personality is enough to start.</p>
        </div>
        <div className="create-top-actions">
          <button className="primary-button" onClick={submit} disabled={saving || !canSubmit}>
            <Check size={17} /> {saving ? 'Creating…' : 'Create character'}
          </button>
        </div>
      </div>
      <div className="create-grid">
        <div className="create-form">
          <section className="form-section compose-section">
            <div className="form-section-title">
              <span className="compose-badge"><PenLine size={15} /></span>
              <div>
                <h2>Start from a name</h2>
                <p>Name a character and where they are from, and the rest of this form gets filled in for you.</p>
              </div>
            </div>
            <div className="compose-row">
              <input
                value={seed.name}
                onChange={(e) => setSeed((s) => ({ ...s, name: e.target.value }))}
                onKeyDown={(e) => e.key === 'Enter' && !composing && compose()}
                placeholder="Character name, e.g. Miku Nakano"
                maxLength={60}
                aria-label="Character name"
              />
              <input
                value={seed.universe}
                onChange={(e) => setSeed((s) => ({ ...s, universe: e.target.value }))}
                onKeyDown={(e) => e.key === 'Enter' && !composing && compose()}
                placeholder="Anime or universe (optional)"
                maxLength={80}
                aria-label="Universe"
              />
              <button className="primary-button compose-button" onClick={compose} disabled={composing}>
                {composing ? <><Loader2 size={16} className="spin" /> Writing…</> : <><Feather size={16} /> Draft it</>}
              </button>
            </div>
            {composeNote && (
              <p className={`compose-note compose-note-${composeNote.kind}`}>
                {composeNote.kind === 'warn' ? <Info size={14} /> : <Check size={14} />}
                {composeNote.text}
              </p>
            )}
          </section>

          <section className="form-section">
            <div className="form-section-title"><span>01</span><div><h2>Identity</h2><p>The essentials people see first.</p></div></div>
            <div className="form-fields">
              <Field label="Character name" required>
                <input value={draft.name} maxLength={60} onChange={(e) => update('name', e.target.value)} placeholder="e.g. Nino Nakano" />
              </Field>
              <Field label="Universe" hint="Where they're from. Leave blank for an original character.">
                <input value={draft.universe} maxLength={80} onChange={(e) => update('universe', e.target.value)} placeholder="e.g. The Quintessential Quintuplets" />
              </Field>
              <Field label="Tagline" hint="One line that captures who they are">
                <input value={draft.tagline} maxLength={140} onChange={(e) => update('tagline', e.target.value)} placeholder="e.g. Sharp-tongued, hard to win over" />
              </Field>
              <Field label="Tags" hint="Separate with commas">
                <input value={draft.tags} onChange={(e) => update('tags', e.target.value)} placeholder="tsundere, protective, blunt" />
              </Field>
            </div>
          </section>

          <section className="form-section">
            <div className="form-section-title">
              <span>02</span>
              <div><h2>Personality &amp; voice</h2><p>This is what the model actually reads. The more specific, the more convincing.</p></div>
            </div>
            <div className="form-fields">
              <Field label="Personality" hint="Their temperament, contradictions, what they care about" required>
                <textarea
                  rows={7}
                  value={draft.personality}
                  onChange={(e) => update('personality', e.target.value)}
                  placeholder="Blunt and hot-tempered, says exactly what she thinks. Everything she does comes from protecting her sisters. Easily flustered by anything sincere, and covers it by getting louder..."
                />
              </Field>
              <Field label="Background" hint="Their history, relationships, the events they can reference">
                <textarea
                  rows={6}
                  value={draft.lore}
                  onChange={(e) => update('lore', e.target.value)}
                  placeholder="One of five identical sisters. Their mother died when they were young..."
                />
              </Field>
              <Field label="Speaking style" hint="Sentence rhythm, verbal tics, and two or three sample lines">
                <textarea
                  rows={6}
                  value={draft.speakingStyle}
                  onChange={(e) => update('speakingStyle', e.target.value)}
                  placeholder={'Speaks fast and direct, in short sentences. Interrupts.\n\nSample lines:\n"Hah? Say that again."\n"...Don\'t get the wrong idea."'}
                />
              </Field>
              <button
                className="magic-suggest"
                onClick={() => {
                  update('speakingStyle', `${draft.speakingStyle}\n\nSample lines:\n"..."\n"..."`.trim());
                  notify('Sample-line template added');
                }}
              ><Plus size={16} /> Add sample-line template</button>
            </div>
          </section>

          <section className="form-section">
            <div className="form-section-title"><span>03</span><div><h2>Appearance &amp; access</h2><p>Finish the details and choose who can chat.</p></div></div>
            <div className="form-fields">
              <Field label="Theme colour">
                <div className="color-picker">
                  {COLOR_OPTIONS.map((color, index) => (
                    <button
                      type="button"
                      key={color}
                      onClick={() => update('color', index)}
                      className={draft.color === index ? 'active' : ''}
                      // The swatch used to blend into the *next* option's
                      // colour, so it showed a gradient the card never used.
                      style={{ background: `linear-gradient(135deg, ${gradientFor(color).join(', ')})` }}
                      aria-label={`Colour option ${index + 1}`}
                    >{draft.color === index && <Check size={16} />}</button>
                  ))}
                </div>
              </Field>
              <Field label="Visibility">
                <div className="segmented-control">
                  {[['Public', true], ['Private', false]].map(([label, value]) => (
                    <button
                      type="button"
                      className={draft.isPublic === value ? 'active' : ''}
                      onClick={() => update('isPublic', value)}
                      key={label}
                    >{label}</button>
                  ))}
                </div>
              </Field>
              <div className="form-toggle-row">
                <div>
                  <span><Shield size={17} /> Mature content</span>
                  <p>Character may take part in adult conversations. Only visible to users who have enabled it.</p>
                </div>
                <Toggle checked={draft.nsfwAllowed} onChange={(value) => update('nsfwAllowed', value)} danger label="Allow mature content" />
              </div>
            </div>
          </section>
          <div className="mobile-create-actions">
            <button className="primary-button" onClick={submit} disabled={saving || !canSubmit}>
              <Check size={17} /> {saving ? 'Creating…' : 'Create character'}
            </button>
          </div>
        </div>

        <aside className="live-preview">
          {/* Was a percentage bar over five fields, which only ever reads
              20/40/60/80/100 — a counter wearing a progress bar. */}
          <div className="live-preview-head">
            <div>Preview</div>
            <span>{filled} of 5 written</span>
          </div>
          <CharacterCard character={previewCharacter} onOpen={() => {}} />
          <div className="preview-note">
            <Info size={15} />
            <p>Personality, background, and speaking style go straight into the model. Sample lines matter more than adjectives.</p>
          </div>
        </aside>
      </div>
    </main>
  );
}

/* ------------------------------------------------------------------ */
/* settings                                                            */
/* ------------------------------------------------------------------ */

function SettingsNav({ active, setActive, onSignOut }) {
  const sections = [
    { id: 'account', label: 'Account', icon: User },
    { id: 'conversations', label: 'Conversations', icon: SlidersHorizontal },
    { id: 'content', label: 'Mature content', icon: Shield },
  ];
  const jump = (id) => {
    setActive(id);
    document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };
  return (
    <aside className="settings-nav">
      <span>Settings</span>
      {sections.map(({ id, label, icon: Icon }) => (
        <button key={id} className={active === id ? 'active' : ''} onClick={() => jump(id)}><Icon size={17} />{label}</button>
      ))}
      <div className="settings-nav-divider" />
      <button className="sign-out" onClick={onSignOut}><LogOut size={17} /> Sign out</button>
    </aside>
  );
}

function SettingsRow({ icon: Icon, title, description, children }) {
  return (
    <div className="settings-row">
      {Icon && <span className="settings-row-icon"><Icon size={17} /></span>}
      <div className="settings-row-copy"><strong>{title}</strong>{description && <p>{description}</p>}</div>
      <div className="settings-row-control">{children}</div>
    </div>
  );
}

const LANGUAGES = [
  ['auto', 'Match what I write in'],
  ['English', 'English'],
  ['Deutsch', 'Deutsch'],
  ['Türkçe', 'Türkçe'],
  ['Español', 'Español'],
  ['日本語', '日本語'],
];

/**
 * Confirming an irreversible action by typing the account name back.
 *
 * A plain "are you sure" is one stray click from gone. Typing something is the
 * usual bar, and it is also the only proof available for an account that
 * signed in through Google and has no password stored here.
 */
function DeleteAccountModal({ user, onClose, notify }) {
  const [typed, setTyped] = useState('');
  const [working, setWorking] = useState(false);
  const handle = user?.username ?? user?.email ?? '';
  const matches = typed.trim().toLowerCase() === handle.toLowerCase();

  const confirm = async () => {
    setWorking(true);
    try {
      await api.settings.deleteAccount(typed.trim());
      // Nothing is left to show, so drop back to a signed-out home rather than
      // leaving a dead session on screen.
      window.location.hash = '';
      window.location.reload();
    } catch (err) {
      notify(err.message);
      setWorking(false);
    }
  };

  return (
    <Modal
      title="Delete account"
      onClose={onClose}
      footer={(
        <>
          <button className="secondary-button" onClick={onClose}>Keep my account</button>
          <button className="danger-button" onClick={confirm} disabled={!matches || working}>
            {working ? 'Deleting…' : 'Delete permanently'}
          </button>
        </>
      )}
    >
      <p className="modal-lede">
        This removes your conversations, groups, and everything characters
        remember about you. Characters you published stay up, but without your
        name on them.
      </p>
      <Field label={`Type ${handle} to confirm`}>
        <input
          value={typed}
          onChange={(e) => setTyped(e.target.value)}
          autoFocus
          autoComplete="off"
          spellCheck="false"
        />
      </Field>
    </Modal>
  );
}

function SettingsPage({ go, notify }) {
  const { user, updateSettings, signOut } = useSession();
  const [active, setActive] = useState('account');
  const [name, setName] = useState(user?.name ?? '');
  const [saving, setSaving] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  const save = async (patch, message) => {
    try {
      await updateSettings(patch);
      if (message) notify(message);
    } catch (err) { notify(err.message); }
  };

  const saveAccount = async () => {
    setSaving(true);
    await save({ name: name.trim() }, 'Saved');
    setSaving(false);
  };

  return (
    <main className="settings-page page-shell">
      <button className="back-link" onClick={() => go('home')}><ArrowLeft size={16} /> Back to Clovyre</button>
      <div className="settings-title">
        <h1>Settings</h1>
      </div>
      <div className="settings-layout">
        <SettingsNav active={active} setActive={setActive} onSignOut={signOut} />
        <div className="settings-content">
          <section className="settings-section" id="account">
            <div className="settings-section-head"><div><h2>Account</h2></div></div>
            <div className="account-profile-row">
              <UserAvatar user={user} className="settings-avatar" />
              <div>
                <strong>{user?.name || user?.username || 'You'}</strong>
                <p>
                  {user?.avatarUrl
                    ? 'Your picture comes from the account you signed in with.'
                    : 'Characters see your display name. Nothing else about you is shared.'}
                </p>
              </div>
            </div>
            <div className="account-fields">
              <Field label="Display name"><input value={name} onChange={(e) => setName(e.target.value)} maxLength={60} /></Field>
              {user?.username && (
                <Field label="Username" hint="Fixed once chosen"><input value={user.username} disabled /></Field>
              )}
              <Field label="Email address" hint="Used to sign in"><input type="email" value={user?.email ?? ''} disabled /></Field>
            </div>
            <div className="section-save">
              <button className="primary-button small-primary" onClick={saveAccount} disabled={saving || name.trim() === (user?.name ?? '')}>
                {saving ? 'Saving…' : 'Save changes'}
              </button>
            </div>
          </section>

          <section className="settings-section" id="conversations">
            <div className="settings-section-head"><div><h2>Conversations</h2></div></div>
            <SettingsRow icon={Languages} title="Reply language" description="Characters mirror whatever you write in unless you pin one.">
              <div className="select-wrap settings-select">
                <select value={user?.language ?? 'auto'} onChange={(e) => save({ language: e.target.value }, 'Language updated')}>
                  {LANGUAGES.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
                </select>
                <ChevronDown size={15} />
              </div>
            </SettingsRow>
            <SettingsRow
              icon={MessageCircle}
              title="Let characters message me first"
              description="They reach out on their own after a few quiet hours."
            >
              <Toggle
                checked={Boolean(user?.proactiveEnabled)}
                onChange={(v) => save({ proactiveEnabled: v }, v ? 'Characters can reach out' : 'Characters will stay quiet')}
                label="Proactive messages"
              />
            </SettingsRow>
            <SettingsRow
              icon={ImageIcon}
              title="Let characters illustrate scenes"
              description="A character can draw the moment instead of describing it. Each picture costs a real image generation, so this is off by default and limited to one every 20 messages."
            >
              <Toggle
                checked={Boolean(user?.sceneImagesEnabled)}
                onChange={(v) => save({ sceneImagesEnabled: v }, v ? 'Characters can illustrate scenes' : 'Scene images off')}
                label="Scene images"
              />
            </SettingsRow>
          </section>

          <section className="settings-section" id="content">
            <div className="settings-section-head"><div><h2>Mature content</h2></div></div>
            <div className={`mature-setting ${user?.nsfwEnabled ? 'enabled' : ''}`}>
              <span className="mature-icon"><Shield size={19} /></span>
              <div>
                <strong>Allow NSFW conversations</strong>
                <p>
                  Unlocks characters marked 18+, who are hidden entirely while
                  this is off. Applies everywhere, in every conversation.
                </p>
              </div>
              <NsfwPill
                checked={Boolean(user?.nsfwEnabled)}
                onChange={(v) => save({ nsfwEnabled: v }, v ? 'Mature content enabled' : 'Mature content disabled')}
              />
            </div>
          </section>

          <section className="settings-section danger-section">
            <div className="settings-section-head"><div><h2>Delete account</h2></div></div>
            <SettingsRow
              icon={Trash2}
              title="Delete this account"
              description="Removes your conversations, groups, and everything characters remember about you. Characters you published stay up without your name."
            >
              <button className="danger-button" onClick={() => setConfirmDelete(true)}>Delete account</button>
            </SettingsRow>
          </section>
        </div>
      </div>

      {confirmDelete && (
        <DeleteAccountModal user={user} notify={notify} onClose={() => setConfirmDelete(false)} />
      )}
    </main>
  );
}

/* ------------------------------------------------------------------ */
/* app                                                                 */
/* ------------------------------------------------------------------ */

function Shell() {
  const [route, go] = useRoute();
  const [toast, setToast] = useState('');
  const { user, loading, updateSettings } = useSession();
  const notify = useCallback((message) => setToast(message), []);

  // The NSFW pill in the composer writes straight through to the account.
  const nsfw = Boolean(user?.nsfwEnabled);
  const setNsfw = useCallback(async (value) => {
    try {
      await updateSettings({ nsfwEnabled: value });
      notify(value ? 'Mature content enabled' : 'Mature content disabled');
    } catch (err) { notify(err.message); }
  }, [updateSettings, notify]);

  // A character reaching out while you are elsewhere in the app.
  const userId = user?.id;
  useEffect(() => {
    if (!userId) return undefined;
    return subscribe(channels.user(userId), {
      proactive: (payload) => notify(`${payload.character?.name ?? 'Someone'} messaged you`),
    });
  }, [userId, notify]);

  if (loading) {
    return <div className="app boot-screen"><Spinner label="Loading Clovyre" /></div>;
  }
  if (!user) return <div className="app"><SignInPage /></div>;

  const isChat = route.startsWith('chat') || route.startsWith('group');
  const chatProps = { go, nsfw, setNsfw, notify };

  let page;
  if (route === 'home') page = <HomePage go={go} notify={notify} />;
  else if (route.startsWith('character/')) page = <CharacterProfile key={route} id={route.split('/')[1]} go={go} notify={notify} />;
  else if (route.startsWith('chat/')) page = <ChatPage key={route} id={route.split('/')[1]} {...chatProps} />;
  else if (route === 'chats') page = <ChatsIndex go={go} notify={notify} />;
  else if (route.startsWith('group/')) page = <GroupChatPage key={route} id={route.split('/')[1]} {...chatProps} />;
  else if (route === 'create') page = <CreatePage go={go} notify={notify} />;
  else if (route === 'settings') page = <SettingsPage go={go} notify={notify} />;
  else page = <HomePage go={go} notify={notify} />;

  return (
    <div className="app">
      {!isChat && <AppHeader route={route} go={go} />}
      {page}
      <Toast message={toast} onClose={() => setToast('')} />
    </div>
  );
}

export default function App() {
  return (
    <SessionProvider>
      <Shell />
    </SessionProvider>
  );
}

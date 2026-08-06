/*
 * mathlang.js — tiny, safe math-expression language for the arena.
 *
 * Agents never send us code. They send expressions in this mini-language,
 * which we tokenize, parse into an AST and evaluate ourselves. There is no
 * eval(), no Function() constructor, and no way to reach a global.
 *
 * Grammar (lowest to highest precedence):
 *   expr    := term (('+' | '-') term)*
 *   term    := unary (('*' | '/' | '%') unary)*
 *   unary   := ('-' | '+') unary | power
 *   power   := primary ('^' unary)?          // right associative
 *   primary := number | ident | ident '(' args ')' | '(' expr ')'
 */

const CONSTANTS = {
  pi: Math.PI,
  tau: Math.PI * 2,
  e: Math.E,
  phi: (1 + Math.sqrt(5)) / 2,
};

const FUNCTIONS = {
  sin: Math.sin,
  cos: Math.cos,
  tan: Math.tan,
  asin: Math.asin,
  acos: Math.acos,
  atan: Math.atan,
  atan2: Math.atan2,
  sinh: Math.sinh,
  cosh: Math.cosh,
  tanh: Math.tanh,
  abs: Math.abs,
  sqrt: (x) => Math.sqrt(Math.abs(x)),
  cbrt: Math.cbrt,
  exp: Math.exp,
  log: (x) => Math.log(Math.abs(x) + 1e-9),
  floor: Math.floor,
  ceil: Math.ceil,
  round: Math.round,
  sign: Math.sign,
  min: Math.min,
  max: Math.max,
  hypot: Math.hypot,
  pow: Math.pow,
  mod: (a, b) => (b === 0 ? 0 : a - b * Math.floor(a / b)),
  clamp: (x, lo, hi) => Math.min(Math.max(x, lo), hi),
  lerp: (a, b, u) => a + (b - a) * u,
  // Smooth pulse centred on `c` with width `w` — handy for shield lobes.
  bump: (x, c, w) => Math.exp(-((x - c) * (x - c)) / (2 * (w || 1) * (w || 1))),
  // Triangle wave in [-1, 1], period 1.
  tri: (x) => 2 * Math.abs(2 * (x - Math.floor(x + 0.5))) - 1,
  // Square wave in [-1, 1], period 1.
  sqr: (x) => (x - Math.floor(x) < 0.5 ? 1 : -1),
  step: (edge, x) => (x < edge ? 0 : 1),
  smoothstep: (a, b, x) => {
    if (a === b) return x < a ? 0 : 1;
    const u = Math.min(Math.max((x - a) / (b - a), 0), 1);
    return u * u * (3 - 2 * u);
  },
};

const FUNCTION_NAMES = Object.keys(FUNCTIONS);
const CONSTANT_NAMES = Object.keys(CONSTANTS);

const MAX_SOURCE_LENGTH = 400;
const MAX_NODES = 300;

class MathLangError extends Error {}

function tokenize(src) {
  const tokens = [];
  let i = 0;
  while (i < src.length) {
    const ch = src[i];
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
      i++;
      continue;
    }
    if (ch >= '0' && ch <= '9') {
      let j = i;
      while (j < src.length && /[0-9]/.test(src[j])) j++;
      if (src[j] === '.') {
        j++;
        while (j < src.length && /[0-9]/.test(src[j])) j++;
      }
      if (src[j] === 'e' || src[j] === 'E') {
        let k = j + 1;
        if (src[k] === '+' || src[k] === '-') k++;
        if (/[0-9]/.test(src[k] || '')) {
          k++;
          while (k < src.length && /[0-9]/.test(src[k])) k++;
          j = k;
        }
      }
      tokens.push({ type: 'num', value: parseFloat(src.slice(i, j)) });
      i = j;
      continue;
    }
    if (ch === '.' && /[0-9]/.test(src[i + 1] || '')) {
      let j = i + 1;
      while (j < src.length && /[0-9]/.test(src[j])) j++;
      tokens.push({ type: 'num', value: parseFloat(src.slice(i, j)) });
      i = j;
      continue;
    }
    if (/[A-Za-z_]/.test(ch)) {
      let j = i;
      while (j < src.length && /[A-Za-z0-9_]/.test(src[j])) j++;
      tokens.push({ type: 'ident', value: src.slice(i, j).toLowerCase() });
      i = j;
      continue;
    }
    if ('+-*/%^(),'.includes(ch)) {
      tokens.push({ type: ch });
      i++;
      continue;
    }
    throw new MathLangError(`unexpected character "${ch}"`);
  }
  tokens.push({ type: 'eof' });
  return tokens;
}

function parse(tokens) {
  let pos = 0;
  let nodeCount = 0;

  const peek = () => tokens[pos];
  const next = () => tokens[pos++];
  const expect = (type) => {
    if (tokens[pos].type !== type) {
      throw new MathLangError(`expected "${type}" but found "${tokens[pos].type}"`);
    }
    return tokens[pos++];
  };
  const node = (n) => {
    if (++nodeCount > MAX_NODES) throw new MathLangError('expression is too complex');
    return n;
  };

  function parseExpr() {
    let left = parseTerm();
    while (peek().type === '+' || peek().type === '-') {
      const op = next().type;
      left = node({ kind: 'bin', op, left, right: parseTerm() });
    }
    return left;
  }

  function parseTerm() {
    let left = parseUnary();
    while (peek().type === '*' || peek().type === '/' || peek().type === '%') {
      const op = next().type;
      left = node({ kind: 'bin', op, left, right: parseUnary() });
    }
    return left;
  }

  function parseUnary() {
    if (peek().type === '-') {
      next();
      return node({ kind: 'neg', operand: parseUnary() });
    }
    if (peek().type === '+') {
      next();
      return parseUnary();
    }
    return parsePower();
  }

  function parsePower() {
    const base = parsePrimary();
    if (peek().type === '^') {
      next();
      return node({ kind: 'bin', op: '^', left: base, right: parseUnary() });
    }
    return base;
  }

  function parsePrimary() {
    const token = next();
    if (token.type === 'num') return node({ kind: 'num', value: token.value });
    if (token.type === '(') {
      const inner = parseExpr();
      expect(')');
      return inner;
    }
    if (token.type === 'ident') {
      if (peek().type === '(') {
        next();
        const args = [];
        if (peek().type !== ')') {
          args.push(parseExpr());
          while (peek().type === ',') {
            next();
            args.push(parseExpr());
          }
        }
        expect(')');
        if (!FUNCTIONS[token.value]) {
          throw new MathLangError(`unknown function "${token.value}"`);
        }
        return node({ kind: 'call', name: token.value, args });
      }
      if (CONSTANTS[token.value] !== undefined) {
        return node({ kind: 'num', value: CONSTANTS[token.value] });
      }
      return node({ kind: 'var', name: token.value });
    }
    throw new MathLangError(`unexpected token "${token.type}"`);
  }

  const ast = parseExpr();
  expect('eof');
  return ast;
}

function evaluate(ast, scope) {
  switch (ast.kind) {
    case 'num':
      return ast.value;
    case 'var': {
      const value = scope[ast.name];
      return typeof value === 'number' ? value : 0;
    }
    case 'neg':
      return -evaluate(ast.operand, scope);
    case 'call': {
      const args = ast.args.map((arg) => evaluate(arg, scope));
      return FUNCTIONS[ast.name](...args);
    }
    case 'bin': {
      const a = evaluate(ast.left, scope);
      const b = evaluate(ast.right, scope);
      switch (ast.op) {
        case '+': return a + b;
        case '-': return a - b;
        case '*': return a * b;
        case '/': return Math.abs(b) < 1e-9 ? 0 : a / b;
        case '%': return Math.abs(b) < 1e-9 ? 0 : a % b;
        case '^': {
          const r = Math.pow(a, b);
          return Number.isFinite(r) ? r : 0;
        }
        default: return 0;
      }
    }
    default:
      return 0;
  }
}

/**
 * Compile an expression string into `(scope) => number`.
 * The returned function never throws and never returns NaN/Infinity —
 * a misbehaving expression degrades to `fallback` instead of killing the frame.
 */
export function compileExpression(source, { allowedVars = [], fallback = 0 } = {}) {
  if (typeof source === 'number' && Number.isFinite(source)) {
    const constant = () => source;
    constant.source = String(source);
    constant.isConstant = true;
    return constant;
  }
  const text = String(source == null ? '' : source).trim();
  if (!text) throw new MathLangError('empty expression');
  if (text.length > MAX_SOURCE_LENGTH) {
    throw new MathLangError(`expression exceeds ${MAX_SOURCE_LENGTH} characters`);
  }

  const ast = parse(tokenize(text));

  if (allowedVars.length) {
    const allowed = new Set(allowedVars);
    const walk = (n) => {
      if (n.kind === 'var' && !allowed.has(n.name)) {
        throw new MathLangError(
          `unknown variable "${n.name}" (allowed: ${allowedVars.join(', ')})`,
        );
      }
      if (n.kind === 'bin') { walk(n.left); walk(n.right); }
      if (n.kind === 'neg') walk(n.operand);
      if (n.kind === 'call') n.args.forEach(walk);
    };
    walk(ast);
  }

  const fn = (scope) => {
    let value;
    try {
      value = evaluate(ast, scope);
    } catch {
      return fallback;
    }
    return Number.isFinite(value) ? value : fallback;
  };
  fn.source = text;
  fn.isConstant = !dependsOnVariable(ast);
  return fn;
}

function dependsOnVariable(n) {
  if (n.kind === 'var') return true;
  if (n.kind === 'bin') return dependsOnVariable(n.left) || dependsOnVariable(n.right);
  if (n.kind === 'neg') return dependsOnVariable(n.operand);
  if (n.kind === 'call') return n.args.some(dependsOnVariable);
  return false;
}

export { MathLangError, FUNCTION_NAMES, CONSTANT_NAMES };

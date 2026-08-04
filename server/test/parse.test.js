import { parseReply, parseJson } from '../src/ai/parse.js';

const cases = [
  {
    name: 'standard thought line',
    raw: '*Nino thinks: why is he asking me that, of all things.*\nHah? Say that again.',
    expect: { thought: 'why is he asking me that, of all things.', content: 'Hah? Say that again.' },
  },
  {
    name: 'think tag',
    raw: '<think>She is testing me.</think>\nFine. I heard you.',
    expect: { thought: 'She is testing me.', content: 'Fine. I heard you.' },
  },
  {
    name: 'speaker label stripped',
    raw: '*Miku thinks: um...*\nMiku: ...it\'s nothing. Really.',
    name_: 'Miku',
    expect: { thought: 'um...', content: "...it's nothing. Really." },
  },
  {
    name: 'reasoning_content fallback',
    raw: 'Ahh, don\'t worry about it!',
    reasoning: 'He looks tired. I should keep it light.',
    expect: { thought: 'He looks tired. I should keep it light.', content: "Ahh, don't worry about it!" },
  },
  {
    name: 'no thought at all',
    raw: 'Just a plain reply.',
    expect: { thought: null, content: 'Just a plain reply.' },
  },
  {
    name: 'unclosed think tag (token cutoff)',
    raw: '<think>I was about to say something but ran out of',
    expect: { thought: 'I was about to say something but ran out of', content: '' },
  },
  {
    name: 'multiline thought',
    raw: '*Itsuki thinks: honestly.\nEvery single time.*\nDo you ever think before you speak?',
    expect: { thought: 'honestly. Every single time.', content: 'Do you ever think before you speak?' },
  },
];

let pass = 0, fail = 0;
for (const c of cases) {
  const got = parseReply(c.raw, { reasoning: c.reasoning ?? null, name: c.name_ ?? '' });
  const ok = got.thought === c.expect.thought && got.content === c.expect.content;
  if (ok) { pass++; console.log(`  PASS  ${c.name}`); }
  else {
    fail++;
    console.log(`  FAIL  ${c.name}`);
    console.log(`        want thought=${JSON.stringify(c.expect.thought)} content=${JSON.stringify(c.expect.content)}`);
    console.log(`        got  thought=${JSON.stringify(got.thought)} content=${JSON.stringify(got.content)}`);
  }
}

const jsonCases = [
  ['```json\n["Nino", "Miku"]\n```', ['Nino', 'Miku']],
  ['Sure! ["Yotsuba"]', ['Yotsuba']],
  ['["Ichika"]', ['Ichika']],
  ['no json here', null],
];
for (const [raw, want] of jsonCases) {
  const got = parseJson(raw, null);
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (ok) { pass++; console.log(`  PASS  json: ${raw.slice(0, 30)}`); }
  else { fail++; console.log(`  FAIL  json: ${raw} -> ${JSON.stringify(got)} want ${JSON.stringify(want)}`); }
}

console.log(`\n${pass} passed, ${fail} failed`);

// --- regression cases captured from real free-model output ---
const real = [
  {
    name: 'stray mid-message thought (ling, German)',
    raw: 'Ah... hallo. Mein Tag... war okay.\n\n*Miku Nakano thinks: I cannot explain it simply.*\n\nUm... ich habe Hausaufgaben gemacht.',
    name_: 'Miku Nakano',
    check: (g) => !g.content.includes('thinks:') && g.content.includes('Mein Tag') && g.content.includes('Hausaufgaben'),
  },
  {
    name: 'leaked planning prose (nemotron)',
    raw: 'We need to respond as Nino Nakano, with inner monologue line first, then spoken response.\n\n*Nino thinks: he noticed.*\nHah? Say that again.',
    name_: 'Nino Nakano',
    check: (g) => !g.content.startsWith('We need to') && g.content.includes('Hah?'),
  },
  {
    name: 'planning prose with nothing after it is kept, not blanked',
    raw: 'We need to respond as Nino.',
    name_: 'Nino Nakano',
    check: (g) => g.content.length > 0,
  },
  {
    name: 'whole reply arrives in reasoning with empty content (ling)',
    raw: '',
    reasoning: "*Nino Nakano thinks: he's been quiet for a while.* Fine. Since nobody's going to say anything, I'll say it. The stand closed last week.",
    name_: 'Nino Nakano',
    check: (g) => g.thought === "he's been quiet for a while."
                && g.content.startsWith('Fine.')
                && !g.content.includes('thinks:'),
  },
  {
    name: 'reasoning with no thought marker still becomes the thought',
    raw: 'Hah? Say that again.',
    reasoning: 'She is testing me and I do not like it.',
    name_: 'Nino Nakano',
    check: (g) => g.thought === 'She is testing me and I do not like it.'
                && g.content === 'Hah? Say that again.',
  },
];

// --- truncated JSON, the shape a reasoning model produces when the token
// --- budget runs out partway through the object ---
console.log('\n--- truncated json repair ---');
const truncated = [
  {
    name: 'cut mid-string in the last field',
    raw: '{"known": true, "tagline": "Loyal to a fault", "personality": "She begins cold and suspic',
    check: (g) => g && g.known === true && g.tagline === 'Loyal to a fault',
  },
  {
    name: 'cut mid-array',
    raw: '{"tagline": "x", "tags": ["loyal", "dev',
    check: (g) => g && g.tagline === 'x',
  },
  {
    name: 'complete json is untouched',
    raw: '{"a": 1, "b": "two"}',
    check: (g) => g && g.a === 1 && g.b === 'two',
  },
  {
    name: 'a string containing a brace does not confuse the repair',
    raw: '{"a": "has { and } inside", "b": "cut off here',
    check: (g) => g && g.a === 'has { and } inside',
  },
  {
    name: 'nothing complete yet returns the fallback',
    raw: '{"personality": "only this one and it is cut',
    check: (g) => g === null,
  },
];
for (const c of truncated) {
  const got = parseJson(c.raw, null);
  if (c.check(got)) { pass++; console.log(`  PASS  ${c.name}`); }
  else { fail++; console.log(`  FAIL  ${c.name} -> ${JSON.stringify(got)}`); }
}

console.log('\n--- regression cases ---');
let rp = 0, rf = 0;
for (const c of real) {
  const got = parseReply(c.raw, { reasoning: c.reasoning ?? null, name: c.name_ });
  if (c.check(got)) { rp++; console.log(`  PASS  ${c.name}`); }
  else { rf++; console.log(`  FAIL  ${c.name}\n        thought=${JSON.stringify(got.thought)}\n        content=${JSON.stringify(got.content)}`); }
}
console.log(`\nregression: ${rp} passed, ${rf} failed`);
process.exit(rf ? 1 : 0);

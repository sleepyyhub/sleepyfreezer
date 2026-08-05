import { sampleLinesFrom } from '../src/lib/adapt.js';

/**
 * The character page shows a character's own sample lines. Pulling them out of
 * the speaking-style field is fiddly: the field is prose that also quotes
 * things inline, and the first version of this happily served up `you` and
 * `idiot` as Nino's representative dialogue.
 */

let pass = 0;
let fail = 0;

const check = (name, input, expected) => {
  const got = JSON.stringify(sampleLinesFrom(input));
  const want = JSON.stringify(expected);
  if (got === want) { pass += 1; console.log(`  PASS  ${name}`); }
  else {
    fail += 1;
    console.log(`  FAIL  ${name}`);
    console.log(`        want ${want}`);
    console.log(`        got  ${got}`);
  }
};

console.log('--- sample lines ---');

check(
  'quoted lines are picked up',
  'Speaks fast.\n\nSample lines:\n"Hah? Say that again."\n"...Don\'t get the wrong idea."',
  ['Hah? Say that again.', "...Don't get the wrong idea."],
);

check(
  'inline quotes in the prose are not sample lines',
  'She calls him "idiot" constantly and says "you" like an accusation.\n"Whatever."',
  ['Whatever.'],
);

check(
  'curly quotes work too',
  '“I am not — ugh. Forget it.”',
  ['I am not — ugh. Forget it.'],
);

check(
  'bulleted lines are accepted',
  '- "Do what you want."\n• "Fine."',
  ['Do what you want.', 'Fine.'],
);

check(
  'duplicates are collapsed',
  '"Same line."\n"Same line."\n"Another."',
  ['Same line.', 'Another.'],
);

check('at most three', '"One."\n"Two."\n"Three."\n"Four."', ['One.', 'Two.', 'Three.']);

check('very short quotes are ignored', '"ok"\n"a"', []);

check('prose with no sample lines yields nothing', 'Speaks fast and direct. Interrupts.', []);

check('empty input', '', []);

check('undefined input', undefined, []);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);

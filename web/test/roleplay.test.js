import { splitRoleplay, stripRoleplay } from '../src/lib/roleplay.js';

let pass = 0;
let fail = 0;

const shape = (segments) => segments.map((s) => `${s.type === 'action' ? 'A' : 'T'}:${s.value}`).join(' | ');

const check = (name, input, expected) => {
  const got = shape(splitRoleplay(input));
  if (got === expected) { pass += 1; console.log(`  PASS  ${name}`); }
  else {
    fail += 1;
    console.log(`  FAIL  ${name}`);
    console.log(`        want ${expected}`);
    console.log(`        got  ${got}`);
  }
};

console.log('--- roleplay segmentation ---');

check('action only', '*steps back defensively*', 'A:steps back defensively');

check('speech only', 'Hah? Say that again.', 'T:Hah? Say that again.');

check(
  'action after speech',
  'Fine. *crosses her arms*',
  'T:Fine.  | A:crosses her arms',
);

check(
  'action before speech',
  '*yawns* You should see Yotsuba.',
  'A:yawns | T: You should see Yotsuba.',
);

check(
  'action in the middle',
  'I heard you *looks away* the first time.',
  'T:I heard you  | A:looks away | T: the first time.',
);

check(
  'two actions',
  '*sighs* Whatever. *turns away*',
  'A:sighs | T: Whatever.  | A:turns away',
);

check(
  'double asterisks treated the same',
  '**She shifts her weight** and says nothing.',
  'A:She shifts her weight | T: and says nothing.',
);

check(
  'mid-typing, action not yet closed',
  'Fine. *crosses her ar',
  'T:Fine.  | A:crosses her ar',
);

check(
  'mid-typing, opening asterisk only',
  'Fine. *',
  'T:Fine. ',
);

check(
  'a lone asterisk in ordinary text is left alone',
  '2 * 3 is six',
  'T:2 * 3 is six',
);

check('empty input', '', '');

console.log('\n--- stripRoleplay ---');
const stripped = stripRoleplay('Fine. *crosses her arms* I heard you.');
if (stripped === 'Fine. crosses her arms I heard you.') { pass += 1; console.log('  PASS  markers removed for previews'); }
else { fail += 1; console.log(`  FAIL  markers removed for previews -> "${stripped}"`); }

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);

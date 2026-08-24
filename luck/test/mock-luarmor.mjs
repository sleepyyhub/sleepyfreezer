// Fake Luarmor: same two endpoints, same response shapes as the docs.
import { createServer } from 'node:http';

const received = [];

const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const send = (obj) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(obj));
    };

    if (req.method === 'GET' && req.url.includes('/details')) {
      return send({
        success: true,
        message: 'Success!',
        projects: [
          {
            platform: 'roblox',
            id: 'proj123',
            name: 'LUCK Hub',
            scripts: [
              {
                script_name: 'LUCK',
                script_id: 'scr456',
                script_version: '0007',
                ffa: true,
                silent: false,
              },
            ],
          },
        ],
      });
    }

    if (req.method === 'PUT' && req.url === '/v3/projects/proj123/scripts/scr456') {
      const parsed = JSON.parse(body);
      received.push({ auth: req.headers.authorization, ...parsed });
      return send({ success: true, message: 'Script updated!', script_version: '0008' });
    }

    res.writeHead(404).end('{}');
  });
});

server.listen(0, async () => {
  const PORT = server.address().port;
  const { spawn } = await import('node:child_process');
  // Async, not spawnSync: the mock server shares this process's event loop and
  // a sync spawn would deadlock it.
  const run = (extra) => new Promise((done) => {
    const child = spawn('node', [
      '/home/user/sleepyfreezer/luck/upload-luarmor.mjs',
      '--key', 'TESTKEY',
      '--base', `http://127.0.0.1:${PORT}`,
      ...extra,
    ], { encoding: 'utf8' });
    let stdout = '', stderr = '';
    child.stdout.on('data', (c) => (stdout += c));
    child.stderr.on('data', (c) => (stderr += c));
    child.on('close', (status) => done({ stdout, stderr, status }));
  });

  console.log('=== --dry ===');
  const dry = await run(['--dry']);
  console.log(dry.stdout + dry.stderr);
  console.log('sends during dry run:', received.length);

  console.log('=== real ===');
  const real = await run([]);
  console.log(real.stdout + real.stderr);

  const got = received[0];
  const checks = [
    ['one PUT sent', received.length === 1],
    ['api key in Authorization header', got?.auth === 'TESTKEY'],
    ['script body is the real file', typeof got?.script === 'string' && got.script.length > 90000],
    ['script starts with the LUCK source', got?.script.startsWith('local Players')],
    ['ffa preserved as true', got?.ffa === true],
    ['silent preserved as false', got?.silent === false],
    ['heartbeat not touched', !('heartbeat' in (got ?? {}))],
    ['lightning not touched', !('lightning' in (got ?? {}))],
    ['exit code 0', real.status === 0],
  ];
  let bad = 0;
  for (const [label, ok] of checks) {
    console.log(`  ${ok ? 'ok   ' : 'FAIL '} ${label}`);
    if (!ok) bad++;
  }
  console.log(bad === 0 ? '\nall green\n' : `\n${bad} failed\n`);
  server.close();
  process.exit(bad === 0 ? 0 : 1);
});

#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');

const specPath = path.resolve(__dirname, '../src/NativeAmphora.ts');
const source = fs.readFileSync(specPath, 'utf8');
const withoutComments = source
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/(^|\s)\/\/.*$/gm, '$1');
const spec = withoutComments.match(/interface\s+Spec\s+extends\s+TurboModule\s*\{([\s\S]*?)\n\}/);

if (!spec) {
  console.error('React Native control-surface guard: could not find the TurboModule Spec interface.');
  process.exit(1);
}

const forbiddenMethods = [
  'upload',
  'uploadChunk',
  'transfer',
  'transferChunk',
  'readFile',
  'readBytes',
  'readStream',
];
const found = forbiddenMethods.filter((method) =>
  new RegExp(`\\b${method}\\s*\\(`).test(spec[1]),
);

if (found.length > 0) {
  console.error(
    `React Native control-surface guard: forbidden method(s) ${found.join(', ')} found in the TurboModule spec. ` +
      'The React Native layer must remain commands-in/coalesced-events-out; JS does not run while suspended. ' +
      'See docs/reference/platform-constraints.md §3.',
  );
  process.exit(1);
}

console.log('React Native control-surface guard: spec remains control-surface only.');

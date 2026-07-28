import assert from 'node:assert/strict';
import test from 'node:test';
import { videoArtifactName } from './bridge.mjs';

test('names video evidence with UTC timestamp followed by scenario name', () => {
  assert.equal(
    videoArtifactName('custom-tool-lifecycle', new Date('2026-07-28T01:49:08.123Z')),
    '20260728T014908123Z-custom-tool-lifecycle.webm',
  );
});

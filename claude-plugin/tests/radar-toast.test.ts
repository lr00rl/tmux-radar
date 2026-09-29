import type { On } from 'claude-code';
import { expect, mock, test } from 'claude-code/testing';

import { parseFeed, parseLevels, toastText } from '../hooks/radar-toast.ts';

const NOW = 1_790_000_000_000;
const NOW_SECONDS = NOW / 1000;

/** The world beneath the plugin: a mark file, a feed script, a place to toast. */
function world(on: On, env: Readonly<Record<string, string>>) {
  const state = { changed: 1, feed: 'self\t1\n', exitCode: 0, runs: 0, toasts: [] as string[] };
  mock.env(on, env);
  on('session.start', (_$, e) => ({ cwd: e.cwd }));
  on('session.id', () => ({ value: 'own-session' }));
  on('fs.exists', () => ({ value: true }));
  on('fs.stat', () => ({
    value: { kind: 'file' as const, size: 1, mtimeMs: state.changed, isLink: false },
  }));
  on('process.run', () => {
    state.runs += 1;
    return { value: { exitCode: state.exitCode, stdout: state.feed, stderr: '' } };
  });
  on('ui.toast', (_$, e) => {
    state.toasts.push(e.text);
    return { value: undefined };
  });
  on('ui.log', () => ({ value: undefined }));
  return state;
}

const row = (epoch: number, level: string, where: string, label: string, pane: string, key: string) =>
  `${epoch}\t${level}\t${where}\t${label}\t${pane}\t${key}\n`;

// not /home: on macOS that is an automount, which the engine's fs refuses as a network location
const HOME = '/tmp/radar-home';
const IN_TMUX = { HOME, TMUX_PANE: '%1' };
const START = { cwd: '/work', surface: 'terminal' as const, isInteractive: true };

test('a mark that lands on another pane is toasted once', async ($, on) => {
  const clock = mock.clock(on, { now: NOW });
  const state = world(on, IN_TMUX);
  state.feed = `self\t1\n${row(NOW_SECONDS - 5, 'done', 'old-window', 'Claude finished', '%7', 's:old')}`;

  await $.session.start(START);
  expect(state.toasts).toEqual([]);

  state.changed = 2;
  state.feed += row(NOW_SECONDS, 'action', 'billing-api', 'Claude needs approval', '%9', 's:new');
  await clock.advance(2000);
  expect(state.toasts).toEqual(['⚠ billing-api · Claude needs approval']);

  state.changed = 3;
  await clock.advance(2000);
  expect(state.toasts).toHaveLength(1);
});

test('an unchanged mark file starts no process', async ($, on) => {
  const clock = mock.clock(on, { now: NOW });
  const state = world(on, IN_TMUX);

  await $.session.start(START);
  expect(state.runs).toBe(1);
  await clock.advance(10_000);
  expect(state.runs).toBe(1);
});

test('a pane nobody is looking at toasts nothing', async ($, on) => {
  const clock = mock.clock(on, { now: NOW });
  const state = world(on, IN_TMUX);
  state.feed = 'self\t0\n';

  await $.session.start(START);
  state.changed = 2;
  state.feed += row(NOW_SECONDS, 'action', 'billing-api', 'Claude needs approval', '%9', 's:new');
  await clock.advance(2000);
  expect(state.toasts).toEqual([]);
});

test('a mark that was already old when first seen is not news', async ($, on) => {
  const clock = mock.clock(on, { now: NOW });
  const state = world(on, IN_TMUX);

  await $.session.start(START);
  state.changed = 2;
  state.feed += row(NOW_SECONDS - 600, 'done', 'argus', 'Claude finished', '%9', 's:stale');
  await clock.advance(2000);
  expect(state.toasts).toEqual([]);
});

test('outside tmux the plugin does nothing', async ($, on) => {
  const clock = mock.clock(on, { now: NOW });
  const state = world(on, { HOME });

  await $.session.start(START);
  await clock.advance(10_000);
  expect(state.runs).toBe(0);
});

test('a headless run does nothing', async ($, on) => {
  const clock = mock.clock(on, { now: NOW });
  const state = world(on, IN_TMUX);

  await $.session.start({ cwd: '/work', surface: null, isInteractive: false });
  await clock.advance(10_000);
  expect(state.runs).toBe(0);
});

test('a checkout without the feed turns the polling off', async ($, on) => {
  const clock = mock.clock(on, { now: NOW });
  const state = world(on, IN_TMUX);
  state.exitCode = 2;

  await $.session.start(START);
  state.changed = 2;
  await clock.advance(10_000);
  expect(state.runs).toBe(1);
});

test('the feed is read row by row', () => {
  const feed = parseFeed(
    `self\t1\n${row(10, 'done', 'w', 'Claude finished: a: b', '%2', 's:k')}garbage\n\n`,
  );
  expect(feed.isViewed).toBe(true);
  expect(feed.rows).toEqual([
    { epoch: 10, level: 'done', where: 'w', label: 'Claude finished: a: b', pane: '%2', key: 's:k' },
  ]);
  expect(parseFeed('').rows).toEqual([]);
  expect(parseFeed('self\t0\n').isViewed).toBe(false);
});

test('a toast is one short line', () => {
  const base = { epoch: 1, pane: '%2', key: 's:k' };
  expect(toastText({ ...base, level: 'done', where: 'argus', label: 'Claude finished' })).toBe(
    '✓ argus · Claude finished',
  );
  expect(toastText({ ...base, level: 'notice', where: '', label: 'Claude turn failed' })).toBe(
    '! Claude turn failed',
  );
  const long = toastText({ ...base, level: 'done', where: '项目', label: '完'.repeat(200) });
  expect([...long]).toHaveLength(72);
  expect(long.endsWith('…')).toBe(true);
});

test('levels fall back to all three', () => {
  expect([...parseLevels(undefined)]).toEqual(['action', 'done', 'notice']);
  expect([...parseLevels(' action , done ')]).toEqual(['action', 'done']);
  expect([...parseLevels('')]).toEqual(['action', 'done', 'notice']);
});

// Toasts in this Claude Code session when an agent in another tmux pane gets
// a mark. Display only: tmux-radar's command hooks and scanner own the state,
// and `needinput-toast.sh feed` owns what a mark means (level, window name,
// whether a pane is on screen). This module decides what is news and says it.
import type { EngineInterface, Register } from 'claude-code';

export type Row = {
  epoch: number;
  level: string;
  where: string;
  label: string;
  pane: string;
  key: string;
};

export type Feed = {
  /** Whether this session's own pane is on screen. */
  isViewed: boolean;
  rows: Row[];
};

const POLL_MS = 2000;
/** A mark older than this when first seen is history, not news. */
const FRESH_SECONDS = 120;
const MAX_CHARS = 72;
const DEFAULT_LEVELS = 'action,done,notice';
const GLYPHS: Readonly<Record<string, string>> = { action: '⚠', done: '✓', notice: '!' };

/** Reads what `needinput-toast.sh feed` prints. */
export function parseFeed(text: string): Feed {
  const rows: Row[] = [];
  let isViewed = false;
  for (const line of text.split('\n')) {
    const [first, level, where, label, pane, key] = line.split('\t');
    if (first === 'self') {
      isViewed = level === '1';
      continue;
    }
    const epoch = Number(first);
    if (first === undefined || first === '' || !Number.isFinite(epoch)) continue;
    if (level === undefined || label === undefined || key === undefined) continue;
    rows.push({ epoch, level, where: where ?? '', label, pane: pane ?? '-', key });
  }
  return { isViewed, rows };
}

/** One line: the glyph of the level, where it happened, what happened. */
export function toastText(row: Row): string {
  const glyph = GLYPHS[row.level] ?? '!';
  const text = row.where === '' ? `${glyph} ${row.label}` : `${glyph} ${row.where} · ${row.label}`;
  const points = [...text];
  return points.length > MAX_CHARS ? `${points.slice(0, MAX_CHARS - 1).join('')}…` : text;
}

export function parseLevels(value: unknown): Set<string> {
  const text = typeof value === 'string' && value.trim() !== '' ? value : DEFAULT_LEVELS;
  return new Set(
    text
      .split(',')
      .map((level) => level.trim())
      .filter((level) => level !== ''),
  );
}

/**
 * The feed script, from the first checkout that has one: the configured one,
 * the checkout this plugin was loaded from (same version as this module), the
 * TPM install. An installed plugin is copied without its sibling `scripts/`,
 * so there the TPM install answers.
 */
async function findFeed(
  $: EngineInterface,
  home: string,
  radarDir: string,
): Promise<string | undefined> {
  const managed = await $.env.get('TMUX_PLUGIN_MANAGER_PATH');
  const roots = [
    radarDir,
    `${$.plugin.root}/..`,
    managed === undefined ? '' : `${managed.replace(/\/+$/, '')}/tmux-radar`,
    `${home}/.tmux/plugins/tmux-radar`,
  ];
  for (const root of roots) {
    if (root === '') continue;
    const path = `${root.replace(/^~(?=\/|$)/, home)}/scripts/needinput-toast.sh`;
    if (await $.fs.exists(path)) return path;
  }
  return undefined;
}

export const register: Register = (on, options) => {
  const levels = parseLevels(options['levels']);
  const radarDir = typeof options['radarDir'] === 'string' ? options['radarDir'] : '';

  on('session.start', async ($, e, next) => {
    const started = await next(e);
    // nobody reads a toast in a headless run, and outside tmux there are no panes
    if (!e.isInteractive) return started;
    const pane = await $.env.get('TMUX_PANE');
    if (pane === undefined || pane === '') return started;

    const home = (await $.env.get('HOME')) ?? '';
    const stateDir = (await $.env.get('TMUX_RADAR_STATE_DIR')) ?? `${home}/.local/state/tmux`;
    const marks = (await $.env.get('TMUX_RADAR_NEEDINPUT_FILE')) ?? `${stateDir}/need-input`;
    const feed = await findFeed($, home, radarDir);
    if (feed === undefined) {
      $.ui.log('no tmux-radar checkout found: toasts are off', { to: 'debug' });
      return started;
    }
    const sessionId = await $.session.id();

    let seen = new Set<string>();
    let lastChange = -1;
    let isPrimed = false;
    let isBusy = false;
    let isOff = false;

    const pass = async (): Promise<void> => {
      // the mark file changes only when a mark is written or cleared, so an
      // idle workspace costs one stat per period and starts no process
      let changed: number;
      try {
        changed = (await $.fs.stat(marks)).mtimeMs;
      } catch {
        return; // no mark has ever been written
      }
      if (changed === lastChange) return;

      const ran = await $.process.run([feed, 'feed', pane, sessionId], { timeoutMs: 5000 });
      if (ran.exitCode !== 0) {
        // a checkout from before the feed existed answers with its usage text
        isOff = true;
        $.ui.log('this tmux-radar checkout has no toast feed: update it to get toasts');
        return;
      }
      lastChange = changed;

      const { isViewed, rows } = parseFeed(ran.stdout);
      const now = Math.floor((await $.clock.now()) / 1000);
      const current = new Set<string>();
      for (const row of rows) {
        const id = `${row.key}@${row.epoch}`;
        current.add(id);
        if (seen.has(id)) continue;
        // what was on file when the session started is not news, and a toast
        // in a pane nobody is looking at is read by nobody
        if (!isPrimed || !isViewed) continue;
        if (!levels.has(row.level) || now - row.epoch > FRESH_SECONDS) continue;
        $.ui.toast(toastText(row), { timeoutMs: row.level === 'action' ? 10_000 : 6000 });
      }
      seen = current;
    };

    const tick = async (): Promise<void> => {
      if (isBusy || isOff) return;
      isBusy = true;
      try {
        await pass();
      } catch (error) {
        $.ui.log(`feed skipped: ${error instanceof Error ? error.message : String(error)}`, {
          to: 'debug',
        });
      } finally {
        isBusy = false;
        isPrimed = true;
      }
    };

    await tick();
    const timer = $.clock.every(POLL_MS, () => {
      if (isOff) timer.cancel();
      else void tick();
    });
    return started;
  });
};

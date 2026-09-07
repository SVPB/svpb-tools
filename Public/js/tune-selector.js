'use strict';

/**
 * Shared tune-selection component for the binder constructor and the personal
 * binder builder.
 *
 * The component owns everything the two pages have in common: the branch
 * picker, the tune catalogue with its search filter, and the ordered list of
 * selected entries with their part tags. What each page *does* with the
 * selection — YAML on the constructor, a PDF request on the builder — stays in
 * the page.
 *
 * Two things the component cannot decide for itself are supplied as hooks to
 * `init`: how the page reports status, and what else the page has to reset when
 * the selection is cleared.
 */
const TuneSelector = (() => {
  // ── State ────────────────────────────────────────────────────────────────
  // `entries` is never reassigned: callers hold on to the array returned by
  // `TuneSelector.entries()`, so clearing has to mutate it in place.
  const entries = [];      // [{tuneSlug, title, parts: [string]}]
  let allTunes = [];       // [{id, slug, title}]
  let tuneDetails = {};    // slug → {id, slug, title, parts: [{id, name}]}

  // ── Page hooks ───────────────────────────────────────────────────────────
  let setStatus = () => {};
  let onClear = () => {};
  let restore = async () => false;

  const el = id => document.getElementById(id);
  const currentFilter = () => el('search-tunes').value.toLowerCase();

  // ── Data loading ─────────────────────────────────────────────────────────
  async function loadTunes(branch) {
    const list = el('tune-list');
    list.innerHTML = '<li style="color:#888;">Loading…</li>';
    allTunes = [];
    tuneDetails = {};
    try {
      const res = await fetch(`/branches/${encodeURIComponent(branch)}/tunes`);
      allTunes = await res.json();
      renderTuneList('');
    } catch (e) {
      list.innerHTML = '<li style="color:#c00;">Failed to load tunes.</li>';
    }
  }

  async function getTuneDetail(slug) {
    if (tuneDetails[slug]) return tuneDetails[slug];
    const branch = el('sel-branch').value;
    const res = await fetch(`/branches/${encodeURIComponent(branch)}/tunes/${encodeURIComponent(slug)}`);
    const detail = await res.json();
    tuneDetails[slug] = detail;
    return detail;
  }

  // ── Render helpers ───────────────────────────────────────────────────────
  function renderTuneList(filter) {
    const list = el('tune-list');
    if (!allTunes.length) {
      list.innerHTML = '<li style="color:#888;">No tunes found.</li>';
      return;
    }
    const visible = filter
      ? allTunes.filter(t => (t.title || t.slug).toLowerCase().includes(filter))
      : allTunes;
    list.innerHTML = '';
    visible.forEach(tune => {
      const added = entries.some(e => e.tuneSlug === tune.slug);
      const li = document.createElement('li');
      if (added) li.className = 'added';
      const label = document.createElement('span');
      label.textContent = tune.title || tune.slug;
      const btn = document.createElement('button');
      btn.textContent = added ? 'Added ✓' : '+ Add';
      btn.disabled = added;
      btn.addEventListener('click', () => addTune(tune.slug, tune.title || tune.slug));
      li.appendChild(label);
      li.appendChild(btn);
      list.appendChild(li);
    });
  }

  function renderBinder() {
    const ul = el('binder-entries');
    const empty = el('empty-msg');
    ul.innerHTML = '';
    empty.style.display = entries.length === 0 ? '' : 'none';
    if (entries.length === 0) return;
    entries.forEach((entry, idx) => {
      const li = document.createElement('li');
      // Reorder buttons
      const up = document.createElement('button');
      up.className = 'move-btn'; up.textContent = '↑'; up.title = 'Move up';
      up.addEventListener('click', () => { if (idx > 0) { [entries[idx-1], entries[idx]] = [entries[idx], entries[idx-1]]; renderBinder(); } });
      const dn = document.createElement('button');
      dn.className = 'move-btn'; dn.textContent = '↓'; dn.title = 'Move down';
      dn.addEventListener('click', () => { if (idx < entries.length-1) { [entries[idx], entries[idx+1]] = [entries[idx+1], entries[idx]]; renderBinder(); } });
      // Info
      const info = document.createElement('div');
      info.style.flex = '1';
      info.style.marginLeft = '4px';
      const title = document.createElement('div');
      title.textContent = entry.title;
      // Part tags
      const tags = document.createElement('div');
      tags.className = 'part-tags';
      if (tuneDetails[entry.tuneSlug]) {
        tuneDetails[entry.tuneSlug].parts.forEach(p => {
          const tag = document.createElement('span');
          tag.className = 'part-tag' + (entry.parts.includes(p.name) ? ' selected' : '');
          tag.textContent = p.name;
          tag.addEventListener('click', () => togglePart(entry.tuneSlug, p.name));
          tags.appendChild(tag);
        });
      }
      info.appendChild(title);
      info.appendChild(tags);
      // Remove
      const rm = document.createElement('button');
      rm.textContent = '✕'; rm.title = 'Remove';
      rm.addEventListener('click', () => {
        entries.splice(idx, 1);
        renderBinder();
        renderTuneList(currentFilter());
      });
      li.appendChild(up);
      li.appendChild(dn);
      li.appendChild(info);
      li.appendChild(rm);
      ul.appendChild(li);
    });
    renderTuneList(currentFilter());
  }

  // ── Actions ──────────────────────────────────────────────────────────────
  async function addTune(slug, title) {
    if (entries.some(e => e.tuneSlug === slug)) return;
    try {
      const detail = await getTuneDetail(slug);
      entries.push({ tuneSlug: slug, title, parts: detail.parts.map(p => p.name) });
      renderBinder();
    } catch (e) {
      setStatus('Failed to load tune detail: ' + e.message, 'error');
    }
  }

  function togglePart(slug, partName) {
    const entry = entries.find(e => e.tuneSlug === slug);
    if (!entry) return;
    const idx = entry.parts.indexOf(partName);
    if (idx >= 0) {
      entry.parts.splice(idx, 1);
      if (entry.parts.length === 0) entry.parts.push(partName); // keep at least one
    } else {
      entry.parts.push(partName);
    }
    renderBinder();
  }

  function clear() {
    entries.length = 0;
    onClear();
    setStatus('');
    renderBinder();
    renderTuneList(currentFilter());
  }

  // ── Initialise ───────────────────────────────────────────────────────────
  /**
   * Wires up the component and loads the branch list.
   *
   * @param {object} hooks
   * @param {(msg: string, severity?: string) => void} [hooks.setStatus]
   *        Reports progress and errors. Pages that do not distinguish
   *        severities simply ignore the second argument.
   * @param {() => void} [hooks.onClear]
   *        Resets whatever output the page owns; called before the selection
   *        is re-rendered.
   * @param {(branches: object[], select: HTMLSelectElement) => Promise<boolean>} [hooks.restore]
   *        Gives the page a chance to pick the branch and seed the selection
   *        itself (the builder restores a shared spec this way). Returning
   *        `true` suppresses the default single-branch auto-selection.
   */
  async function init(hooks) {
    hooks = hooks || {};
    if (hooks.setStatus) setStatus = hooks.setStatus;
    if (hooks.onClear) onClear = hooks.onClear;
    if (hooks.restore) restore = hooks.restore;

    el('sel-branch').addEventListener('change', async e => {
      entries.length = 0;
      renderBinder();
      if (e.target.value) await loadTunes(e.target.value);
    });

    el('search-tunes').addEventListener('input', e => {
      renderTuneList(e.target.value.toLowerCase());
    });

    try {
      const res = await fetch('/branches');
      const branches = await res.json();
      const sel = el('sel-branch');
      sel.innerHTML = '<option value="">— select a year —</option>';
      branches.forEach(b => {
        const opt = document.createElement('option');
        opt.value = b.name;
        opt.textContent = b.name;
        sel.appendChild(opt);
      });
      if (await restore(branches, sel)) return;
      if (branches.length === 1) {
        sel.value = branches[0].name;
        await loadTunes(branches[0].name);
      }
    } catch (e) {
      setStatus('Failed to load branches: ' + e.message, 'error');
    }
  }

  return {
    init,
    clear,
    addTune,
    togglePart,
    loadTunes,
    getTuneDetail,
    render: renderBinder,
    /** The live selection array — mutate it, never replace it. */
    entries: () => entries,
    /** The catalogue for the currently selected branch. */
    tunes: () => allTunes,
    /** The selected branch name, or '' when none is chosen. */
    branch: () => el('sel-branch').value,
    /** The typed binder name, falling back to `fallback` when blank. */
    binderName: fallback => el('binder-name').value.trim() || fallback,
  };
})();

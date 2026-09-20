'use strict';

/**
 * Shared tune-selection component for the binder constructor and the personal
 * binder builder.
 *
 * The component owns everything the two pages have in common: the branch
 * picker, the tune catalogue with its search filter, and the ordered selection.
 * What each page *does* with the selection — YAML on the constructor, a PDF
 * request on the builder — stays in the page.
 *
 * A tune goes into a binder whole. Its parts are not offered as a choice: every
 * part of a tune resolves to the same multi-voice score until #20 renders them
 * separately, so choosing between them could only ever mislead (#24). Entries
 * still carry the tune's full part list, because that is what the binder spec
 * and every shared URL are written in.
 *
 * The selection is always a list of sections, each an ordered list of entries.
 * A section's title becomes a divider page ahead of it; a section with no title
 * gets no divider. A page that has not opted in to sections (`sections: false`)
 * sees exactly one untitled section and none of the controls for adding,
 * naming, or reordering sections, so its selection behaves as a flat list.
 *
 * A section can be folded down to its header row so a tall binder stays
 * navigable. Folding is display only: it never touches the selection, the
 * ordering, or anything a page generates from them.
 *
 * Things the component cannot decide for itself are supplied as hooks to
 * `init`: how the page reports status, what else the page has to reset when the
 * selection is cleared, and how a page restores a saved selection.
 */
const TuneSelector = (() => {
  // ── State ────────────────────────────────────────────────────────────────
  // `sections` is never reassigned: callers hold on to the array returned by
  // `TuneSelector.sections()`, so resetting has to mutate it in place.
  const sections = [];     // [{title: string, entries: [{tuneSlug, title, parts: [string]}]}]
  let active = 0;          // index of the section the catalogue adds tunes to
  let sectionsEnabled = false;
  let untitledSections = true;   // a blank section title is allowed, and means no divider
  let allTunes = [];       // [{id, slug, title, subtitle, abcPath}]
  let tuneDetails = {};    // slug → {id, slug, title, subtitle, parts: [{id, name}]}
  // Folded sections, held by identity rather than by index so the fold follows
  // a section through a reorder, a retitle, and every rebuild of the list.
  const folded = new WeakSet();

  // ── Page hooks ───────────────────────────────────────────────────────────
  let setStatus = () => {};
  let onClear = () => {};
  let restore = async () => false;

  const el = id => document.getElementById(id);
  const currentFilter = () => el('search-tunes').value.toLowerCase();
  const allEntries = () => sections.flatMap(s => s.entries);
  // Variants of one tune share a title, so the subtitle ("Harmony 1") is part of the label.
  const tuneLabel = t => t.title
    ? (t.subtitle ? `${t.title} — ${t.subtitle}` : t.title)
    : t.slug;
  // The file behind the label: variants are separate files, and it is the file that gets edited.
  const tuneFile = t => t.abcPath || `${t.slug}.abc`;
  const sectionLabel = idx => sections[idx].title.trim()
    || `Section ${idx + 1} (${untitledSections ? 'no divider' : 'untitled'})`;

  /** Title over file path, as shown in both the catalogue and the binder. */
  function tuneNameBlock(title, file) {
    const block = document.createElement('div');
    const name = document.createElement('div');
    name.textContent = title;
    block.appendChild(name);
    if (file) {
      const path = document.createElement('div');
      path.className = 'tune-file';
      path.textContent = file;
      block.appendChild(path);
    }
    return block;
  }

  function resetSections() {
    sections.length = 0;
    sections.push({ title: '', entries: [] });
    active = 0;
  }
  resetSections();

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
    const selected = allEntries();
    const visible = filter
      ? allTunes.filter(t => `${tuneLabel(t)} ${tuneFile(t)}`.toLowerCase().includes(filter))
      : allTunes;
    list.innerHTML = '';
    visible.forEach(tune => {
      const added = selected.some(e => e.tuneSlug === tune.slug);
      const li = document.createElement('li');
      if (added) li.className = 'added';
      const label = tuneNameBlock(tuneLabel(tune), tuneFile(tune));
      const btn = document.createElement('button');
      btn.textContent = added ? 'Added ✓' : '+ Add';
      btn.disabled = added;
      btn.addEventListener('click', () => addTune(tune.slug, tuneLabel(tune)));
      li.appendChild(label);
      li.appendChild(btn);
      list.appendChild(li);
    });
  }

  function button(text, title, className, onClick) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = text;
    b.title = title;
    if (className) b.className = className;
    b.addEventListener('click', onClick);
    return b;
  }

  /**
   * The header row of a section: the disclosure control, the section's own
   * controls, and — while it is folded — how many tunes are hidden under it.
   * `tunesId` identifies the list the disclosure control opens and closes.
   */
  function renderSectionHeader(section, sIdx, tunesId) {
    const row = document.createElement('div');
    row.className = 'section-header' + (sIdx === active ? ' active' : '');
    row.title = 'Tunes you add from the catalogue go into the highlighted section';
    row.addEventListener('click', e => {
      // Buttons act for themselves, and re-rendering under the title input would take its focus.
      if (e.target.closest('button, input')) return;
      if (active !== sIdx) { active = sIdx; renderBinder(); }
    });

    // Folding and activating are separate gestures: this one is a button, and
    // the row's own click handler leaves buttons alone.
    const shut = folded.has(section);
    const disclosure = button(shut ? '▸' : '▾', shut ? 'Show this section' : 'Fold this section',
                              'fold-btn', () => { setFolded(section, !shut); renderBinder(); });
    disclosure.setAttribute('aria-expanded', String(!shut));
    disclosure.setAttribute('aria-controls', tunesId);
    disclosure.setAttribute('aria-label', `${shut ? 'Show' : 'Fold'} ${sectionLabel(sIdx)}`);
    row.appendChild(disclosure);

    row.appendChild(button('↑', 'Move section up', 'move-btn', () => moveSection(sIdx, -1)));
    row.appendChild(button('↓', 'Move section down', 'move-btn', () => moveSection(sIdx, 1)));

    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'section-title';
    input.maxLength = 60;
    input.value = section.title;
    input.placeholder = untitledSections ? 'Section title (blank: no divider)' : 'Section title';
    input.setAttribute('aria-label', `Title of section ${sIdx + 1}`);
    // Update state without re-rendering, so typing keeps focus.
    input.addEventListener('input', () => { section.title = input.value; refreshSectionLabels(); });
    input.addEventListener('focus', () => {
      if (active !== sIdx) {
        active = sIdx;
        el('binder-entries').querySelectorAll('.section-header')
          .forEach((h, i) => h.classList.toggle('active', i === active));
      }
    });
    row.appendChild(input);

    // A folded section still says how much is under it.
    if (shut) {
      const count = document.createElement('span');
      count.className = 'section-count';
      const n = section.entries.length;
      count.textContent = `${n} ${n === 1 ? 'tune' : 'tunes'}`;
      row.appendChild(count);
    }

    if (sections.length > 1) {
      const receiver = sIdx > 0 ? 'above' : 'below';
      row.appendChild(button('✕', `Remove section — its tunes join the section ${receiver}`, '', () => removeSection(sIdx)));
    }
    return row;
  }

  function renderEntry(entry, sIdx, eIdx) {
    const section = sections[sIdx];
    const li = document.createElement('li');

    // Reorder buttons. At a section boundary they carry the tune across it.
    li.appendChild(button('↑', 'Move up', 'move-btn', () => moveEntry(sIdx, eIdx, -1)));
    li.appendChild(button('↓', 'Move down', 'move-btn', () => moveEntry(sIdx, eIdx, 1)));

    // Info
    const info = document.createElement('div');
    info.style.flex = '1';
    info.style.marginLeft = '4px';
    const tune = allTunes.find(t => t.slug === entry.tuneSlug);
    info.appendChild(tuneNameBlock(entry.title, tune && tuneFile(tune)));
    li.appendChild(info);

    // Jump straight to another section, for moves the arrows would take a while over.
    if (sectionsEnabled && sections.length > 1) {
      const sel = document.createElement('select');
      sel.className = 'section-move';
      sel.title = 'Move to section';
      sel.setAttribute('aria-label', `Section for ${entry.title}`);
      sections.forEach((_, i) => {
        const opt = document.createElement('option');
        opt.value = String(i);
        opt.textContent = sectionLabel(i);
        opt.selected = i === sIdx;
        sel.appendChild(opt);
      });
      sel.addEventListener('change', () => moveEntryToSection(sIdx, eIdx, Number(sel.value)));
      li.appendChild(sel);
    }

    // Remove
    li.appendChild(button('✕', 'Remove', '', () => {
      section.entries.splice(eIdx, 1);
      renderBinder();
    }));
    return li;
  }

  function renderBinder() {
    const ul = el('binder-entries');
    const empty = el('empty-msg');
    const total = allEntries().length;
    ul.innerHTML = '';
    empty.style.display = total === 0 ? '' : 'none';
    el('add-section').hidden = !sectionsEnabled;

    sections.forEach((section, sIdx) => {
      // Without sections there is nothing to fold, so the entries stay a flat list.
      if (!sectionsEnabled) {
        section.entries.forEach((entry, eIdx) => ul.appendChild(renderEntry(entry, sIdx, eIdx)));
        return;
      }
      // A section is its header plus a list of its own, so folding it hides one
      // element. The tunes are rendered either way: they are only out of sight.
      const group = document.createElement('li');
      group.className = 'section-group';
      const tunes = document.createElement('ul');
      tunes.className = 'section-tunes';
      tunes.id = `section-tunes-${sIdx}`;
      tunes.hidden = folded.has(section);
      section.entries.forEach((entry, eIdx) => tunes.appendChild(renderEntry(entry, sIdx, eIdx)));
      group.appendChild(renderSectionHeader(section, sIdx, tunes.id));
      group.appendChild(tunes);
      ul.appendChild(group);
    });
    renderFoldAll();
    renderTuneList(currentFilter());
  }

  /** Folds or unfolds one section. Display only — the selection is untouched. */
  function setFolded(section, shut) {
    if (shut) folded.add(section); else folded.delete(section);
  }

  /**
   * Labels the fold-everything control for what it would do next, and hides it
   * where there is nothing to fold or only one section to fold.
   */
  function renderFoldAll() {
    const btn = el('fold-all-sections');
    btn.hidden = !sectionsEnabled || sections.length < 2;
    if (btn.hidden) return;
    const anyOpen = sections.some(s => !folded.has(s));
    btn.textContent = anyOpen ? 'Fold all' : 'Show all';
    btn.title = anyOpen
      ? 'Fold every section down to its header'
      : 'Show the tunes in every section';
  }

  /** Relabels the move-to-section menus after a title edit, without re-rendering. */
  function refreshSectionLabels() {
    el('binder-entries').querySelectorAll('select.section-move').forEach(sel => {
      Array.from(sel.options).forEach((opt, i) => { opt.textContent = sectionLabel(i); });
    });
  }

  // ── Actions ──────────────────────────────────────────────────────────────
  async function addTune(slug, title) {
    if (allEntries().some(e => e.tuneSlug === slug)) return;
    try {
      // The whole tune goes in, so the entry names every part the catalogue knows.
      const detail = await getTuneDetail(slug);
      sections[active].entries.push({ tuneSlug: slug, title, parts: detail.parts.map(p => p.name) });
      // Show the section the tune just went into, rather than swallowing it.
      setFolded(sections[active], false);
      renderBinder();
    } catch (e) {
      setStatus('Failed to load tune detail: ' + e.message, 'error');
    }
  }

  /** Moves an entry one place; off either end of a section it joins the neighbouring one. */
  function moveEntry(sIdx, eIdx, delta) {
    const list = sections[sIdx].entries;
    const target = eIdx + delta;
    if (target >= 0 && target < list.length) {
      [list[eIdx], list[target]] = [list[target], list[eIdx]];
    } else if (delta < 0 && sIdx > 0) {
      sections[sIdx - 1].entries.push(list.splice(eIdx, 1)[0]);
      setFolded(sections[sIdx - 1], false);
    } else if (delta > 0 && sIdx < sections.length - 1) {
      sections[sIdx + 1].entries.unshift(list.splice(eIdx, 1)[0]);
      setFolded(sections[sIdx + 1], false);
    } else {
      return;
    }
    renderBinder();
  }

  function moveEntryToSection(sIdx, eIdx, targetIdx) {
    if (targetIdx === sIdx || !sections[targetIdx]) return;
    sections[targetIdx].entries.push(sections[sIdx].entries.splice(eIdx, 1)[0]);
    setFolded(sections[targetIdx], false);
    renderBinder();
  }

  function addSection() {
    sections.push({ title: '', entries: [] });
    active = sections.length - 1;
    renderBinder();
    const inputs = el('binder-entries').querySelectorAll('input.section-title');
    if (inputs.length) inputs[inputs.length - 1].focus();
  }

  function moveSection(sIdx, delta) {
    const target = sIdx + delta;
    if (target < 0 || target >= sections.length) return;
    [sections[sIdx], sections[target]] = [sections[target], sections[sIdx]];
    if (active === sIdx) active = target;
    else if (active === target) active = sIdx;
    renderBinder();
  }

  /** Removes a section's divider, keeping its tunes: they join the section above (or below, for the first). */
  function removeSection(sIdx) {
    if (sections.length < 2) return;
    const [removed] = sections.splice(sIdx, 1);
    const receiver = sIdx > 0 ? sections[sIdx - 1] : sections[0];
    if (sIdx > 0) receiver.entries.push(...removed.entries);
    else receiver.entries.unshift(...removed.entries);
    // The tunes moved somewhere the user can see.
    if (removed.entries.length) setFolded(receiver, false);
    // Follow the tunes: a removed active section hands over to the one that took them.
    if (active > sIdx || (active === sIdx && sIdx > 0)) active -= 1;
    renderBinder();
  }

  /**
   * Replaces the selection with `saved`, a list of
   * `{title, entries: [{tuneSlug, parts?}]}` in binder order. Tunes missing from
   * the current branch's catalogue are dropped. The branch must already be
   * selected and its tunes loaded.
   *
   * A saved `parts` list is read and discarded: URLs shared while the tags were
   * still clickable may name one voice of a tune, and restoring that selection
   * would be restoring a choice that never worked (#24). The tune comes back
   * whole, as it would have been rendered anyway.
   */
  async function load(saved) {
    sections.length = 0;
    for (const s of saved) {
      const section = { title: sectionsEnabled ? (s.title || '') : '', entries: [] };
      for (const e of (s.entries || [])) {
        const tune = allTunes.find(t => t.slug === e.tuneSlug);
        const seen = x => x.tuneSlug === e.tuneSlug;
        if (!tune || allEntries().some(seen) || section.entries.some(seen)) continue;
        const detail = await getTuneDetail(e.tuneSlug);
        section.entries.push({
          tuneSlug: e.tuneSlug,
          title: tuneLabel(tune),
          parts: detail.parts.map(p => p.name),
        });
      }
      if (sectionsEnabled || sections.length === 0) sections.push(section);
      else sections[0].entries.push(...section.entries);
    }
    if (sections.length === 0) resetSections();
    active = sections.length - 1;
    renderBinder();
  }

  function clear() {
    resetSections();
    onClear();
    setStatus('');
    renderBinder();
  }

  // ── Initialise ───────────────────────────────────────────────────────────
  /**
   * Wires up the component and loads the branch list.
   *
   * @param {object} hooks
   * @param {boolean} [hooks.sections]
   *        Shows the controls for adding, naming, and reordering sections.
   *        Without it the selection is a single untitled section.
   * @param {boolean} [hooks.untitledSections=true]
   *        Whether a blank section title is meaningful (no divider). Pages
   *        that need every section titled turn this off, and the controls
   *        stop suggesting that a blank title is an option; enforcing it is
   *        still the page's job.
   * @param {(msg: string, severity?: string) => void} [hooks.setStatus]
   *        Reports progress and errors. Pages that do not distinguish
   *        severities simply ignore the second argument.
   * @param {() => void} [hooks.onClear]
   *        Resets whatever output the page owns; called before the selection
   *        is re-rendered.
   * @param {(branches: object[], select: HTMLSelectElement) => Promise<boolean>} [hooks.restore]
   *        Gives the page a chance to pick the branch and seed the selection
   *        itself (the builder restores a shared spec this way, via `load`).
   *        Returning `true` suppresses the default single-branch auto-selection.
   */
  async function init(hooks) {
    hooks = hooks || {};
    sectionsEnabled = !!hooks.sections;
    untitledSections = hooks.untitledSections !== false;
    if (hooks.setStatus) setStatus = hooks.setStatus;
    if (hooks.onClear) onClear = hooks.onClear;
    if (hooks.restore) restore = hooks.restore;

    el('add-section').addEventListener('click', addSection);
    el('fold-all-sections').addEventListener('click', () => {
      // Whatever the button offers, it does to every section at once.
      const shut = sections.some(s => !folded.has(s));
      sections.forEach(s => setFolded(s, shut));
      renderBinder();
    });
    renderBinder();

    el('sel-branch').addEventListener('change', async e => {
      resetSections();
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
    load,
    addTune,
    addSection,
    loadTunes,
    getTuneDetail,
    render: renderBinder,
    /** The live sections array — mutate it, never replace it. */
    sections: () => sections,
    /** Every selected entry in binder order, across sections (a fresh array). */
    entries: allEntries,
    /** The catalogue for the currently selected branch. */
    tunes: () => allTunes,
    /** The selected branch name, or '' when none is chosen. */
    branch: () => el('sel-branch').value,
    /** The typed binder name, falling back to `fallback` when blank. */
    binderName: fallback => el('binder-name').value.trim() || fallback,
  };
})();

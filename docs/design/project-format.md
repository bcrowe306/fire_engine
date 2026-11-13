# Project folders and files

Status: built, all seven steps (decisions taken 2026-11-13).
"Today" below is the survey from before.

## Today (surveyed)

A project is a folder, `Name.pads/`:

| Path | What | Written by |
|---|---|---|
| `project.fire` | fire:session file: ids, the samples table (`PSMP` v1), wavetables, the project (`PPRJ` v38) | `model_save` |
| `samples/` | imports, sampled takes (`Recording-N.wav`), bounces, freezes, consolidations | ten call sites, each joining `"samples"` itself |
| `takes/` | audio tracks' takes (`A1-N.wav`) | `build_audio` |
| `warped/` | warp renderings (cache) | `warp_path` |
| `renders/` | comp renderings (cache) | `comp_source` |
| `.autosave/project.fire` | the backup | `model_save_backup` |

The user's own files are in the settings folder
(`~/Library/Application Support/Pads/` on macOS): `settings.ini`,
`layout2.ini`, `pads.log`, `open-project.txt`, `Templates/`, `Presets/Synth/`.

What holds up: one version number with migrations for every older file,
newer files refused; sample paths stored relative to the folder; imports
copied in with unique names; plug-in states and wavetables inside
`project.fire`.

What doesn't:

1. **Takes overwrite earlier takes.** The recorder numbers takes from a
   counter that starts at 1 whenever it is made (a project opened, the
   sampling input changed, the graph rebuilt), and `os.create` truncates:
   `Recording-1.wav` or `A1-1.wav` a pad already plays is replaced.
2. **Save As flattens and overwrites.** Every sample is copied to
   `samples/<base name>` with no unique naming: takes leave `takes/`, and
   two files with one name become one.
3. **Caches only grow.** Every warp ratio/mode/transpose and every comp
   edit leaves a file; nothing removes them; Save As drops them.
4. **Unused files stay.** Deleted takes, replaced samples, old bounces.
5. **Unsaved projects live in the OS temp folder**, with their recordings
   and autosave: macOS clears it.
6. **Relative paths carry the OS's separator** (`\` from Windows).
7. **Only `samples/` is known to templates and moves**; it works because
   every take is also in the samples table, which nothing enforces.

## Decisions

- **Unsaved projects:** in Pads' own folder, `~/Music/Pads/Unsaved/Untitled N.pads`
  (a setting; under the prefs folder when Pads runs with `--prefs`, so
  tests stay in their sandbox). Saving moves the folder where the user
  chooses. Left-over unsaved projects are offered on start, like a backup.
- **Audio by origin:** `Samples/Imported`, `Samples/Recorded`,
  `Samples/Processed`.
- **Caches:** `cache/` in the project, safe to delete, never copied,
  trimmed.
- **Unused files:** File > Clean Up Project lists them and moves them to
  the Trash. Nothing is removed by itself.

## The layout

```
Name.pads/
  project.fire
  Samples/
    Imported/      files brought in (browser, drag, Add Take File)
    Recorded/      sampled into pads (Recording-N.wav), audio tracks' takes (A1 seq 1.wav)
    Processed/     bounces, bounces in place, freezes, consolidations, normalize/edit results, export to pad
  cache/           rebuilt on demand, never copied
    warp/          warp renderings
    comp/          comp renderings
    recording/     audio tracks' takes while recorded (folded into Recorded, then removed)
  .autosave/       the backup
```

Rules:

- **Every new file gets a name no file in its folder has** (`unique_path`),
  at the moment it is created. Recorders ask for the next free name
  instead of keeping a counter; the rt side is untouched (the name is made
  on the control side, as now).
- **Everything the project plays is in the samples table.** A file in
  `Samples/` that isn't is unused (Clean Up's list). Files under `cache/`
  are never in the table.
- **Paths are written with `/`**, relative to the folder when inside it;
  reading accepts either separator.
- **Folder names live in one place**: `apps/pads/model/project_paths.odin`
  (`project_folder(dir, .Recorded)`, `project_new_file(dir, .Processed,
  "Bounce A1.wav")`, `stored_path`/`loaded_path`), replacing the ten joins.
  A name with a separator in it (a sequence called "A/B") is made safe.

## Copies and moves

- **Save As / Save a Copy / Save as Template** copy every file the
  samples table names to the same relative path in the new folder (those
  inside first, so their places are theirs); a file from outside the
  folder goes into `Samples/Imported` with a unique name. `cache/` and
  `.autosave/` are not copied.
- **New from template** copies the whole template folder, nested folders
  included, but its `cache/` and `.autosave/`.
- **Saving an unsaved project** moves its folder (rename; copy then remove
  across volumes) and opens it there.

## Older projects

They open as they are: their `samples/` paths are relative and keep
working (old `takes/` held only takes being recorded). New files go to
the new folders; Save As keeps `samples/x.wav` where it is (which folder
of the new three an old file belongs in can't be known). Old `warped/`
and `renders/` are caches: Clean Up offers to remove them. No project-version bump is
needed for the layout; the separator change is read-compatible.

## Cache trimming

Built (`cache_trim`, apps/pads/model/cache.odin). When a project closes
(another opened, a new one, Pads quitting): every rendering it plays now
stays (each warped pad at the project's tempo and every sequence's, each
audio part's comp); of the rest, the newest are kept up to 1 GB
(`CACHE_KEEP_BYTES`: a warp mode or comp undone comes back at once) and
the older go; half-made `.part` files go; an older project's `warped/`
and `renders/` go (nothing names them now). `cache/recording` is left
alone. Deleting `cache/` by hand is always safe: it renders again.

## Clean Up Project

Lists, with sizes: files in `Samples/` the project doesn't use, files
only the undo history uses (kept unless the user ticks them, which clears
that history), and the cache. Moves the chosen ones to the Trash
(macOS `NSFileManager trashItemAtURL`, Windows `SHFileOperationW` with `FOF_ALLOWUNDO`,
Linux the freedesktop Trash in `~/.local/share/Trash`).

## Steps

1. **Takes never overwrite.** Built: fire:record's recorder takes the
   first free `<name>-<n>.wav` (tests/record, tests/pads_model sampling).
2. **`project_paths.odin`** and the new folders for new files. Built;
   paths written with `/`, read either way; a path outside the folder is
   stored absolute (not `../..`).
3. **Copies keep the layout.** Built: Save As, Save a Copy, templates,
   unique names for outside files (tests/pads_model project_paths).
4. **`cache/`** for warps and comps, trimming, not copied. Built
   (tests/pads_model cache_test).
5. **Unsaved folder.** Built (apps/pads/unsaved.odin): `Untitled.pads`,
   `Untitled 2.pads`... in `unsaved_root` (the setting; `Music/Pads/Unsaved`;
   under `--prefs` for tests; the system's temporary folder for a script
   without `--prefs`). Saving moves the folder (copies across disks);
   New, Open, a template or Quit without saving removes it (Quit: once the
   engine has let go of its files). A crash leaves it, and the recovery
   offer brings it back as still unsaved; Discard removes it
   (tests/e2e/test_unsaved.py).
6. **Clean Up Project.** Built: `pm.unused_files` / `pm.clean_up`
   (apps/pads/model/cleanup.odin), `app.move_to_trash` (app/core/trash*.odin:
   NSFileManager, SHFileOperationW with FOF_ALLOWUNDO, the freedesktop
   Trash; `trash_redirect` for tests and `--prefs` runs). Files not in the
   samples table are ticked; samples nothing plays now (pads, synths,
   wavetables, clips, parts, freezes, the Audio tab's clipboard) are
   offered unticked and forget undo; the cache is offered. The project is
   saved after; redo is forgotten either way (an undone import). Where
   names' case doesn't count, `Samples/` and `samples/` are one folder,
   listed once (tests/pads_model cleanup_test, tests/app_core trash tests,
   tests/e2e/test_cleanup.py).
7. **Docs.** Built: this file, pads.md's Projects section.

Each step: model tests (in temp folders), an e2e where there is UI, both
opt levels, the cloud machines for steps 1, 3, 5 and 6 (paths and Trash
differ per OS).

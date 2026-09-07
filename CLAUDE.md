# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Manifest V3 Chrome extension that rewrites the splits table on Garmin Connect pool-swim activity pages, collapsing individual pool lengths into aggregated ~100m splits. It is entirely a DOM-rewriting content script — no API calls, no storage, no UI of its own.

## Commands

```sh
npm run build    # webpack production build -> dist/
npm start        # webpack --mode development --watch
npm run pack     # rebuild garmin100.zip from manifest.json + dist/* + src/assets/*
```

There is no test suite and no linter. Verification is by loading the extension and looking at a real activity page: build, load the extension via `chrome://extensions` → "Load unpacked" (point it at the repo root, since `manifest.json` lives there and references `dist/content.bundle.js`), then open a pool-swim activity on Garmin Connect and check the Splits tab.

`dist/` is gitignored but must exist for both loading the extension and `npm run pack`.

## MCP servers

`.mcp.json` (project-scoped, checked in) configures two servers. Project-scoped servers need approval in the client before they appear in `claude mcp list`.

**`chrome-devtools`** ([chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp)) automates the whole verification loop, which is otherwise the main cost of working on this repo: `install_extension` with the **absolute path to the repo root** replaces "Load unpacked", `reload_extension` picks up a rebuild, then `navigate_page` + `evaluate_script` / `take_snapshot` inspect the patched Splits table, and `list_console_messages` surfaces the `"Started swimming"` log and any thrown errors from the observer.

Three things about that config are deliberate and will break extension debugging if changed:

- **`--category-extensions=true`** — the five `*_extension` tools are off by default.
- **No `--browser-url` / `--autoConnect`.** Extension tools only work over a pipe connection, i.e. when the MCP server launches Chrome itself. Attaching to an already-running Chrome silently drops them (until Chrome 149).
- **No `--isolated`.** The server reuses a persistent profile at `$HOME/.cache/chrome-devtools-mcp/chrome-profile`, which is what lets a Garmin Connect login survive between runs — activity pages need auth, so a throwaway profile means logging in every session. Note the flip side: that profile holds real Garmin credentials, and it is not this repo's `dist/` that gets loaded but whatever absolute path you pass.

`--viewport=1600x1000` is also load-bearing rather than cosmetic: the splits table is wide, and a narrow viewport can reflow or drop columns — which corrupts results silently, because `COLUMN_INDEX` addresses cells by position (see below).

**`lsmcp`** ([@mizchi/lsmcp](https://github.com/mizchi/lsmcp), `-p typescript`) wraps typescript-language-server for hover types, references, and diagnostics. It uses the `typescript` preset rather than the faster `tsgo`, because `tsgo` pulls `@typescript/native-preview` (a `7.0.0-dev` build) and this project is one small file with nothing to gain from it. Its main value is getting type errors without a full webpack build; `npx tsc --noEmit` is the cheaper way to ask the same question.

## Architecture

Everything lives in [content.ts](air-file://3gjccddosou3g12gss3v/Users/denofevil/Code/sandbox/Garmin100/src/content/content.ts?type=file&root=%252F). The pipeline is:

1. **Two table-shape detectors**, one per Garmin Connect UI generation, matching the two `content_scripts` URL patterns in the manifest:
   - `replaceTableRows()` — legacy `/modern/activity/*` markup: `tr.table-row-parent.interval` parent rows with `tr.table-row-child.length.interval-N` children. Groups are scoped by re-querying on the parent's `interval-N` class. Marked with the `patched` attribute.
   - `replaceTabsRow()` — current `/app/activity/*` markup: CSS-module tables matched by `table[class*="IntervalsTable_table"]`. There is no parent/child class link here, so length rows are identified by their interval label matching `/^\d+\.\d+$/` (e.g. `3.2`), and groups are broken whenever the `N` prefix changes. Marked with `data-swim100-patched`.
2. **`patchRowGroup()`** — the shared aggregator both paths call. It writes the group's totals into the *first* row and deletes the rest: sums lengths/time/total strokes, takes min of avg pace and max of max HR, copies the cumulative-time cell's `innerHTML` from the *last* row, and stamps the distance cell with `💯` as the visible marker.
3. **`MutationObserver`** on `document.body` (childList + subtree) re-runs the whole patch on any DOM change, because Garmin Connect is an SPA that renders and re-renders the splits table after the content script has already run.

### Things that will bite you

- **`COLUMN_INDEX` is hardcoded table-column positions.** This is the single most fragile part of the extension — every aggregation reads and writes cells by numeric index. Any column reorder or insertion on Garmin's side silently corrupts the output rather than failing loudly. Commit `a3be507` ("Update for garmin changes") was exactly this kind of breakage.
- **Idempotency comes from the patched attributes and the `💯` sentinel, not from the `patching` flag.** `MutationObserver` callbacks are delivered on a microtask, after `patchSplitTables()` has returned and reset `patching` to `false` — so the flag does *not* prevent the observer from firing on the mutations the patch itself just made. What actually prevents double-aggregation is the per-row patched attribute plus `parseInteger()` deliberately treating `"💯"` (and `"--"`) as `0`. Preserve both invariants when changing this code.
- **The two paths use different patched-attribute names on purpose** (`patched` vs `data-swim100-patched`), and each function only checks its own. Don't unify them without checking both markup generations.
- **`HUNDRED_METERS_THRESHOLD` is 99, not 100**, so that three 33m lengths (yard pools reported in metres) also flush a group. Groups flush on `>=`, so a 25m pool flushes at 4 lengths and a 50m pool at 2.
- **Avg pace for a group is just the group's total time** (`patchRowGroup` passes `totalTime` rounded down to whole seconds), which is correct only because a group is ~100m by construction.
- **Times are handled in tenths of a second** via `timeToTenths()` / `tenthsToTime()`. `timeToTenths` accepts a variable number of `:`-separated segments (folding them left-to-right by 60) so it parses both `1:23.4` and `1:02:03`.

### Dead code and stale docs

- `src/background/background.ts` is boilerplate that is **not registered in `manifest.json`** — there is no service worker entry. Webpack still builds `dist/background.bundle.js`, but nothing loads it.
- `react`, `react-dom`, `redux`, and `react-redux` in `package.json` are unused; the popup they were for was deleted in commit `8e47bff`.
- `README.md` and `README_BUILD.md` are stale scaffolding — they describe a React/Redux popup and a `popup/` directory that no longer exist, and `README_BUILD.md` is truncated mid-sentence. Don't trust them; don't treat the `jsx: "react"` setting in `tsconfig.json` as evidence of React usage.
- `manifest.json` (`0.0.2`) and `package.json` (`1.0.0`) versions are unrelated; the manifest one is what ships.

# Slopdiff

Slopdiff is a personal macOS code-review app for agent-generated changes. Build with Swift Package Manager; package the executable as a native app using `scripts/build-app.sh`. Run `swift test` for domain and Git integration tests.

## Product contract

- Use native AppKit controls and a virtualized continuous side-by-side diff. Render only visible rows; never create one view per changed line across the entire review.
- Support worktree changes since merge-base (committed, staged, unstaged, non-ignored untracked), explicit Git revision comparisons, and GitHub PR URLs.
- GitHub maps repositories to user-selected local checkouts. Never clone automatically, switch branches, mutate working files, or stage content. Fetch missing PR objects without changing local branches.
- Keep production additions/modifications first, alphabetically, and lower-priority files last in a flat sidebar.
- Remember global switches to collapse and auto-review tests, known documentation/non-code, and generated/noise files. Classification is an explicit skip list: unknown extensions and arbitrary text files remain production-priority; `.proto` is code. Deleted/removal-only, binary, and confidently whitespace-only changes collapse and auto-review automatically. Every skipped file remains expandable.
- Fold imports in Kotlin, Java, Go, TypeScript, Rust, and Python with explicit expansion. Imports are not automatically considered safe.
- Syntax highlighting and word-level change emphasis are required. Markdown has a rendered preview.
- A fixed review-and-next action must support repeated clicks without moving. Sidebar navigation scrolls the continuous diff.
- Persist local comments with path, side, line range and diff identity. Export/copy Markdown with a short comparison header and path/range/plain comment text. Do not submit GitHub reviews.
- Preserve review progress for unchanged diffs across launches; changed diffs become unreviewed. Preserve comments even if their diff changes, clearly flagging their stale location.
- Follow system appearance/accent and use Monaspace Neon for source with system monospace fallback. Test the dark appearance.
- Use the Atom One syntax palette; preserve the user's preferred coloring.
- Use one native Liquid Glass toolbar integrated with traffic lights, a compact flat native sidebar, and a consistently tinted glass window. Group related controls with spacing. Do not stack custom toolbars or paint gray rectangles behind file headers, imports, or empty diff cells.
- Keep review chrome minimal: no raw hunk headers, Original/Changed labels, repeated file categories, reviewed counter, load statistics, bottom hint bar, or comparison-title bubble. The copy action is named `Copy review`.
- Finishing a line selection opens a non-modal comment editor automatically. Preserve dirty drafts on save failure and require explicit discard.
- Keep the diff halves exactly equal, with independent visible horizontal scrollbar tracks when their content overflows. A remembered Soft wrap toggle keeps paired rows aligned and preserves original line numbers.
- Working-tree reviews always include staged, unstaged, and non-ignored untracked changes. Do not offer a checkbox to exclude them; an explicit branch target is a different comparison source.
- Quit when the main window closes, including when preview windows are open.

## Engineering

- Keep Git/process work, parsing, and syntax preparation off the main thread. Bound caches and render work. Expose loading and actionable failures.
- Use one domain model and one persistence authority. Write persistence atomically.
- Validate Git refs and paths at the process boundary. Run processes with argument arrays, not interpolated shell scripts. Include stderr in failures.
- Test behavior using real temporary Git repositories, including unusual paths, whitespace-sensitive source, missing refs, ignored/untracked files, binary files, rename/deletion and persistence.
- Verify a release build, actual app screenshots, and a 400-file/30,000-line stress review. Local loading may take up to about two seconds; network PR loading may take about seven seconds. Scrolling after loading must remain fast. Do not present CPU screenshot rasterization or layout timings as frame-rate measurements.
- No publishing CI, website, or README. Keep this file as the contributor contract.

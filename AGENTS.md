# McDiff

McDiff is a personal macOS code-review app for agent-generated changes. Build with Swift Package Manager; package the executable as a native app using `scripts/build-app.sh`. Run `swift test` for domain and Git integration tests.

## Product contract

- Use native AppKit controls and a virtualized continuous diff. Support split and unified layouts, defaulting to split and remembering the choice globally. The toolbar toggle names and depicts the destination layout. Unified source shows deletions before additions, context once, and both old/new line numbers; comments retain their original side and line range. Switching layouts aligns to the header of the file currently in view, including after asynchronous measurement. Render only visible rows; never create one view per changed line across the entire review.
- Support worktree changes since merge-base (committed, staged, unstaged, non-ignored untracked), explicit Git revision comparisons, and GitHub PR URLs.
- GitHub maps repositories to user-selected local checkouts. Never clone automatically, switch branches, mutate working files, or stage content. Fetch missing PR objects without changing local branches.
- Keep production additions/modifications first, alphabetically, and lower-priority files last in a flat sidebar.
- Remember global switches to collapse and auto-review tests, known documentation/non-code, and generated/noise files. Classification is an explicit skip list: unknown extensions and arbitrary text files remain production-priority; `.proto` is code. Deleted/removal-only, binary, and confidently whitespace-only changes collapse and auto-review automatically. Every skipped file remains expandable.
- Markdown is documentation regardless of directory, including test fixtures and generated folders. Changing a skip switch only changes expansion for files whose effective skip status changes; preserve manual expansion elsewhere.
- Fold imports in Kotlin, Java, Go, TypeScript, Rust, and Python with explicit expansion. Imports are not automatically considered safe.
- Syntax highlighting and word-level change emphasis are required. Markdown renders inline by default with a per-file header toggle to source mode for line comments. Split shows both rendered versions; Unified shows only the new rendered version, with source mode available to review deletions. The source/rendered choice lasts for the current review; do not add a global Markdown preference or separate preview window.
- A fixed review-and-next action must support repeated clicks without moving. Sidebar navigation smoothly scrolls the continuous diff, keeping the selected file highlighted during motion. New selections retarget the scroll; direct scrolling or code interaction interrupts it. Layout switching aligns immediately to the selected file header.
- Persist local comments with path, side, line range and diff identity. Export/copy Markdown with a short comparison header and path/range/plain comment text. Do not submit GitHub reviews.
- Preserve review progress for unchanged diffs across launches; changed diffs become unreviewed. Preserve comments even if their diff changes, clearly flagging their stale location.
- Follow system appearance/accent and use Monaspace Neon for source with system monospace fallback. Test the dark appearance.
- Use the Atom One syntax palette; preserve the user's preferred coloring.
- Use one native Liquid Glass toolbar integrated with traffic lights, a compact flat native sidebar, and a consistently tinted glass window. Use system-generated toolbar items in the regular unified style, without custom button views or forced control heights. Group related controls with spacing. File-header hairlines and subtle rounded import highlights provide separation; empty diff cells remain transparent.
- Fresh launches show Home with open pull requests authored by the signed-in user across personal and organization repositories, including drafts, newest creation first. Show title, repository, number, creation age, and draft status with native search. Single-click a row to review; a small chain button shown on hover opens GitHub independently. Local comparisons remain available without sign-in.
- Home hides the review sidebar and review controls. Explicit Home and Resume actions preserve the loaded review and its position; app activation preserves the current screen. Protect unsaved comments when leaving a review.
- Use direct GitHub REST with OAuth device authorization and macOS Keychain credentials, including refresh-token rotation. Do not depend on the gh executable, embed client secrets, or store tokens in preferences. Sign-out clears account-owned Home results.
- The account toolbar button shows a circular GitHub avatar and opens sign-in directly, including when already authenticated. Preserve existing credentials and PR results through cancelled or failed sign-in; replace credentials only after successful authorization and identity lookup.
- Home searches GitHub across matching authored open PRs, not just loaded rows. Paginate results with Previous/Next; query changes return to page one. Do not display loaded-result counters.
- Sign packaged builds with the Respawn Developer ID Application identity to preserve Keychain recognition across updates; do not use ad-hoc signing.
- A single GitHub PR URL dropped on the window or pasted at window level opens through the same comparison flow as Home. Paste within text editors remains text paste. Do not monitor the clipboard or add browser extensions.
- Package and modules are McDiff/McDiffCore; the bundle identity is dev.nek12.mcdiff. Use McDiff storage without reading or migrating Slopdiff data.
- Keep review chrome minimal: no raw hunk headers, Original/Changed labels, repeated file categories, reviewed counter, load statistics, bottom hint bar, or comparison-title bubble. The copy action is named `Copy review`.
- Place compact addition/deletion counts beside the filename. Keep Open and Recents on Home. In reviews, align the toolbar separator with the sidebar: Home/Refresh on the left; Next/Previous/Review-next and a text-free spinner on the right, then flexible space and Search, Wrap, Unified/Split, Comments/Copy/Export.
- Provide text tooltips on buttons and subtle animations for checkbox and state changes. Successful Copy review gives visible, temporary confirmation; repeated clicks restart it. Animate presentation without moving the fixed review action or introducing animated row-height measurement.
- Finishing a selection on actual code opens a non-modal comment editor automatically. Empty diff cells and trailing space do not open it. Saved comments have clickable gutter markers; selecting their range reopens them. Save is explicit; preserve unsaved edits on failure and require explicit discard. Do not add persistent drafts or automatic outside-click saving.
- Keep the split diff halves exactly equal; unified source uses the full width. Horizontal overflow and offsets belong to each file and side independently, controlled by trackpad or Shift-wheel over that side. Do not show horizontal scrollbar controls or reserve a layout strip. Every app-owned scroll view uses overlay scrollbars. A remembered Soft wrap toggle keeps paired rows aligned and preserves original line numbers.
- Expanding/collapsing files or imports and switching Markdown presentation preserve the clicked header's screen position, including asynchronous row measurement.
- Native toolbar search matches paths and displayed old/new text, filters the sidebar by either, highlights matches, and navigates them without changing review state.
- Working-tree reviews always include staged, unstaged, and non-ignored untracked changes. Do not offer a checkbox to exclude them; an explicit branch target is a different comparison source.
- Quit when the main window closes, including when preview windows are open.

## Engineering

- Automated tests must not present visible windows, sheets, popovers, or steal focus. Keep rendering/layout tests offscreen; verify visible interaction manually.

- Keep Git/process work, parsing, and syntax preparation off the main thread. Bound caches and render work. Expose loading and actionable failures.
- Use one domain model and one persistence authority. Write persistence atomically.
- Validate Git refs and paths at the process boundary. Run processes with argument arrays, not interpolated shell scripts. Include stderr in failures.
- Test behavior using real temporary Git repositories, including unusual paths, whitespace-sensitive source, missing refs, ignored/untracked files, binary files, rename/deletion and persistence.
- Verify a release build, actual app screenshots, and a 400-file/30,000-line stress review. Local loading may take up to about two seconds; network PR loading may take about seven seconds. Scrolling after loading must remain fast. Do not present CPU screenshot rasterization or layout timings as frame-rate measurements.
- No publishing CI, website, or README. Keep this file as the contributor contract.

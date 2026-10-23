# Third-party code vendored for Markdown rendering

Markdown files are rendered by `SyntaxHighlightRenderXPC/MarkdownRenderer.swift`
(compiled into the "Syntax Highlight XPC Render" service and `syntax_highlight_cli`).
The C sources below are plain copies (no submodules), compiled directly into those two targets.

## cmark-gfm — `cmark-gfm/`

- Upstream: https://github.com/github/cmark-gfm
- Commit: `27d942c8b0a62d192f616e5bf3578f4b6a89e180` (version 0.29.0.gfm.13), the commit pinned by QLMarkdown.
- Copied: `src/` (without `main.c`, `CMakeLists.txt`, `*.in`), `extensions/` (without `CMakeLists.txt`), `COPYING` (licence).
- `generated/`: `config.h`, `cmark-gfm_export.h`, `cmark-gfm_version.h` as produced by the upstream CMake
  configuration on macOS (copied from QLMarkdown's `cmark-headers` build). They are committed so the
  build needs neither CMake nor the `cmark-headers` legacy target. Regenerate them if cmark-gfm is updated.

## cmark-extra — `cmark-extra/`

- Upstream: https://github.com/sbarex/QLMarkdown (`cmark-extra/`), GPL-3.0 (`LICENSE-QLMarkdown.txt`).
- Commit: `3a0cdcd40c5f53584a2fd9cf9dde6007276b31ce` (Release 1.5.7).
- Copied only the files that are compiled: `c_log.[ch]`, `url.[ch]pp`, `utf8cpp.h`, `utf8/`, `b64.c/`
  (encode/decode/buffer, MIT, `b64.c/LICENSE`), `MIMEtype/` (MIT, `MIMEtype/LICENSE`) and the extensions
  `alert`, `emoji` + `emoji_utils`, `heads` + `heads_utils`, `inlineimage`.
- Local changes:
  - `extensions/heads_utils.cpp`: slugs are built with the std (`iswalnum`) implementation instead of
    pcre2/jpcre2, so SH does not depend on pcre2.
  - `c_log.c`: log subsystem renamed to `com.michaelyu.SourceCodeSyntaxHighlight`.
- SH-specific (not upstream): `extensions/scsh_codeblock.[ch]` — renders fenced code blocks with the
  HTML produced by SH's `highlight`, and registers the extensions used by SH.

## Style — `Application/resources/markdown.css`

- Copy of QLMarkdown `Resources/default.css` at the same commit (`3a0cdcd4`), installed in
  `Contents/Resources/highlight/markdown.css`.

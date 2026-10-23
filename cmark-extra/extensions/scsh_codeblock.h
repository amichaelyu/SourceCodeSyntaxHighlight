//
//  scsh_codeblock.h
//  SourceCodeSyntaxHighlight
//
//  cmark-gfm extension that renders a fenced code block with HTML produced
//  outside of cmark (by SH's `highlight` engine). The Swift side walks the
//  document, highlights each code block and attaches the result to the node
//  with `scsh_codeblock_set_html`. Nodes without attached HTML keep the
//  standard cmark rendering.
//

#ifndef scsh_codeblock_h
#define scsh_codeblock_h

#include "cmark-gfm-extension_api.h"

#ifdef __cplusplus
extern "C" {
#endif

cmark_syntax_extension *create_scsh_codeblock_extension(void);

/// Attach the highlighted `html` (copied) to the code block `node` and bind the node to `extension`.
/// @return 1 on success.
int scsh_codeblock_set_html(cmark_node *node, cmark_syntax_extension *extension, const char *html);

/// Register the extensions used by SourceCodeSyntaxHighlight
/// (cmark-gfm core extensions + emoji, heads, inlineimage, alert, scsh_codeblock).
void scsh_markdown_extensions_ensure_registered(void);

#ifdef __cplusplus
}
#endif

#endif /* scsh_codeblock_h */

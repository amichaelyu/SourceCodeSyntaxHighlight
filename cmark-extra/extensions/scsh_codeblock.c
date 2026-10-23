//
//  scsh_codeblock.c
//  SourceCodeSyntaxHighlight
//
//  See scsh_codeblock.h.
//

#include "scsh_codeblock.h"

#include <stdlib.h>
#include <string.h>

#include "../../cmark-gfm/src/parser.h"
#include "../../cmark-gfm/src/render.h"
#include "../../cmark-gfm/src/html.h"
#include "../../cmark-gfm/src/houdini.h"
#include "../../cmark-gfm/src/registry.h"
#include "../../cmark-gfm/src/plugin.h"
#include "cmark-gfm-core-extensions.h"

#include "emoji.h"
#include "heads.h"
#include "inlineimage.h"
#include "alert.h"

static void free_html(cmark_mem *mem, void *user_data) {
    free(user_data);
}

int scsh_codeblock_set_html(cmark_node *node, cmark_syntax_extension *extension, const char *html) {
    if (node == NULL || extension == NULL || html == NULL || node->type != CMARK_NODE_CODE_BLOCK) {
        return 0;
    }
    char *copy = strdup(html);
    if (copy == NULL) {
        return 0;
    }
    if (node->user_data != NULL && node->user_data_free_func != NULL) {
        node->user_data_free_func(node->content.mem, node->user_data);
    }
    cmark_node_set_user_data(node, copy);
    cmark_node_set_user_data_free_func(node, free_html);
    cmark_node_set_syntax_extension(node, extension);
    return 1;
}

/// Language name: first word of the fence info string.
static size_t language_length(cmark_node *node) {
    size_t len = 0;
    const unsigned char *info = node->as.code.info.data;
    while (len < (size_t)node->as.code.info.len && info[len] != ' ' && info[len] != '\t') {
        len++;
    }
    return len;
}

static void html_render(cmark_syntax_extension *extension,
                        cmark_html_renderer *renderer, cmark_node *node,
                        cmark_event_type ev_type, int options) {
    if (ev_type != CMARK_EVENT_ENTER) {
        return;
    }
    cmark_strbuf *html = renderer->html;
    cmark_html_render_cr(html);
    cmark_strbuf_puts(html, "<pre class=\"hl\"");
    cmark_html_render_sourcepos(node, html, options);
    size_t lang_len = language_length(node);
    if (lang_len > 0) {
        cmark_strbuf_puts(html, " lang=\"");
        houdini_escape_html0(html, node->as.code.info.data, (bufsize_t)lang_len, 0);
        cmark_strbuf_puts(html, "\"><code class=\"language-");
        houdini_escape_html0(html, node->as.code.info.data, (bufsize_t)lang_len, 0);
        cmark_strbuf_puts(html, "\">");
    } else {
        cmark_strbuf_puts(html, "><code>");
    }
    const char *highlighted = (const char *)node->user_data;
    if (highlighted != NULL) {
        cmark_strbuf_puts(html, highlighted);
    } else {
        houdini_escape_html0(html, node->as.code.literal.data, node->as.code.literal.len, 0);
    }
    cmark_strbuf_puts(html, "</code></pre>\n");
}

cmark_syntax_extension *create_scsh_codeblock_extension(void) {
    cmark_syntax_extension *ext = cmark_syntax_extension_new("scsh_codeblock");
    cmark_syntax_extension_set_html_render_func(ext, html_render);
    return ext;
}

static int scsh_extensions_registration(cmark_plugin *plugin) {
    cmark_plugin_register_syntax_extension(plugin, create_inlineimage_extension());
    cmark_plugin_register_syntax_extension(plugin, create_emoji_extension());
    cmark_plugin_register_syntax_extension(plugin, create_heads_extension());
    cmark_plugin_register_syntax_extension(plugin, create_alert_extension());
    cmark_plugin_register_syntax_extension(plugin, create_scsh_codeblock_extension());
    return 1;
}

void scsh_markdown_extensions_ensure_registered(void) {
    static int registered = 0;
    if (!registered) {
        cmark_gfm_core_extensions_ensure_registered();
        cmark_register_plugin(scsh_extensions_registration);
        registered = 1;
    }
}

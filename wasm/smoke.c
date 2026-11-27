/* A program linked against libgraphviz.a, for wasm/smoke.sh: it reads one
 * graph from its standard input, lays it out with the dot engine and writes
 * it in the plain format, after a first line naming the Graphviz it is. */
#include <stdio.h>
#include <stdlib.h>

#include "gvc.h"
#include "gvplugin.h"

extern gvplugin_library_t gvplugin_dot_layout_LTX_library;
extern gvplugin_library_t gvplugin_neato_layout_LTX_library;
extern gvplugin_library_t gvplugin_core_LTX_library;

/* The library registers no plugin itself: the program names the built-in
 * ones. */
static lt_symlist_t builtins[] = {
    {"gvplugin_dot_layout_LTX_library", &gvplugin_dot_layout_LTX_library},
    {"gvplugin_neato_layout_LTX_library", &gvplugin_neato_layout_LTX_library},
    {"gvplugin_core_LTX_library", &gvplugin_core_LTX_library},
    {0, 0},
};

int main(void) {
  GVC_t *gvc = gvContextPlugins(builtins, 0);
  if (gvc == NULL) {
    fputs("no context\n", stderr);
    return 1;
  }
  printf("graphviz %s\n", gvcVersion(gvc));
  Agraph_t *graph = agread(stdin, NULL);
  if (graph == NULL) {
    fputs("no graph read\n", stderr);
    return 1;
  }
  if (gvLayout(gvc, graph, "dot") != 0) {
    fputs("no layout\n", stderr);
    return 1;
  }
  if (gvRender(gvc, graph, "plain", stdout) != 0) {
    fputs("no render\n", stderr);
    return 1;
  }
  gvFreeLayout(gvc, graph);
  agclose(graph);
  return gvFreeContext(gvc);
}

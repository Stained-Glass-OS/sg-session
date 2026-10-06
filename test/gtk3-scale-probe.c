/* hidpi-ui-e2e's Linux program: a GTK 3 window with a line of text, at its
 * natural size; GTK through dlopen (no development headers needed) */
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv)
{
    void *g = dlopen("libgtk-3.so.0", RTLD_NOW);
    if (!g) { fprintf(stderr, "no GTK 3\n"); return 77; }
    void (*init)(int *, char ***) = dlsym(g, "gtk_init");
    void *(*window_new)(int) = dlsym(g, "gtk_window_new");
    void *(*label_new)(const char *) = dlsym(g, "gtk_label_new");
    void (*add)(void *, void *) = dlsym(g, "gtk_container_add");
    void (*title)(void *, const char *) = dlsym(g, "gtk_window_set_title");
    void (*show)(void *) = dlsym(g, "gtk_widget_show_all");
    void (*run)(void) = dlsym(g, "gtk_main");
    void *w;
    init(&argc, &argv);
    w = window_new(0);
    title(w, "sg-gtk3-probe");
    add(w, label_new("Stained Glass OS: the quick brown fox jumps over the lazy dog"));
    show(w);
    run();
    return 0;
}

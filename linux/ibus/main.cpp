// The IBus engine's process. ibus-daemon starts it with --ibus, as the
// component file says (ime-jd.xml); run without it, it registers that
// component itself, which is how to try a build without installing it.
#include <cstring>
#include <string>

#include <glib-unix.h>
#include <ibus.h>

#include "engine.h"
#include "ibus_engine.h"
#include "project.h"
#include "user_dict.h"

namespace {

constexpr const char *kComponentName = "io.github.hronro.ImeJd";
constexpr const char *kEngineName = "ime-jd";
/// How long a burst of file events settles before the store reloads: one
/// save is several of them.
constexpr guint kReloadDelayMs = 300;

imejd::UserDictStore *g_store = nullptr;
guint g_reloadSource = 0;

/// Tells the desktop's notification service, which is how a failed rebuild
/// after a text-editor save gets seen.
void notify(const std::string &title, const std::string &body) {
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    if (!bus) {
        return;
    }
    GVariantBuilder actions;
    g_variant_builder_init(&actions, G_VARIANT_TYPE("as"));
    GVariantBuilder hints;
    g_variant_builder_init(&hints, G_VARIANT_TYPE("a{sv}"));
    g_dbus_connection_call(bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                           "org.freedesktop.Notifications", "Notify",
                           g_variant_new("(susssasa{sv}i)", "键道", 0u, IMEJD_ICON, title.c_str(), body.c_str(),
                                         &actions, &hints, -1),
                           nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr, nullptr);
    g_object_unref(bus);
}

gboolean reloadStore(gpointer) {
    g_reloadSource = 0;
    g_store->reload();
    return G_SOURCE_REMOVE;
}

gboolean onWatch(gint, GIOCondition, gpointer) {
    if (g_store->drainWatch()) {
        if (g_reloadSource) {
            g_source_remove(g_reloadSource);
        }
        g_reloadSource = g_timeout_add(kReloadDelayMs, reloadStore, nullptr);
    }
    return G_SOURCE_CONTINUE;
}

/// What the component file says, for a run outside ibus-daemon.
IBusComponent *component(const char *exec) {
    IBusComponent *component = ibus_component_new_varargs(
        "name", kComponentName, "description", "键道输入法", "version", imejd::kVersion, "license",
        "GPL-3.0", "author", "hronro", "homepage", "https://github.com/hronro/ime-jd", "exec", exec,
        "textdomain", "ime-jd", nullptr);
    ibus_component_add_engine(
        component, ibus_engine_desc_new_varargs("name", kEngineName, "longname", "键道", "description",
                                                "键道输入法", "language", "zh_CN", "license", "GPL-3.0",
                                                "author", "hronro", "icon", IMEJD_ICON, "layout", "default",
                                                "symbol", "中", "icon-prop-key", imejd::kInputModeProperty,
                                                "rank", 0, nullptr));
    return component;
}

} // namespace

int main(int argc, char **argv) {
    bool launchedByIBus = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--ibus") == 0 || std::strcmp(argv[i], "-i") == 0) {
            launchedByIBus = true;
        } else if (std::strcmp(argv[i], "--version") == 0) {
            g_print("%s\n", imejd::kVersion);
            return 0;
        }
    }

    if (!imejd::Engine::abiMatches()) {
        g_printerr("键道: jd.h does not match the libjd linked in\n");
        return 1;
    }

    ibus_init();
    IBusBus *bus = ibus_bus_new();
    if (!ibus_bus_is_connected(bus)) {
        g_printerr("键道: cannot connect to IBus\n");
        return 1;
    }
    g_signal_connect(bus, "disconnected", G_CALLBACK(+[](IBusBus *, gpointer) { ibus_quit(); }), nullptr);

    imejd::UserDictStore store(imejd::UserDictStore::defaultDirectory(), notify);
    g_store = &store;
    if (store.watchFd() >= 0) {
        g_unix_fd_add(store.watchFd(), G_IO_IN, onWatch, nullptr);
    }
    imejd_ibus_engine_set_store(&store);

    IBusFactory *factory = ibus_factory_new(ibus_bus_get_connection(bus));
    ibus_factory_add_engine(factory, kEngineName, IMEJD_TYPE_IBUS_ENGINE);
    if (launchedByIBus) {
        ibus_bus_request_name(bus, kComponentName, 0);
    } else {
        ibus_bus_register_component(bus, component(argv[0]));
    }

    ibus_main();
    return 0;
}

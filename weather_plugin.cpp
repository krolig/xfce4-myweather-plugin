#include <libxfce4panel/libxfce4panel.h>
#include <gtk/gtk.h>
#include <curl/curl.h>
#include <nlohmann/json.hpp>

#include <string>
#include <vector>
#include <map>
#include <fstream>
#include <cstdlib>
#include <cmath>
#include <thread>
#include <stdexcept>

using json = nlohmann::json;


struct Config {
    std::string lat = "53.22109";
    std::string lon = "44.91199";
    std::string timezone = "Europe%2FMoscow";
    std::string font_desc = "Tahoma 10";
    std::string panel_font = "Tahoma 8";
    std::string panel_color = "#000000";
    int max_tooltip_px = 423;
    int update_interval = 1800;
    int offset_x = 0;
    int offset_y = -3;
};

static Config load_config() {
    Config cfg;
    std::string sys_path = "/etc/xdg/myweather.conf";
    std::string user_path;

    const char* home = std::getenv("HOME");
    if (home) {
        user_path = std::string(home) + "/.config/myweather.conf";
        std::ifstream test_user(user_path);
        if (!test_user.good()) {
            std::ifstream src(sys_path, std::ios::binary);
            if (src.good()) {
                g_mkdir_with_parents((std::string(home) + "/.config").c_str(), 0755);
                std::ofstream dst(user_path, std::ios::binary);
                dst << src.rdbuf();
            }
        }
    }

    std::ifstream f(!user_path.empty() ? user_path : sys_path);
    if (!f.is_open()) f.open(sys_path);

    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line.front() == '#') continue;
        auto pos = line.find('=');
        if (pos == std::string::npos) continue;
        std::string key = line.substr(0, pos);
        std::string val = line.substr(pos + 1);

        if (key == "lat") cfg.lat = val;
        else if (key == "lon") cfg.lon = val;
        else if (key == "timezone") cfg.timezone = val;
        else if (key == "font_desc") cfg.font_desc = val;
        else if (key == "panel_font") cfg.panel_font = val;
        else if (key == "panel_color") cfg.panel_color = val;
        else if (key == "max_tooltip_px") cfg.max_tooltip_px = std::stoi(val);
        else if (key == "update_interval") cfg.update_interval = std::stoi(val);
        else if (key == "offset_x") cfg.offset_x = std::stoi(val);
        else if (key == "offset_y") cfg.offset_y = std::stoi(val);
    }
    return cfg;
}



struct WeatherPlugin {
    XfcePanelPlugin* plugin;
    GtkWidget* button;
    GtkWidget* panel_label;
    GtkWidget* popup_win;
    GtkWidget* popup_label;
    bool alive = true;
};

static size_t write_callback(void* contents, size_t size, size_t nmemb, std::string* s) {
    size_t newLength = size * nmemb;
    s->append(static_cast<char*>(contents), newLength);
    return newLength;
}

static std::string http_get(const std::string& url) {
    CURL* curl = curl_easy_init();
    std::string response;
    if (curl) {
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "Mozilla/5.0 (X11; Linux x86_64) WeatherPlugin/1.0");
        CURLcode res = curl_easy_perform(curl);
        curl_easy_cleanup(curl);
        if (res != CURLE_OK) throw std::runtime_error(curl_easy_strerror(res));
    }
    return response;
}

static int get_px(PangoLayout* layout, const std::string& markup) {
    pango_layout_set_markup(layout, markup.c_str(), -1);
    int w = 0, h = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    return w;
}

static std::string fit_px(PangoLayout* layout, const std::string& text, int target_w, const std::string& color = "", const std::string& align = "center") {
    std::string body = color.empty() ? text : "<span foreground=\"" + color + "\">" + text + "</span>";
    int cur_w = get_px(layout, body);
    if (cur_w >= target_w) return body;

    const std::vector<std::string> sp_units = {" ", "\u2009", "\u200a"};
    auto build_pad = [&](int needed_px) -> std::string {
        if (needed_px <= 0) return "";
        std::string s = "";
        while (get_px(layout, s) < needed_px) {
            bool added = false;
            for (const auto& u : sp_units) {
                if (get_px(layout, s + u) <= needed_px) {
                    s += u;
                    added = true;
                    break;
                }
            }
            if (!added) break;
        }
        return s;
    };

    int diff = target_w - cur_w;
    if (align == "left") return body + build_pad(diff);

    int left_w = diff / 2;
    std::string l_pad = build_pad(left_w);
    std::string r_pad = build_pad(target_w - get_px(layout, l_pad + body));
    return l_pad + body + r_pad;
}

static std::pair<std::string, std::string> fetch_weather_markup(const Config& cfg) {
    static const std::map<int, std::string> icons = {
        {0,"☀️"}, {1,"🌤️"}, {2,"⛅"}, {3,"☁️"}, {45,"🌫️"}, {48,"🌫️"},
        {51,"🌦️"}, {53,"🌦️"}, {55,"🌧️"}, {61,"🌧️"}, {63,"🌧️"}, {65,"🌧️"},
        {71,"🌨️"}, {73,"🌨️"}, {75,"❄️"}, {77,"❄️"}, {80,"🌦️"}, {81,"🌧️"},
        {82,"⛈️"}, {85,"🌨️"}, {86,"❄️"}, {95,"⛈️"}, {96,"⛈️"}, {99,"⛈️"}
    };

    static const std::map<int, std::pair<std::string, std::string>> desc = {
        {0, {"Ясно", "#d97706"}}, {1, {"Ясно", "#d97706"}},
        {2, {"Обл.", "#4b5563"}}, {3, {"Пасм", "#374151"}},
        {45, {"Тумн", "#6b7280"}}, {48, {"Тумн", "#6b7280"}},
        {51, {"Морс", "#2563eb"}}, {53, {"Морс", "#2563eb"}}, {55, {"Морс", "#2563eb"}},
        {61, {"Дожд", "#1d4ed8"}}, {63, {"Дожд", "#1d4ed8"}}, {65, {"Ливн", "#1e40af"}},
        {71, {"Снег", "#0284c7"}}, {73, {"Снег", "#0284c7"}}, {75, {"Снег", "#0284c7"}}, {77, {"Снег", "#0284c7"}},
        {80, {"Ливн", "#1e40af"}}, {81, {"Ливн", "#1e40af"}}, {82, {"Ливн", "#1e40af"}},
        {85, {"Снег", "#0284c7"}}, {86, {"Снег", "#0284c7"}},
        {95, {"Гроз", "#7c3aed"}}, {96, {"Гроз", "#7c3aed"}}, {99, {"Гроз", "#7c3aed"}}
    };

    auto clean_zero = [](double val) -> double {
        int r = static_cast<int>(std::lround(val));
        return (r == 0) ? 0.0 : static_cast<double>(r);
    };

    auto t_col = [](double r_val) -> std::string {
        return r_val > 0.0 ? "#dc2626" : (r_val < 0.0 ? "#2563eb" : "#374151");
    };

    std::string host = "https://";
    host += "api.";
    host += "open-meteo.";
    host += "com";
    std::string url = host + "/v1/forecast?latitude=" + cfg.lat +
                      "&longitude=" + cfg.lon +
                      "&current_weather=true&daily=weathercode,temperature_2m_max,temperature_2m_min,precipitation_sum,windspeed_10m_max&windspeed_unit=ms&timezone=" +
                      cfg.timezone + "&forecast_days=7";

    std::string raw_json = http_get(url);
    json data = json::parse(raw_json);

    int wcode = 0;
    double temp = 0.0;
    data.at("current_weather").at("weathercode").get_to(wcode);
    data.at("current_weather").at("temperature").get_to(temp);
    temp = clean_zero(temp);
    std::string now_ico = icons.count(wcode) ? icons.at(wcode) : "🌡️";

    char panel_buf[64];
    if (temp == 0.0) snprintf(panel_buf, sizeof(panel_buf), "%s 0°C", now_ico.c_str());
    else snprintf(panel_buf, sizeof(panel_buf), "%s %+.0f°C", now_ico.c_str(), temp);

    std::string panel_markup = "<span font=\"" + cfg.panel_font + "\" foreground=\"" + cfg.panel_color + "\">" +
                               std::string(panel_buf) + "</span>";

    struct Cell { std::string text; std::string color; };
    using Row = std::pair<std::string, std::vector<Cell>>;
    std::vector<Row> rows(6);
    rows[0].first = "Дата";
    rows[1].first = "Погода";
    rows[2].first = "Максимум";
    rows[3].first = "Минимум";
    rows[4].first = "Осадки";
    rows[5].first = "Ветер";

    const auto& d = data.at("daily");
    size_t days = d.at("time").size();

    for (size_t i = 0; i < days; ++i) {
        std::string dt;
        d.at("time").at(i).get_to(dt);
        rows[0].second.push_back({dt.substr(8, 2) + "." + dt.substr(5, 2), ""});

        int code = 0;
        d.at("weathercode").at(i).get_to(code);
        if (desc.count(code)) rows[1].second.push_back({desc.at(code).first, desc.at(code).second});
        else rows[1].second.push_back({"----", "#000000"});

        char buf[32];
        double tmax = 0.0, tmin = 0.0, prec = 0.0, wind = 0.0;

        d.at("temperature_2m_max").at(i).get_to(tmax);
        tmax = clean_zero(tmax);
        if (tmax == 0.0) snprintf(buf, sizeof(buf), "0°");
        else snprintf(buf, sizeof(buf), "%+.0f°", tmax);
        rows[2].second.push_back({buf, t_col(tmax)});

        d.at("temperature_2m_min").at(i).get_to(tmin);
        tmin = clean_zero(tmin);
        if (tmin == 0.0) snprintf(buf, sizeof(buf), "0°");
        else snprintf(buf, sizeof(buf), "%+.0f°", tmin);
        rows[3].second.push_back({buf, t_col(tmin)});

        d.at("precipitation_sum").at(i).get_to(prec);
        snprintf(buf, sizeof(buf), "%.1fмм", prec);
        rows[4].second.push_back({buf, prec > 0 ? "#0284c7" : ""});

        d.at("windspeed_10m_max").at(i).get_to(wind);
        snprintf(buf, sizeof(buf), "%.0fм/с", std::round(wind));
        rows[5].second.push_back({buf, ""});
    }
    cairo_surface_t* surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    cairo_t* ctx = cairo_create(surf);
    PangoLayout* layout = pango_cairo_create_layout(ctx);
    PangoFontDescription* fdesc = pango_font_description_from_string(cfg.font_desc.c_str());
    pango_layout_set_font_description(layout, fdesc);

    int base_label_w = 0;
    for (const auto& r : rows) base_label_w = std::max(base_label_w, get_px(layout, r.first));

    std::vector<int> base_col_w(days, 0);
    for (const auto& r : rows) {
        for (size_t i = 0; i < days; ++i) {
            base_col_w[i] = std::max(base_col_w[i], get_px(layout, r.second[i].text));
        }
    }

    const std::string BAR = "<span foreground=\"#888888\">|</span>";
    int bar_w = get_px(layout, BAR);
    int pad_lbl = 5;
    int pad_col = 0;

    for (int test_pad = 18; test_pad >= 0; --test_pad) {
        int total_w = (base_label_w + pad_lbl) + bar_w * static_cast<int>(days);
        for (int w : base_col_w) total_w += (w + test_pad);
        if (total_w <= cfg.max_tooltip_px) {
            pad_col = test_pad;
            break;
        }
    }

    int label_w = base_label_w + pad_lbl;
    std::string popup_markup = "<span font=\"" + cfg.font_desc + "\">";
    for (size_t r_idx = 0; r_idx < rows.size(); ++r_idx) {
        const auto& r = rows[r_idx];
        std::string line = fit_px(layout, r.first, label_w, "", "left") + BAR;
        for (size_t i = 0; i < days; ++i) {
            line += fit_px(layout, r.second[i].text, base_col_w[i] + pad_col, r.second[i].color, "center");
            if (i + 1 < days) line += BAR;
        }
        popup_markup += line + (r_idx + 1 < rows.size() ? "\n" : "");
    }
    popup_markup += "</span>";

    pango_font_description_free(fdesc);
    g_object_unref(layout);
    cairo_destroy(ctx);
    cairo_surface_destroy(surf);

    return {panel_markup, popup_markup};
}

static gboolean update_weather_timer(gpointer user_data) {
    auto* wp = static_cast<WeatherPlugin*>(user_data);
    Config cfg = load_config();

    std::thread([wp, cfg]() {
        std::string panel_str, popup_str;
        try {
            auto res = fetch_weather_markup(cfg);
            panel_str = res.first;
            popup_str = res.second;
        } catch (const std::exception& e) {
            panel_str = "<span font=\"" + cfg.panel_font + "\" foreground=\"" + cfg.panel_color + "\">Нет сети</span>";
            popup_str = "<span font=\"" + cfg.font_desc + "\">Ошибка: " + std::string(e.what()) + "</span>";
        }

        struct UIUpdate { WeatherPlugin* wp; std::string p; std::string pop; };
        auto* upd = new UIUpdate{wp, panel_str, popup_str};

        g_idle_add([](gpointer data) -> gboolean {
            auto* u = static_cast<UIUpdate*>(data);
            if (u->wp->alive) {
                gtk_label_set_markup(GTK_LABEL(u->wp->panel_label), u->p.c_str());
                gtk_label_set_markup(GTK_LABEL(u->wp->popup_label), u->pop.c_str());
            }
            delete u;
            return G_SOURCE_REMOVE;
        }, upd);
    }).detach();

    return G_SOURCE_CONTINUE;
}


static void on_button_clicked(GtkButton*, gpointer user_data) {
    auto* wp = static_cast<WeatherPlugin*>(user_data);
    if (gtk_widget_get_visible(wp->popup_win)) {
        gtk_widget_hide(wp->popup_win);
    } else {
        Config cfg = load_config();
        gtk_widget_show_all(wp->popup_win);
        gint x, y;
        xfce_panel_plugin_position_widget(wp->plugin, wp->popup_win, wp->button, &x, &y);
        gtk_window_move(GTK_WINDOW(wp->popup_win), x + cfg.offset_x, y + cfg.offset_y);
        gtk_window_present(GTK_WINDOW(wp->popup_win));
    }
}



extern "C" void construct(XfcePanelPlugin* plugin) {
    auto* wp = new WeatherPlugin();
    wp->plugin = plugin;
    Config cfg = load_config();

    GtkCssProvider* provider = gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider, "#weather-popup-lbl { padding: 8px 10px; }", -1, nullptr);
    gtk_style_context_add_provider_for_screen(
        gdk_screen_get_default(), GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
    );
    g_object_unref(provider);


    wp->button = xfce_panel_create_button();
    gtk_widget_set_can_focus(wp->button, FALSE);
    wp->panel_label = gtk_label_new("...");
    gtk_container_add(GTK_CONTAINER(wp->button), wp->panel_label);
    gtk_container_add(GTK_CONTAINER(plugin), wp->button);
    gtk_widget_show_all(wp->button);


    wp->popup_win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_decorated(GTK_WINDOW(wp->popup_win), FALSE);
    gtk_window_set_skip_taskbar_hint(GTK_WINDOW(wp->popup_win), TRUE);
    gtk_window_set_keep_above(GTK_WINDOW(wp->popup_win), TRUE);

    wp->popup_label = gtk_label_new("Загрузка...");
    gtk_widget_set_name(wp->popup_label, "weather-popup-lbl");
    gtk_container_add(GTK_CONTAINER(wp->popup_win), wp->popup_label);

    g_signal_connect(wp->popup_win, "button-press-event", G_CALLBACK(+[](GtkWidget* w, GdkEventButton*, gpointer) -> gboolean {
        gtk_widget_hide(w); return TRUE;
    }), nullptr);
    g_signal_connect(wp->popup_win, "key-press-event", G_CALLBACK(+[](GtkWidget* w, GdkEventKey* ev, gpointer) -> gboolean {
        if (ev->keyval == GDK_KEY_Escape) { gtk_widget_hide(w); return TRUE; }
        return FALSE;
    }), nullptr);


    g_signal_connect(wp->popup_win, "focus-out-event", G_CALLBACK(+[](GtkWidget* w, GdkEventFocus*, gpointer) -> gboolean {
        GdkModifierType mods = static_cast<GdkModifierType>(0);
        GdkDisplay* display = gtk_widget_get_display(w);
        GdkSeat* seat = gdk_display_get_default_seat(display);
        GdkDevice* pointer = gdk_seat_get_pointer(seat);

        if (pointer && gtk_widget_get_window(w)) {
            gdk_window_get_device_position(gtk_widget_get_window(w), pointer, nullptr, nullptr, &mods);
        }

        // Проверяем модификаторы (Alt = GDK_MOD1_MASK, Ctrl, Super)
        if (mods & (GDK_MOD1_MASK | GDK_CONTROL_MASK | GDK_SUPER_MASK)) {
            return FALSE;
        }

        gtk_widget_hide(w);
        return FALSE;
    }), nullptr);



    g_signal_connect(wp->button, "clicked", G_CALLBACK(on_button_clicked), wp);

    // Пункт меню "Обновить погоду"
    GtkWidget* refresh_item = gtk_menu_item_new_with_label("Обновить погоду");
    gtk_widget_show(refresh_item);
    xfce_panel_plugin_menu_insert_item(plugin, GTK_MENU_ITEM(refresh_item));
    g_signal_connect(refresh_item, "activate", G_CALLBACK(+[](GtkMenuItem*, gpointer data) {
        update_weather_timer(data);
    }), wp);

    // Пункт меню "Открыть настройки"
    GtkWidget* settings_item = gtk_menu_item_new_with_label("Открыть настройки");
    gtk_widget_show(settings_item);
    xfce_panel_plugin_menu_insert_item(plugin, GTK_MENU_ITEM(settings_item));
    g_signal_connect(settings_item, "activate", G_CALLBACK(+[](GtkMenuItem*, gpointer) {
        load_config();
        const char* home = std::getenv("HOME");
        if (home) {
            std::string path = std::string(home) + "/.config/myweather.conf";
            std::string uri = "file://" + path;
            if (!g_app_info_launch_default_for_uri(uri.c_str(), nullptr, nullptr)) {
                g_spawn_command_line_async(("mousepad \"" + path + "\"").c_str(), nullptr);
            }
        }
    }), nullptr);

    // Автообновление при сохранении ~/.config/myweather.conf
    GFileMonitor* monitor = nullptr;
    const char* home = std::getenv("HOME");
    if (home) {
        std::string cfg_path = std::string(home) + "/.config/myweather.conf";
        GFile* gfile = g_file_new_for_path(cfg_path.c_str());
        monitor = g_file_monitor_file(gfile, G_FILE_MONITOR_NONE, nullptr, nullptr);
        if (monitor) {
            g_signal_connect(monitor, "changed", G_CALLBACK(+[](GFileMonitor*, GFile*, GFile*, GFileMonitorEvent ev, gpointer data) {
                if (ev == G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT || ev == G_FILE_MONITOR_EVENT_CREATED) {
                    update_weather_timer(data);
                }
            }), wp);
        }
        g_object_unref(gfile);
    }

    g_signal_connect(plugin, "free-data", G_CALLBACK(+[](XfcePanelPlugin*, WeatherPlugin* p) {
        p->alive = false;
        gtk_widget_destroy(p->popup_win);
        delete p;
    }), wp);

    if (monitor) {
        g_signal_connect_swapped(plugin, "free-data", G_CALLBACK(g_object_unref), monitor);
    }

    update_weather_timer(wp);
    g_timeout_add_seconds(cfg.update_interval, update_weather_timer, wp);
}


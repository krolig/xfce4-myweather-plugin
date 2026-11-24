CC = gcc
CXX = g++
CFLAGS = -fPIC -O2 -Wall -Wextra $(shell pkg-config --cflags libxfce4panel-2.0 gtk+-3.0 2>/dev/null)
CXXFLAGS = -fPIC -O2 -Wall -Wextra -std=c++17 $(shell pkg-config --cflags libxfce4panel-2.0 gtk+-3.0 libcurl nlohmann_json 2>/dev/null)
LDFLAGS = -shared $(shell pkg-config --libs libxfce4panel-2.0 gtk+-3.0 libcurl 2>/dev/null)

TARGET = libmyweather.so
OBJS = register.o weather_plugin.o

PKG_NAME = xfce4-myweather-plugin
PKG_VER = 1.0.0
ARCH = $(shell dpkg --print-architecture 2>/dev/null || echo amd64)
DEB_DIR = build_deb
DEB_FILE = $(PKG_NAME)_$(PKG_VER)_$(ARCH).deb

LIBDIR := $(shell pkg-config --variable=libdir libxfce4panel-2.0 2>/dev/null)
ifeq ($(LIBDIR),)
	LIBDIR := /usr/lib/$(shell dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)
endif

PLUGIN_DIR = $(LIBDIR)/xfce4/panel/plugins
DESKTOP_DIR = /usr/share/xfce4/panel/plugins
DESKTOP_FILE = myweather.desktop
SYS_CONF_DIR = /etc/xdg
SYS_CONF_FILE = $(SYS_CONF_DIR)/myweather.conf

all: check_deps $(TARGET)

check_deps:
	@pkg-config --exists libxfce4panel-2.0 gtk+-3.0 libcurl nlohmann_json || { \
		echo "Ошибка: не найдены dev-пакеты! Запустите: make deps"; \
		exit 1; \
	}

deps:
	@if command -v apt-get >/dev/null 2>&1; then \
		CURL_PKG=""; \
		pkg-config --exists libcurl || CURL_PKG="libcurl4-openssl-dev"; \
		sudo apt-get update && sudo apt-get install -y g++ make pkg-config dpkg-dev libxfce4panel-2.0-dev libgtk-3-dev $$CURL_PKG nlohmann-json3-dev; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -S --needed base-devel gtk3 curl xfce4-panel nlohmann-json; \
	elif command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y gcc-c++ make pkgconfig gtk3-devel xfce4-panel-devel libcurl-devel json-devel; \
	else \
		echo "Установите вручную: g++, make, pkg-config, gtk3-devel, xfce4-panel-devel, libcurl-devel, nlohmann-json"; \
	fi

$(OBJS): | check_deps

$(TARGET): $(OBJS)
	$(CXX) $(OBJS) -o $@ $(LDFLAGS)

register.o: register.c
	$(CC) $(CFLAGS) -c $< -o $@

weather_plugin.o: weather_plugin.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

deb: check_deps $(TARGET)
	rm -rf $(DEB_DIR)
	mkdir -p $(DEB_DIR)/DEBIAN
	mkdir -p $(DEB_DIR)$(PLUGIN_DIR)
	mkdir -p $(DEB_DIR)$(DESKTOP_DIR)
	mkdir -p $(DEB_DIR)$(SYS_CONF_DIR)
	cp $(TARGET) $(DEB_DIR)$(PLUGIN_DIR)/
	@printf "[Xfce Panel]\nType=X-XFCE-PanelPlugin\nName=Погода (Open-Meteo)\nComment=Прогноз погоды на 7 дней\nIcon=weather-clear\nX-XFCE-Module=myweather\nX-XFCE-Internal=FALSE\nX-XFCE-API=2.0\n" > $(DEB_DIR)$(DESKTOP_DIR)/$(DESKTOP_FILE)
	@printf "lat=53.13\nlon=45.0\ntimezone=Europe%%2FMoscow\nfont_desc=Tahoma 10\npanel_font=Tahoma 8\npanel_color=#000000\nmax_tooltip_px=423\nupdate_interval=1800\noffset_x=0\noffset_y=-3\n" > $(DEB_DIR)$(SYS_CONF_FILE)
	@printf "$(SYS_CONF_FILE)\n" > $(DEB_DIR)/DEBIAN/conffiles
	@printf "Package: $(PKG_NAME)\nVersion: $(PKG_VER)\nSection: xfce\nPriority: optional\nArchitecture: $(ARCH)\nDepends: xfce4-panel, libgtk-3-0 | libgtk-3-0t64, libcurl4 | libcurl4t64\nMaintainer: User <user@localhost>\nDescription: Xfce4 panel weather plugin using Open-Meteo API\n" > $(DEB_DIR)/DEBIAN/control
	@printf "#!/bin/sh\npkill -f 'wrapper-2.0.*myweather' || true\n" > $(DEB_DIR)/DEBIAN/prerm
	@chmod 0755 $(DEB_DIR)/DEBIAN/prerm
	dpkg-deb --build --root-owner-group $(DEB_DIR) $(DEB_FILE)
	rm -rf $(DEB_DIR)
	@echo "Готово: $(DEB_FILE)"

install: check_deps $(TARGET)
	sudo mkdir -p $(PLUGIN_DIR) $(DESKTOP_DIR) $(SYS_CONF_DIR)
	sudo cp $(TARGET) $(PLUGIN_DIR)/
	@printf "[Xfce Panel]\nType=X-XFCE-PanelPlugin\nName=Погода (Open-Meteo)\nComment=Прогноз погоды на 7 дней\nIcon=weather-clear\nX-XFCE-Module=myweather\nX-XFCE-Internal=FALSE\nX-XFCE-API=2.0\n" | sudo tee $(DESKTOP_DIR)/$(DESKTOP_FILE) > /dev/null
	@if [ ! -f "$(SYS_CONF_FILE)" ]; then \
		printf "lat=53.13\nlon=45.0\ntimezone=Europe%%2FMoscow\nfont_desc=Tahoma 10\npanel_font=Tahoma 8\npanel_color=#000000\nmax_tooltip_px=423\nupdate_interval=1800\noffset_x=0\noffset_y=-3\n" | sudo tee $(SYS_CONF_FILE) > /dev/null; \
	fi

uninstall:
	sudo rm -f $(PLUGIN_DIR)/$(TARGET) $(DESKTOP_DIR)/$(DESKTOP_FILE)
	@echo "Примечание: конфигурационный файл $(SYS_CONF_FILE) сохранен. Для полного удаления выполните: make purge"

purge: uninstall
	sudo rm -f $(SYS_CONF_FILE)

clean:
	rm -rf $(OBJS) $(TARGET) $(DEB_DIR) *.deb

.PHONY: all check_deps deps deb install uninstall purge clean


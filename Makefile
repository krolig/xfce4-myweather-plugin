CC = gcc
CXX = g++
CFLAGS = -fPIC -O2 -Wall -Wextra $(shell pkg-config --cflags libxfce4panel-2.0 gtk+-3.0 2>/dev/null)
CXXFLAGS = -fPIC -O2 -Wall -Wextra -std=c++17 $(shell pkg-config --cflags libxfce4panel-2.0 gtk+-3.0 libcurl nlohmann_json 2>/dev/null)
LDFLAGS = -shared $(shell pkg-config --libs libxfce4panel-2.0 gtk+-3.0 libcurl 2>/dev/null)

TARGET = libmyweather.so
OBJS = register.o weather_plugin.o
FONT_FILES = $(wildcard fonts/*.ttf fonts/*.TTF)
SRC_FILES = Makefile register.c weather_plugin.cpp $(wildcard *.h *.hpp) $(FONT_FILES)

PKG_NAME = xfce4-myweather-plugin
GIT_TAG := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
PKG_VER ?= $(if $(GIT_TAG),$(GIT_TAG),1.0.0)
PKG_REL = 1

# Суффикс дистрибутива (например, .el7 / .red8, если определен в системе)
DIST_TAG := $(shell rpm --eval '%{?dist}' 2>/dev/null)

# Архитектура для DEB
DEB_ARCH = $(shell dpkg --print-architecture 2>/dev/null || echo amd64)
DEB_DIR = build_deb
DEB_FILE = $(PKG_NAME)_$(PKG_VER)_$(DEB_ARCH).deb

# Архитектура и пути для RPM / SRPM
RPM_ARCH = $(shell uname -m)
RPM_DIR = $(abspath build_rpm)
RPM_SPEC = $(RPM_DIR)/SPECS/$(PKG_NAME).spec
RPM_FILE = $(PKG_NAME)-$(PKG_VER)-$(PKG_REL)$(DIST_TAG).$(RPM_ARCH).rpm
SRPM_FILE = $(PKG_NAME)-$(PKG_VER)-$(PKG_REL)$(DIST_TAG).src.rpm

LIBDIR := $(shell pkg-config --variable=libdir libxfce4panel-2.0 2>/dev/null)
ifeq ($(LIBDIR),)
	ifeq ($(shell command -v rpm >/dev/null 2>&1 && echo yes),yes)
		LIBDIR := $(shell rpm --eval '%{_libdir}' 2>/dev/null || echo /usr/lib64)
	else
		LIBDIR := /usr/lib/$(shell dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)
	endif
endif

PLUGIN_DIR = $(LIBDIR)/xfce4/panel/plugins
DESKTOP_DIR = /usr/share/xfce4/panel/plugins
DESKTOP_FILE = myweather.desktop
SYS_CONF_DIR = /etc/xdg
SYS_CONF_FILE = $(SYS_CONF_DIR)/myweather.conf
FONTS_DIR = /usr/share/fonts/truetype/myweather

all: check_deps $(TARGET)

check_deps:
	@pkg-config --exists libxfce4panel-2.0 gtk+-3.0 libcurl nlohmann_json || { \
		echo "Ошибка: не найдены dev-пакеты! Запустите: make deps"; \
		exit 1; \
	}

deps:
	@if command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y gcc-c++ make pkgconfig rpm-build gtk3-devel xfce4-panel-devel libcurl-devel 'pkgconfig(nlohmann_json)'; \
	elif command -v apt-get >/dev/null 2>&1; then \
		CURL_PKG=""; \
		pkg-config --exists libcurl || CURL_PKG="libcurl4-openssl-dev"; \
		sudo apt-get update && sudo apt-get install -y g++ make pkg-config dpkg-dev rpm libxfce4panel-2.0-dev libgtk-3-dev $$CURL_PKG nlohmann-json3-dev; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -S --needed base-devel gtk3 curl xfce4-panel nlohmann-json rpm-tools; \
	else \
		echo "Установите вручную: gcc-c++, make, pkg-config, rpm-build, gtk3-devel, xfce4-panel-devel, libcurl-devel, nlohmann-json"; \
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
	@if [ -n "$(FONT_FILES)" ]; then \
		mkdir -p $(DEB_DIR)$(FONTS_DIR); \
		install -m 0644 $(FONT_FILES) $(DEB_DIR)$(FONTS_DIR)/; \
	fi
	@printf "[Xfce Panel]\nType=X-XFCE-PanelPlugin\nName=Погода (Open-Meteo)\nComment=Прогноз погоды на 7 дней\nIcon=weather-clear\nX-XFCE-Module=myweather\nX-XFCE-Internal=FALSE\nX-XFCE-API=2.0\n" > $(DEB_DIR)$(DESKTOP_DIR)/$(DESKTOP_FILE)
	@printf "lat=53.13\nlon=45.0\ntimezone=Europe%%2FMoscow\nfont_desc=Tahoma 10\npanel_font=Tahoma 8\npanel_color=#000000\nmax_tooltip_px=423\nupdate_interval=1800\noffset_x=-1\noffset_y=-3\n" > $(DEB_DIR)$(SYS_CONF_FILE)
	@printf "$(SYS_CONF_FILE)\n" > $(DEB_DIR)/DEBIAN/conffiles
	@printf "Package: $(PKG_NAME)\nVersion: $(PKG_VER)\nSection: xfce\nPriority: optional\nArchitecture: $(DEB_ARCH)\nDepends: xfce4-panel, libgtk-3-0 | libgtk-3-0t64, libcurl4 | libcurl4t64\nMaintainer: User <user@localhost>\nDescription: Xfce4 panel weather plugin using Open-Meteo API\n" > $(DEB_DIR)/DEBIAN/control
	@printf "#!/bin/sh\ncommand -v fc-cache >/dev/null 2>&1 && fc-cache -f $(FONTS_DIR) || true\n" > $(DEB_DIR)/DEBIAN/postinst
	@printf "#!/bin/sh\npkill -f 'wrapper-2.0.*myweather' || true\n" > $(DEB_DIR)/DEBIAN/prerm
	@chmod 0755 $(DEB_DIR)/DEBIAN/postinst $(DEB_DIR)/DEBIAN/prerm
	dpkg-deb --build --root-owner-group $(DEB_DIR) $(DEB_FILE)
	rm -rf $(DEB_DIR)
	@echo "Готово: $(DEB_FILE)"

rpm: check_deps $(TARGET)
	@command -v rpmbuild >/dev/null 2>&1 || { echo "Ошибка: rpmbuild не найден! Запустите: make deps"; exit 1; }
	rm -rf $(RPM_DIR)
	mkdir -p $(RPM_DIR)/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	@printf "%%global debug_package %%{nil}\n\
\n\
Name: $(PKG_NAME)\n\
Version: $(PKG_VER)\n\
Release: $(PKG_REL)%%{?dist}\n\
Summary: Xfce4 panel weather plugin using Open-Meteo API\n\
License: GPLv2+\n\
BuildArch: $(RPM_ARCH)\n\
Requires: xfce4-panel, gtk3, libcurl\n\
\n\
%%description\n\
Xfce4 panel weather plugin using Open-Meteo API.\n\
\n\
%%install\n\
mkdir -p %%{buildroot}$(PLUGIN_DIR)\n\
mkdir -p %%{buildroot}$(DESKTOP_DIR)\n\
mkdir -p %%{buildroot}$(SYS_CONF_DIR)\n\
install -m 0755 $(abspath $(TARGET)) %%{buildroot}$(PLUGIN_DIR)/\n\
if [ -n \"$(abspath $(FONT_FILES))\" ]; then\n\
    mkdir -p %%{buildroot}$(FONTS_DIR)\n\
    install -m 0644 $(abspath $(FONT_FILES)) %%{buildroot}$(FONTS_DIR)/\n\
fi\n\
printf '[Xfce Panel]\\nType=X-XFCE-PanelPlugin\\nName=Погода (Open-Meteo)\\nComment=Прогноз погоды на 7 дней\\nIcon=weather-clear\\nX-XFCE-Module=myweather\\nX-XFCE-Internal=FALSE\\nX-XFCE-API=2.0\\n' > %%{buildroot}$(DESKTOP_DIR)/$(DESKTOP_FILE)\n\
printf 'lat=53.13\\nlon=45.0\\ntimezone=Europe%%%%2FMoscow\\nfont_desc=Tahoma 10\\npanel_font=Tahoma 8\\npanel_color=#000000\\nmax_tooltip_px=423\\nupdate_interval=1800\\noffset_x=-1\\noffset_y=-3\\n' > %%{buildroot}$(SYS_CONF_FILE)\n\
\n\
%%post\n\
command -v fc-cache >/dev/null 2>&1 && fc-cache -f $(FONTS_DIR) || true\n\
\n\
%%preun\n\
if [ \$$1 -eq 0 ]; then\n\
    pkill -f 'wrapper-2.0.*myweather' || true\n\
fi\n\
\n\
%%files\n\
$(PLUGIN_DIR)/$(TARGET)\n\
$(DESKTOP_DIR)/$(DESKTOP_FILE)\n\
%%config(noreplace) $(SYS_CONF_FILE)\n\
$(if $(FONT_FILES),$(FONTS_DIR)/,)\n" > $(RPM_SPEC)
	rpmbuild --define "_topdir $(RPM_DIR)" -bb $(RPM_SPEC)
	cp $(RPM_DIR)/RPMS/$(RPM_ARCH)/$(RPM_FILE) .
	rm -rf $(RPM_DIR)
	@echo "Готово: $(RPM_FILE)"

srpm:
	@command -v rpmbuild >/dev/null 2>&1 || { echo "Ошибка: rpmbuild не найден! Запустите: make deps"; exit 1; }
	rm -rf $(RPM_DIR)
	mkdir -p $(RPM_DIR)/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	tar --transform 's,^,$(PKG_NAME)-$(PKG_VER)/,' -czf $(RPM_DIR)/SOURCES/$(PKG_NAME)-$(PKG_VER).tar.gz $(SRC_FILES)
	@printf "Name: $(PKG_NAME)\n\
Version: $(PKG_VER)\n\
Release: $(PKG_REL)%%{?dist}\n\
Summary: Xfce4 panel weather plugin using Open-Meteo API\n\
License: GPLv2+\n\
Source0: %%{name}-%%{version}.tar.gz\n\
\n\
BuildRequires: gcc-c++\n\
BuildRequires: make\n\
BuildRequires: pkgconfig\n\
BuildRequires: pkgconfig(libxfce4panel-2.0)\n\
BuildRequires: pkgconfig(gtk+-3.0)\n\
BuildRequires: pkgconfig(libcurl)\n\
BuildRequires: pkgconfig(nlohmann_json)\n\
\n\
Requires: xfce4-panel, gtk3, libcurl\n\
\n\
%%description\n\
Xfce4 panel weather plugin using Open-Meteo API.\n\
\n\
%%prep\n\
%%autosetup\n\
\n\
%%build\n\
%%make_build\n\
\n\
%%install\n\
make install DESTDIR=%%{buildroot} SUDO=\n\
\n\
%%post\n\
command -v fc-cache >/dev/null 2>&1 && fc-cache -f $(FONTS_DIR) || true\n\
\n\
%%preun\n\
if [ \$$1 -eq 0 ]; then\n\
    pkill -f 'wrapper-2.0.*myweather' || true\n\
fi\n\
\n\
%%files\n\
%%{_libdir}/xfce4/panel/plugins/$(TARGET)\n\
$(DESKTOP_DIR)/$(DESKTOP_FILE)\n\
%%config(noreplace) $(SYS_CONF_FILE)\n\
$(if $(FONT_FILES),$(FONTS_DIR)/,)\n" > $(RPM_SPEC)
	rpmbuild --define "_topdir $(RPM_DIR)" -bs $(RPM_SPEC)
	cp $(RPM_DIR)/SRPMS/$(SRPM_FILE) .
	rm -rf $(RPM_DIR)
	@echo "Готово: $(SRPM_FILE)"

SUDO ?= sudo
install: check_deps $(TARGET)
	$(SUDO) mkdir -p $(DESTDIR)$(PLUGIN_DIR) $(DESTDIR)$(DESKTOP_DIR) $(DESTDIR)$(SYS_CONF_DIR)
	$(SUDO) cp $(TARGET) $(DESTDIR)$(PLUGIN_DIR)/
	@if [ -n "$(FONT_FILES)" ]; then \
		$(SUDO) mkdir -p $(DESTDIR)$(FONTS_DIR); \
		$(SUDO) install -m 0644 $(FONT_FILES) $(DESTDIR)$(FONTS_DIR)/; \
		if [ -z "$(DESTDIR)" ]; then \
			command -v fc-cache >/dev/null 2>&1 && $(SUDO) fc-cache -f $(FONTS_DIR) || true; \
		fi; \
	fi
	@printf "[Xfce Panel]\nType=X-XFCE-PanelPlugin\nName=Погода (Open-Meteo)\nComment=Прогноз погоды на 7 дней\nIcon=weather-clear\nX-XFCE-Module=myweather\nX-XFCE-Internal=FALSE\nX-XFCE-API=2.0\n" | $(SUDO) tee $(DESTDIR)$(DESKTOP_DIR)/$(DESKTOP_FILE) > /dev/null
	@if [ ! -f "$(DESTDIR)$(SYS_CONF_FILE)" ]; then \
		printf "lat=53.13\nlon=45.0\ntimezone=Europe%%2FMoscow\nfont_desc=Tahoma 10\npanel_font=Tahoma 8\npanel_color=#000000\nmax_tooltip_px=423\nupdate_interval=1800\noffset_x=-1\noffset_y=-3\n" | $(SUDO) tee $(DESTDIR)$(SYS_CONF_FILE) > /dev/null; \
	fi

uninstall:
	sudo rm -f $(PLUGIN_DIR)/$(TARGET) $(DESKTOP_DIR)/$(DESKTOP_FILE)
	sudo rm -rf $(FONTS_DIR)
	@command -v fc-cache >/dev/null 2>&1 && sudo fc-cache -f || true
	@echo "Примечание: конфигурационный файл $(SYS_CONF_FILE) сохранен. Для полного удаления выполните: make purge"

purge: uninstall
	sudo rm -f $(SYS_CONF_FILE)

clean:
	rm -rf $(OBJS) $(TARGET) $(DEB_DIR) *.deb $(RPM_DIR) *.rpm

.PHONY: all check_deps deps deb rpm srpm install uninstall purge clean


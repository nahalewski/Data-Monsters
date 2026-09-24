# PS Vita build of the lovepsp runtime (vitasdk + its SDL2).
#
#   make            -> build/vita/gen1recomp.vpk  (needs ../../build/game.pak)

VITASDK ?= /usr/local/vitasdk
PREFIX := $(VITASDK)/bin/arm-vita-eabi-
CC := $(PREFIX)gcc
PKGCONFIG := $(VITASDK)/bin/arm-vita-eabi-pkg-config

RT := ../../runtime
B := $(RT)/build/vita
LUA_DIR := ../../third_party/lua
LUA_SRC := $(filter-out $(LUA_DIR)/luac.c,$(wildcard $(LUA_DIR)/*.c))
RT_SRC := main.c obj.c fs.c image.c gfx.c font.c audio.c core.c apu.c vorbis.c plat_common.c plat_host.c touch.c net.c zipx.c
OBJS := $(patsubst %.c,$(B)/obj/%.o,$(RT_SRC)) $(patsubst $(LUA_DIR)/%.c,$(B)/obj/lua/%.o,$(LUA_SRC))

TITLE_ID := GEN1RECMP
TITLE := gen1recomp for PS Vita

CFLAGS := -O2 -Wall -Wno-unused-function -Wno-format-truncation -Wno-stringop-truncation \
          -Wno-misleading-indentation -fno-strict-aliasing -D__vita__ \
          -I$(LUA_DIR) -I../../third_party/stb -I../../third_party/font8x8 -I$(B) -I$(RT)/src \
          $(shell $(PKGCONFIG) --cflags sdl2) $(LUA_NUMBER_CFLAGS)
LIBS := $(shell $(PKGCONFIG) --libs sdl2) -lScePower_stub -lSceHttp_stub -lSceSsl_stub -lSceNet_stub -lSceNetCtl_stub -lSceSysmodule_stub -lm

all: $(B)/gen1recomp.vpk

$(B)/boot_lua.h: $(RT)/lua/boot.lua $(RT)/tools/bin2c.py
	@mkdir -p $(B)
	python3 $(RT)/tools/bin2c.py $< $@ boot_lua

$(B)/obj/lua/%.o: $(LUA_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -w -O3 -c $< -o $@

$(B)/obj/%.o: $(RT)/src/%.c $(B)/boot_lua.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(B)/lovepsp.elf: $(OBJS)
	$(CC) -Wl,-q -o $@ $^ $(LIBS)

$(B)/eboot.bin: $(B)/lovepsp.elf
	$(VITASDK)/bin/vita-elf-create $< $(B)/lovepsp.velf
	$(VITASDK)/bin/vita-make-fself -s $(B)/lovepsp.velf $@

$(B)/param.sfo:
	@mkdir -p $(B)
	$(VITASDK)/bin/vita-mksfoex -s TITLE_ID=$(TITLE_ID) "$(TITLE)" $@

$(B)/gen1recomp.vpk: $(B)/eboot.bin $(B)/param.sfo ../../build/game.pak
	$(VITASDK)/bin/vita-pack-vpk -s $(B)/param.sfo -b $(B)/eboot.bin \
	  --add ../../build/game.pak=game.pak \
	  --add ../../psp-assets/vita/icon0.png=sce_sys/icon0.png \
	  --add ../../psp-assets/vita/bg.png=sce_sys/livearea/contents/bg.png \
	  --add ../../psp-assets/vita/startup.png=sce_sys/livearea/contents/startup.png \
	  --add template.xml=sce_sys/livearea/contents/template.xml \
	  $@

clean:
	rm -rf $(B)

.PHONY: all clean

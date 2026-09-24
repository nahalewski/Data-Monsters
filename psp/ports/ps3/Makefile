# PS3 build of the lovepsp runtime (PSL1GHT + its SDL2 port from ps3libraries).
#
#   make            -> lovepsp.pkg (CFW / RPCS3 installable) and pkg/ folder
#
# The archive is packed as Lua SOURCE (build.sh --no-bytecode): the PPU is
# big-endian and Lua bytecode is not portable across byte orders.

ifeq ($(strip $(PSL1GHT)),)
$(error "PSL1GHT is not set")
endif
include $(PSL1GHT)/ppu_rules

TARGET := lovepsp
TITLE := gen1recomp for PS3
APPID := GEN1RECMP
CONTENTID := UP0001-$(APPID)_00-0000000000000000
ICON0 := ../../psp-assets/ps3/ICON0.PNG
PKGFILES := pkgfiles

RT := ../../runtime
BUILDDIR := build
LUA_DIR := ../../third_party/lua
LUA_SRC := $(filter-out $(LUA_DIR)/luac.c,$(wildcard $(LUA_DIR)/*.c))
RT_SRC := main.c obj.c fs.c image.c gfx.c font.c audio.c core.c apu.c vorbis.c plat_common.c plat_host.c touch.c net.c zipx.c
OBJS := $(patsubst %.c,$(BUILDDIR)/rt/%.o,$(RT_SRC)) $(patsubst $(LUA_DIR)/%.c,$(BUILDDIR)/lua/%.o,$(LUA_SRC))

PORTLIBS := $(PS3DEV)/portlibs/ppu
CFLAGS := -O2 -Wall -Wno-unused-function -Wno-format-truncation -Wno-stringop-truncation \
          -Wno-misleading-indentation -fno-strict-aliasing $(MACHDEP) \
          -I$(LUA_DIR) -I../../third_party/stb -I../../third_party/font8x8 -I$(BUILDDIR) -I$(RT)/src \
          -I$(PSL1GHT)/ppu/include -I$(PORTLIBS)/include -I$(PORTLIBS)/include/SDL2 $(LUA_NUMBER_CFLAGS)
LDFLAGS := $(MACHDEP) -L$(PSL1GHT)/ppu/lib -L$(PORTLIBS)/lib
LIBS := -lSDL2 -lrsx -lgcm_sys -lio -lsysutil -lsysmodule -laudio -lrt -llv2 -lm

all: $(TARGET).pkg

$(BUILDDIR)/boot_lua.h: $(RT)/lua/boot.lua $(RT)/tools/bin2c.py
	@mkdir -p $(BUILDDIR)
	python3 $(RT)/tools/bin2c.py $< $@ boot_lua

$(BUILDDIR)/lua/%.o: $(LUA_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -w -O3 -c $< -o $@

$(BUILDDIR)/rt/%.o: $(RT)/src/%.c $(BUILDDIR)/boot_lua.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILDDIR)/$(TARGET).elf: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS)
	sprxlinker $@

# ppu_rules' %.self / %.pkg rules expect the elf in $(BUILDDIR)
$(TARGET).self: $(BUILDDIR)/$(TARGET).elf
	$(SELF) $< $@
	$(FSELF) $< $(basename $@).fake.self

$(TARGET).pkg: $(TARGET).self pkgfiles/USRDIR/game.pak

pkgfiles/USRDIR/game.pak: ../../build_ps3/game.pak
	@mkdir -p pkgfiles/USRDIR
	cp $< $@

clean:
	rm -rf $(BUILDDIR) pkgfiles $(TARGET).self $(TARGET).fake.self $(TARGET).pkg

.PHONY: all clean

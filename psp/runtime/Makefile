# PSP build of the lovepsp runtime (pspsdk build.mak).
#
#   make                     -> build/psp/lovepsp.prx + build/psp/PARAM.SFO
#                               (+ build/psp/EBOOT.PBP without game data)
# The release EBOOT with game.pak as DATA.PSAR is assembled by ../build.sh.

PSPSDK := $(shell psp-config --pspsdk-path)
B := build/psp
TARGET := $(B)/lovepsp

LUA_DIR := ../third_party/lua
LUA_SRC := $(filter-out $(LUA_DIR)/luac.c,$(wildcard $(LUA_DIR)/*.c))
RT_SRC := src/main.c src/obj.c src/fs.c src/image.c src/gfx.c src/font.c src/audio.c \
          src/core.c src/apu.c src/vorbis.c src/plat_common.c src/plat_psp.c src/net.c src/zipx.c

OBJS := $(RT_SRC:.c=.o) $(LUA_SRC:.c=.o)

INCDIR := $(LUA_DIR) ../third_party/stb ../third_party/font8x8 $(B) src
# -G0: no small-data section (the Lua state is far bigger than $gp reaches)
CFLAGS := -O2 -G0 -Wall -Wno-unused-function -Wno-format-truncation \
          -Wno-stringop-truncation -Wno-misleading-indentation \
          -fno-strict-aliasing
# number configuration shared by the runtime and lpluac (bytecode must match):
# e.g. LUA_NUMBER_CFLAGS=-DLUA_FLOAT_TYPE=LUA_FLOAT_FLOAT for 32-bit floats
CFLAGS += $(LUA_NUMBER_CFLAGS)
LIBDIR :=
LDFLAGS :=
LIBS := -lpspaudio -lpsppower -lpspdisplay -lpspctrl -lm

BUILD_PRX = 1
PSP_FW_VERSION = 600
PSP_LARGE_MEMORY = 1

EXTRA_TARGETS = $(B)/EBOOT.PBP
PSP_EBOOT = $(B)/EBOOT.PBP
PSP_EBOOT_SFO = $(B)/PARAM.SFO
PSP_EBOOT_TITLE = gen1recomp for PSP
PSP_EBOOT_ICON = ../psp-assets/ICON0.PNG
PSP_EBOOT_PIC1 = ../psp-assets/PIC1.PNG

include $(PSPSDK)/lib/build.mak

$(B)/boot_lua.h: lua/boot.lua tools/bin2c.py
	@mkdir -p $(B)
	python3 tools/bin2c.py $< $@ boot_lua

src/main.o: $(B)/boot_lua.h
$(RT_SRC:.c=.o): $(wildcard src/*.h)
$(LUA_SRC:.c=.o): CFLAGS += -w -O3

.PHONY: clean-all
clean-all: clean
	rm -rf $(B) $(OBJS)

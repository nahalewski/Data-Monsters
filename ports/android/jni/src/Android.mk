# lovepsp runtime as libmain.so for the SDL2 Android activity
LOCAL_PATH := $(call my-dir)
RT := $(LOCAL_PATH)/../../../../runtime
TP := $(LOCAL_PATH)/../../../../third_party
GEN := $(LOCAL_PATH)/../../gen

include $(CLEAR_VARS)
LOCAL_MODULE := main
LOCAL_C_INCLUDES := $(RT)/src $(TP)/lua $(TP)/stb $(TP)/font8x8 $(GEN) $(LOCAL_PATH)/../SDL/include
RT_SRC := main.c obj.c fs.c image.c gfx.c font.c audio.c core.c apu.c vorbis.c plat_common.c plat_host.c touch.c net.c zipx.c
LUA_SRC := $(filter-out $(TP)/lua/luac.c,$(wildcard $(TP)/lua/*.c))
LOCAL_SRC_FILES := $(addprefix $(RT)/src/,$(RT_SRC)) $(LUA_SRC)
LOCAL_CFLAGS := -O2 -fno-strict-aliasing -DLUA_USE_POSIX -DLUA_USE_DLOPEN -Wno-unused-function
LOCAL_SHARED_LIBRARIES := SDL2
LOCAL_LDLIBS := -llog -landroid -lm -ldl
include $(BUILD_SHARED_LIBRARY)

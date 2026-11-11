#!/usr/bin/env bash
#
# Builds OpenBeken's Linux simulator (upstream's custom.mk) twice -- sanitized for the fuzz targets,
# plain for the oracle -- and links the three libFuzzer harnesses against the sanitized objects.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Upstream's build writes generated Berry resources and reaches Berry through a hard-coded
# ../../../libraries/berry include, so build in a staged copy of the tree (gitignored) with Berry
# (a git submodule upstream) taken from the image's pinned dependency cache.
BERRY_DEP=/opt/toolchains/deps/berry-b9ce913d9d43bb296d9604bc0cb4f2f68a6b703f/src
B="$SRC/mayhem/build"
STAGE="$B/obk"
rm -rf "$B"
mkdir -p "$STAGE/libraries/berry"
cp -a src include custom.mk "$STAGE/"
cp -a libraries/berry.mk "$STAGE/libraries/"
cp -a "$BERRY_DEP/." "$STAGE/libraries/berry/"
cd "$STAGE"
mkdir -p libraries/berry/generate libraries/berry/temp
libraries/berry/tools/coc/coc -o libraries/berry/temp libraries/berry/src src/berry/modules -c include/berry_conf.h
cp -r libraries/berry/temp/. libraries/berry/generate/

quiet() { # <log> <cmd...>: keep the log on success, show its tail on failure
  local log="$1"; shift
  "$@" > "$log" 2>&1 || { tail -60 "$log"; exit 1; }
}

# The simulator is C with implicit declarations / int-pointer mixes that clang 19 rejects by default;
# glibc >= 2.38 also collides with upstream's strcasestr (see obk_compat.h). -lnsl does not exist on
# this base and the simulator does not need it. Paths in DWARF are mapped back to the real tree.
MAP="-fdebug-prefix-map=$STAGE=$SRC"
OBK_CPP='-include '"$SRC"'/mayhem/obk_compat.h $(INCLUDES) -MMD -MP -std=gnu99 -DWINDOWS -DLINUX -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-return-mismatch'

build_objs() { # <name> <cflags...>
  local name="$1"; shift
  local dir="$B/$name"
  quiet "$B/make-$name.log" make -f "$SRC/mayhem/objs.mk" -j"$MAYHEM_JOBS" BUILD_DIR="$dir" \
       LDLIBS='-lpthread -lm' CC="$CC" CPPFLAGS="$OBK_CPP" CFLAGS="-w $MAP $*" objs
  # upstream's main() lives in win_main.c; rename it so harnesses can provide their own entry point
  objcopy --redefine-sym main=obk_sim_main "$dir/src/win_main.c.o" "$dir/win_main_nomain.o"
  find "$dir" -name '*.o' ! -name win_main.c.o ! -name win_main_nomain.o | sort > "$dir/objs.list"
}

INCLUDES="$(make -s -f "$SRC/mayhem/objs.mk" print-includes)"
CPP_FLAGS=(-include "$SRC/mayhem/obk_compat.h" -I"$SRC/mayhem" $INCLUDES -std=gnu99 -DWINDOWS -DLINUX
           -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-return-mismatch)

# 1) Sanitized simulator + the fuzz harnesses.
# Relaxed UBSan checks (everything else, and all of ASan, stays on and halting):
#  - shift: the firmware's BIT_CHECK/BIT_SET helpers and CFG_HasFlag do `1 << 31` and `1 << i` for i >= 32
#    on int all over (e.g. the index page loops BIT_CHECK(g_hiddenChannels, i) up to CHANNEL_MAX); upstream's
#    own ASan/UBSan CI suppresses shift-base by function for the same reason.
#  - float-cast-overflow: float values are narrowed to int/byte throughout the LED and expression code
#    (NaN or out-of-range input -> `unsigned char`), which fires on the first colour/expression command.
#  - function: HTTP/command callbacks are stored through differently typed function pointers
#    (e.g. hprintf255 via `int (*)(void *, const char *, ...)`), which trips on every REST API call.
SAN="$B/san"
build_objs san $SANITIZER_FLAGS -fno-sanitize=shift,function,float-cast-overflow $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link
xargs -a "$SAN/objs.list" ar rcs "$SAN/libobk.a" "$SAN/win_main_nomain.o"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

for t in fuzz_http fuzz_command fuzz_tuyamcu; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link -w $MAP "${CPP_FLAGS[@]}" -c "$SRC/mayhem/$t.c" -o "$B/$t.o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/$t.o" "$B/lsan_off.o" \
      -Wl,--whole-archive "$SAN/libobk.a" -Wl,--no-whole-archive -lpthread -lm -lstdc++ -o "/mayhem/$t"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "$B/$t.o" "$B/standalone_main.o" "$B/lsan_off.o" \
      -Wl,--whole-archive "$SAN/libobk.a" -Wl,--no-whole-archive -lpthread -lm -lstdc++ -o "/mayhem/$t-standalone"
done

# 2) The oracle: upstream's own self-test suite (win_main -runUnitTests 2) and the known-answer
#    probes, both built with plain flags and no sanitizers.
PLAIN="$B/plain"
build_objs plain -O1 $COVERAGE_FLAGS
$CC $COVERAGE_FLAGS "$PLAIN/src/win_main.c.o" $(cat "$PLAIN/objs.list") -lpthread -lm -o /mayhem/obk_selftest
$CC -O1 -w $COVERAGE_FLAGS "${CPP_FLAGS[@]}" "$SRC/mayhem/obk_kat.c" "$PLAIN/win_main_nomain.o" $(cat "$PLAIN/objs.list") -lpthread -lm -o /mayhem/obk_kat

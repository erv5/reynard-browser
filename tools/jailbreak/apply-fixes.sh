#!/bin/sh

# Jailbreak compatibility fixes for the Reynard/Gecko build.
#
# 1. build-gecko.sh: add --disable-jemalloc to the generated mozconfig.
#    jemalloc registers its own malloc zone at startup (memory/build/zone.c),
#    which conflicts with libhooker (Taurine) on jailbroken devices:
#    pspawn_payload-stg2.dylib aborts in free() during
#    dyld::initializeMainExecutable, before main() runs.
# 2. build-gecko.sh: add --without-wasm-sandboxed-libraries. Xcode's clang
#    has no wasm backend and no wasi sysroot is installed, so the wasm
#    compiler check in configure fails otherwise.
# 3. build-gecko.sh: invoke mach with python3.12 (mach rejects newer Python).
# 4. toolchain.configure: relax the minimum macOS SDK to the installed
#    version when it is older than Gecko's requirement.
# 5. build-app.sh: archive with CODE_SIGNING_ALLOWED=NO (CI runners have no
#    Apple identity or provisioning profiles; create-ipa.sh re-signs with
#    ldid anyway), and AddGecko.sh: fall back to ad-hoc signing for the
#    Gecko dylibs in that case - xcodebuild forbids CODE_SIGN_IDENTITY=-
#    as a build setting on recent SDKs, but codesign -s - from a script
#    phase is fine.
#
# Idempotent: safe to run multiple times.
# Must be run after update-gecko.sh. If invoked from outside the repository
# (e.g. copied to a temp dir in CI), set REYNARD_ROOT to the repository root.

set -eu

if [ -n "${REYNARD_ROOT:-}" ]; then
	ROOT_DIR="$REYNARD_ROOT"
else
	SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
	ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
fi
FIREFOX_DIR="$ROOT_DIR/engine/firefox"
BUILD_GECKO="$ROOT_DIR/tools/development/build-gecko.sh"
BUILD_APP="$ROOT_DIR/tools/release/build-app.sh"
TOOLCHAIN_CONFIGURE="$FIREFOX_DIR/build/moz.configure/toolchain.configure"

# --- 1+2. mozconfig options -------------------------------------------------

if ! grep -q "disable-jemalloc" "$BUILD_GECKO"; then
	awk '{
		print
		if (!done && $0 ~ /ac_add_options --disable-debug/) {
			print "\techo \"ac_add_options --disable-jemalloc\""
			print "\techo \"ac_add_options --without-wasm-sandboxed-libraries\""
			done = 1
		}
	}' "$BUILD_GECKO" > "$BUILD_GECKO.tmp"
	cat "$BUILD_GECKO.tmp" > "$BUILD_GECKO" && rm "$BUILD_GECKO.tmp"
	echo "patched: mozconfig gains --disable-jemalloc and --without-wasm-sandboxed-libraries"
else
	echo "ok: jemalloc options already present in build-gecko.sh"
fi

# --- 3. python3.12 for mach ---------------------------------------------------

if ! grep -q "python3.12 ./mach" "$BUILD_GECKO"; then
	sed -i '' 's|^\(\s*\)\./mach build|\1python3.12 ./mach build|' "$BUILD_GECKO"
	echo "patched: mach invoked with python3.12"
else
	echo "ok: mach already uses python3.12"
fi

# --- 4. macOS SDK minimum -----------------------------------------------------

if [ -f "$TOOLCHAIN_CONFIGURE" ]; then
	MACOS_SDK_VER="$(xcrun --show-sdk-version --sdk macosx)"
	python3 - "$TOOLCHAIN_CONFIGURE" "$MACOS_SDK_VER" <<'PYEOF'
import re, sys
path, installed = sys.argv[1], sys.argv[2]
src = open(path).read()
m = re.search(r'(def mac_sdk_min_version\(\):\s*\n\s*return ")([0-9.]+)(")', src)
if m:
    def v(s):
        return tuple(int(x) for x in s.split("."))
    if v(m.group(2)) > v(installed):
        src = src[:m.start(2)] + installed + src[m.end(2):]
        open(path, "w").write(src)
        print(f"patched: macOS SDK minimum {m.group(2)} -> {installed}")
    else:
        print(f"ok: macOS SDK {installed} satisfies minimum {m.group(2)}")
else:
    print("warn: mac_sdk_min_version not found; toolchain.configure may have changed")
PYEOF
fi

# --- 5. signing-free archive + ad-hoc fallback in AddGecko.sh -----------------

if ! grep -q "CODE_SIGNING_ALLOWED" "$BUILD_APP"; then
	sed -i '' 's|^xcodebuild archive|xcodebuild archive CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=|' "$BUILD_APP"
	echo "patched: build-app.sh archives without code signing"
else
	echo "ok: build-app.sh already archives unsigned"
fi

ADD_GECKO="$ROOT_DIR/browser/Scripts/AddGecko.sh"
if ! grep -q "CODE_SIGNING_ALLOWED" "$ADD_GECKO"; then
	awk '{
		print
		if (!done && $0 ~ /^SIGN_IDENTITY=/) {
			print ""
			print "# CODE_SIGNING_ALLOWED=NO leaves EXPANDED_CODE_SIGN_IDENTITY empty;"
			print "# fall back to ad-hoc signing (create-ipa.sh re-signs with ldid later)."
			print "if [ \"${CODE_SIGNING_ALLOWED:-YES}\" = \"NO\" ]; then"
			print "\tSIGN_IDENTITY=\"-\""
			print "fi"
			done = 1
		}
	}' "$ADD_GECKO" > "$ADD_GECKO.tmp"
	cat "$ADD_GECKO.tmp" > "$ADD_GECKO" && rm "$ADD_GECKO.tmp"
	echo "patched: AddGecko.sh falls back to ad-hoc signing when signing is disabled"
else
	echo "ok: AddGecko.sh already has ad-hoc fallback"
fi

echo "All jailbreak fixes applied."

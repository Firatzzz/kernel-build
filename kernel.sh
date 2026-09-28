#!/usr/bin/env bash
#
# Shisouka Kernel - local build script (Redmi 10C / fog, sm6225)
#
# Pemakaian:
#   bash kernel.sh
#
# Opsi lewat environment variable (semua opsional):
#   BRANCH=ye            branch source kernel (kosong = default branch)
#   USE_KSU=1            1 = pasang KernelSU, 0 = tanpa KernelSU
#   CLEAN=1              1 = build bersih, 0 = incremental
#   TG_BOT_TOKEN=...     token bot Telegram (kosong = tanpa notifikasi)
#   TG_CHAT_ID=...       chat ID / channel tujuan
#
# Contoh:
#   TG_BOT_TOKEN="123:abc" TG_CHAT_ID="-100123456" USE_KSU=1 bash kernel.sh
#
# Jangan menulis token langsung di file ini kalau repo bersifat publik.

set -euo pipefail

##--------------------------- Konfigurasi ---------------------------##

KERNEL_NAME="Shisouka-Kernel"
DEVICE="fog"
MODEL="Redmi 10C"
AUTHOR="Firatz"
DEFCONFIG="vendor/fog-perf_defconfig"
ARCH_NAME="arm64"

KERNEL_REPO="https://github.com/Firatzzz/kernel_xiaomi_sm6225"
ANYKERNEL_REPO="https://github.com/Kentanglu/AnyKernel3-680"
CLANG_URL="https://github.com/ZyCromerZ/Clang/releases/download/17.0.0-20230725-release/Clang-17.0.0-20230725.tar.gz"
GCC64_REPO="https://github.com/ZyCromerZ/aarch64-linux-android-4.9"
GCC32_REPO="https://github.com/ZyCromerZ/arm-linux-androideabi-4.9"

BRANCH="${BRANCH:-}"
USE_KSU="${USE_KSU:-1}"
CLEAN="${CLEAN:-1}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

WORKDIR="${WORKDIR:-$HOME/shisouka-build}"   # jangan pakai spasi di path
SRC="$WORKDIR/kernel"
TC="$WORKDIR/toolchain"
AK3="$WORKDIR/AnyKernel3"
OUT_ZIP_DIR="$WORKDIR/output"
LOG_FILE="$WORKDIR/error.log"

export TZ="Asia/Jakarta"

##--------------------------- Helper ---------------------------##

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

tg_enabled() { [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; }

tg_text() {
	tg_enabled || return 0
	curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
		-d chat_id="$TG_CHAT_ID" \
		-d parse_mode=HTML \
		-d disable_web_page_preview=true \
		--data-urlencode text="$1" > /dev/null || true
}

tg_file() {
	# $1 = path file, $2 = caption
	tg_enabled || return 0
	curl -s -F document=@"$1" \
		"https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
		-F chat_id="$TG_CHAT_ID" \
		-F parse_mode=HTML \
		-F caption="$2" > /dev/null || true
}

on_error() {
	local code=$?
	warn "Build gagal (exit code $code)"
	if [ -f "$LOG_FILE" ]; then
		tg_file "$LOG_FILE" "${KERNEL_NAME} build FAILED (exit ${code})"
	else
		tg_text "${KERNEL_NAME} build FAILED (exit ${code})"
	fi
	exit "$code"
}
trap on_error ERR

need() {
	for bin in "$@"; do
		command -v "$bin" > /dev/null 2>&1 || die "Perintah '$bin' tidak ditemukan. Install dulu (contoh: sudo apt install $bin)"
	done
}

##--------------------------- Tahapan ---------------------------##

check_env() {
	need git curl wget tar zip make python3 bc bison flex
	case "$WORKDIR" in *" "*) die "WORKDIR tidak boleh mengandung spasi: $WORKDIR" ;; esac
	mkdir -p "$WORKDIR" "$OUT_ZIP_DIR"
}

fetch_source() {
	if [ ! -d "$SRC/.git" ]; then
		log "Clone source kernel"
		git clone --depth=1 ${BRANCH:+-b "$BRANCH"} "$KERNEL_REPO" "$SRC"
	else
		log "Source sudah ada, memakai yang lokal ($SRC)"
	fi
	cd "$SRC"
	COMMIT_SHORT="$(git rev-parse --short HEAD)"
	COMMIT_MSG="$(git log -1 --pretty=%s)"
	KERNEL_VER="$(make kernelversion 2> /dev/null || echo unknown)"
}

fetch_toolchain() {
	mkdir -p "$TC"
	if [ ! -x "$TC/clang/bin/clang" ]; then
		log "Download Clang (agak lama)"
		mkdir -p "$TC/clang"
		wget -q --show-progress "$CLANG_URL" -O "$WORKDIR/clang.tar.gz"
		tar -xf "$WORKDIR/clang.tar.gz" -C "$TC/clang"
		rm -f "$WORKDIR/clang.tar.gz"
	fi
	[ -d "$TC/gcc64" ] || { log "Clone GCC64"; git clone --depth=1 "$GCC64_REPO" "$TC/gcc64"; }
	[ -d "$TC/gcc32" ] || { log "Clone GCC32"; git clone --depth=1 "$GCC32_REPO" "$TC/gcc32"; }
	[ -d "$AK3" ]      || { log "Clone AnyKernel3"; git clone --depth=1 "$ANYKERNEL_REPO" -b master "$AK3"; }
}

patch_ksu() {
	KSU_TEXT="Off"
	[ "$USE_KSU" = "1" ] || return 0
	cd "$SRC"
	if [ ! -d KernelSU ]; then
		log "Pasang KernelSU"
		curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
	else
		log "KernelSU sudah terpasang"
	fi
	local count
	count="$(cd KernelSU && git rev-list --count HEAD 2> /dev/null || echo 0)"
	KSU_TEXT="On (v$((count + 10200)))"
}

compile() {
	cd "$SRC"

	export PATH="$TC/clang/bin:$TC/gcc64/bin:$TC/gcc32/bin:$PATH"
	export LD_LIBRARY_PATH="$TC/clang/lib:$TC/gcc64/lib:$TC/gcc32/lib:${LD_LIBRARY_PATH:-}"
	export ARCH="$ARCH_NAME" SUBARCH="$ARCH_NAME"
	export KBUILD_BUILD_USER="$AUTHOR"
	export KBUILD_BUILD_HOST="$(hostname)"
	export LOCALVERSION="-${KERNEL_NAME}"

	local args=(
		O=out
		ARCH="$ARCH_NAME"
		CC=clang
		LLVM_IAS=1
		PYTHON=python3
		CROSS_COMPILE=aarch64-linux-android-
		CROSS_COMPILE_ARM32=arm-linux-androideabi-
		CLANG_TRIPLE=aarch64-linux-gnu-
		AR=llvm-ar
		NM=llvm-nm
		OBJDUMP=llvm-objdump
		STRIP=llvm-strip
		LD=aarch64-linux-android-ld
		HOSTLD="$TC/clang/bin/ld"
	)

	if [ "$CLEAN" = "1" ]; then
		log "Membersihkan out/"
		rm -rf out
	fi

	log "Generate defconfig: $DEFCONFIG"
	make "${args[@]}" "$DEFCONFIG"

	tg_text "<b>${KERNEL_NAME} build started</b>
<b>Device:</b> <code>${MODEL} (${DEVICE})</code>
<b>Kernel:</b> <code>${KERNEL_VER}</code>
<b>KernelSU:</b> <code>${KSU_TEXT}</code>
<b>Commit:</b> <code>${COMMIT_SHORT} - ${COMMIT_MSG}</code>
<b>Host:</b> <code>$(hostname) ($(nproc --all) core)</code>"

	log "Mulai kompilasi"
	local start end
	start=$(date +%s)
	set -o pipefail
	make -j"$(nproc --all)" "${args[@]}" 2>&1 | tee "$LOG_FILE"
	end=$(date +%s)
	BUILD_TIME="$(( (end - start) / 60 ))m $(( (end - start) % 60 ))s"

	[ -f out/arch/arm64/boot/Image.gz ] || die "Image.gz tidak ditemukan, kompilasi gagal"
	log "Kompilasi selesai dalam $BUILD_TIME"
}

package() {
	local stamp name
	stamp="$(date +%Y%m%d-%H%M)"
	name="${KERNEL_NAME}-${DEVICE}"
	[ "$USE_KSU" = "1" ] && name="${name}-KSU"
	name="${name}-${stamp}-${COMMIT_SHORT}.zip"

	log "Membuat zip: $name"
	cp "$SRC/out/arch/arm64/boot/Image.gz" "$AK3/Image.gz"
	(cd "$AK3" && zip -r9 "$OUT_ZIP_DIR/$name" . -x ".git*" -x "README.md" -x "*.zip")

	ZIP_PATH="$OUT_ZIP_DIR/$name"
	ZIP_MD5="$(md5sum "$ZIP_PATH" | cut -d' ' -f1)"
}

upload() {
	log "Hasil: $ZIP_PATH"
	if tg_enabled; then
		log "Upload ke Telegram"
		tg_file "$ZIP_PATH" "<b>${KERNEL_NAME}</b> for ${MODEL}
Build time: <code>${BUILD_TIME}</code>
KernelSU: <code>${KSU_TEXT}</code>
Commit: <code>${COMMIT_SHORT}</code>
MD5: <code>${ZIP_MD5}</code>"
	else
		warn "TG_BOT_TOKEN / TG_CHAT_ID kosong, upload Telegram dilewati"
	fi
}

##--------------------------- Main ---------------------------##

main() {
	check_env
	fetch_source
	fetch_toolchain
	patch_ksu
	compile
	package
	upload
	log "Selesai."
}

main "$@"

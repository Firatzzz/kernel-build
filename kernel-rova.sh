#!/bin/bash
# shellcheck disable=SC2154
#
# Build Shisouka Kernel - Redmi 4A / 5A (rova = rolex + riva, MSM8917)
# Source : https://github.com/Firatzzz/kernel_rova (branch 16-dev, Linux 4.19.325)
# Dijalankan dari GitHub Actions:  bash kernel.sh
#
# Variabel environment (semua opsional, dari workflow):
#   KERNEL_BRANCH : branch source kernel (default: 16-dev)
#   DEFCONFIG     : defconfig relatif terhadap arch/arm64/configs (default: deteksi otomatis)
#   FRAGMENTS     : fragment config tambahan, dipisah spasi (opsional)
#   TOOLCHAIN     : proton (default, Clang 13 + binutils GNU) | zyc (Clang 17 + GCC 4.9)
#   LLVM_IAS      : 1 (default) | 0 kalau ada error assembler
#   ENABLE_LTO    : 0 (default, LTO/CFI dimatikan agar build stabil) | 1
#   KSU           : 1 = aktifkan root KernelSU | 0 = matikan (default: 1)
#   KSU_SOURCE    : auto    = pakai KernelSU bawaan source jika ada, kalau tidak pakai next (default)
#                   builtin = KernelSU bawaan source (gagal jika tidak ada)
#                   next    = KernelSU-Next branch legacy (non-GKI)
#                   sukisu  = SukiSU-Ultra
#   KSU_HOOK      : kprobes (default) | manual (hook harus SUDAH ada di source)
#   CUSTOM_LOCALVERSION : suffix versi kernel (default kosong, lihat catatan modul)
#   TG_BOT_TOKEN  : token bot Telegram (disarankan dari GitHub Secrets)
#   TG_CHAT_ID    : chat id grup Telegram (disarankan dari GitHub Secrets)

set -eo pipefail

##------------------------------------------------------##
##----------------- Konfigurasi dasar ------------------##

WORKDIR="$(pwd)"
KERNEL="$WORKDIR/kernel"
TC="$WORKDIR/toolchain"
AK3="$WORKDIR/AnyKernel3"
OUTDIR="$WORKDIR/output"
LOG="$WORKDIR/error.log"

KERNEL_REPO="https://github.com/Firatzzz/kernel_rova"
KERNEL_BRANCH="${KERNEL_BRANCH:-16-dev}"
ANYKERNEL_REPO="https://github.com/osm0sis/AnyKernel3"

TOOLCHAIN="${TOOLCHAIN:-proton}"
PROTON_REPO="https://github.com/kdrag0n/proton-clang"
ZYC_CLANG_URL="https://github.com/ZyCromerZ/Clang/releases/download/17.0.0-20230725-release/Clang-17.0.0-20230725.tar.gz"
ZYC_GCC64_REPO="https://github.com/ZyCromerZ/aarch64-linux-android-4.9"
ZYC_GCC32_REPO="https://github.com/ZyCromerZ/arm-linux-androideabi-4.9"

KERNEL_NAME="Shisouka-Kernel"
AUTHOR="Firatz"
MODEL="Redmi 4A / 5A"
DEVICE="rova"

DEFCONFIG="${DEFCONFIG:-}"
FRAGMENTS="${FRAGMENTS:-}"
LLVM_IAS="${LLVM_IAS:-1}"
ENABLE_LTO="${ENABLE_LTO:-0}"

# Root. 1 = YES | 0 = NO
KSU="${KSU:-1}"
KSU_SOURCE="${KSU_SOURCE:-auto}"
KSU_HOOK="${KSU_HOOK:-kprobes}"

# Push ke Telegram. 1 = YES | 0 = NO
PTTG=1
CHATID="${TG_CHAT_ID:-"-1004403448296"}"
TOKEN="${TG_BOT_TOKEN:-8201939373:AAHYv-Yrl_TpqkBKr_HaAXAmSJVRzJfl08E}"

export TZ="Asia/Jakarta"

: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

##------------------------------------------------------##
##-------------------- Telegram ------------------------##

TG_ENABLED=0

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# Panggil API Telegram. Retry 3x, error ditampilkan.
tg_api()
{
	local method="$1"; shift
	local out try
	for try in 1 2 3; do
		out="$(curl -sS --max-time 600 "https://api.telegram.org/bot${TOKEN}/${method}" "$@" 2>&1)" || true
		if echo "$out" | grep -q '"ok":true'; then
			return 0
		fi
		echo "[!] Telegram ${method} gagal (percobaan $try): $(echo "$out" | head -c 400)"
		sleep 3
	done
	return 1
}

tg_msg()
{
	[ "$TG_ENABLED" = 1 ] || return 0
	tg_api sendMessage \
		--form-string chat_id="$CHATID" \
		--form-string parse_mode=HTML \
		--form-string disable_web_page_preview=true \
		--form-string text="$1"
}

# PENTING: caption pakai --form-string. Dengan -F, nilai yang diawali
# '<' atau '@' dianggap nama file oleh curl (caption "<b>..." bikin upload gagal).
tg_doc()
{
	[ "$TG_ENABLED" = 1 ] || return 0
	tg_api sendDocument \
		--form-string chat_id="$CHATID" \
		--form-string parse_mode=HTML \
		--form-string caption="$2" \
		-F document=@"$1"
}

tg_init()
{
	if [ "$PTTG" != 1 ]; then return 0; fi
	if [ -z "$TOKEN" ] || [ -z "$CHATID" ]; then
		echo "[!] TG_BOT_TOKEN / TG_CHAT_ID kosong. Telegram dilewati."
		return 0
	fi

	local r
	r="$(curl -sS --max-time 30 "https://api.telegram.org/bot${TOKEN}/getMe" 2>&1 || true)"
	if ! echo "$r" | grep -q '"ok":true'; then
		echo "[!] Token ditolak Telegram (dicabut/salah): $(echo "$r" | head -c 300)"
		return 0
	fi
	echo "[+] Bot OK: $(echo "$r" | grep -o '"username":"[^"]*"' || true)"

	r="$(curl -sS --max-time 30 "https://api.telegram.org/bot${TOKEN}/getChat" --form-string chat_id="$CHATID" 2>&1 || true)"
	if ! echo "$r" | grep -q '"ok":true'; then
		echo "[!] Chat ID $CHATID tidak bisa diakses bot: $(echo "$r" | head -c 300)"
		echo "[!] Pastikan bot sudah masuk grup (dan jadi admin bila perlu) dan ID benar."
		return 0
	fi
	echo "[+] Grup OK: $(echo "$r" | grep -o '"title":"[^"]*"' || true)"
	TG_ENABLED=1
}

on_exit()
{
	local code=$?
	trap - EXIT
	if [ "$code" -ne 0 ]; then
		sleep 2
		echo "[×] Build gagal (exit code $code)"
		local run_url="" tail_txt
		if [ -n "${GITHUB_RUN_ID:-}" ]; then
			run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
		fi
		tail_txt="$(tail -n 40 "$LOG" 2>/dev/null | esc | tail -c 3000 || true)"
		tg_msg "$(printf '%s\n%s\n\n%s' \
			"<b>${KERNEL_NAME} build FAILED</b> (exit ${code})" \
			"${run_url:+<a href=\"${run_url}\">Buka run</a>}" \
			"<pre>${tail_txt}</pre>")" || true
		if [ -s "$LOG" ]; then
			tg_doc "$LOG" "${KERNEL_NAME} build FAILED" || true
		fi
	fi
	exit "$code"
}
trap on_exit EXIT

##------------------------------------------------------##
##----------------------- Langkah ----------------------##

ensure_deps()
{
	local miss=() t SUDO=""
	for t in git curl wget zip python3 bc flex bison make; do
		command -v "$t" >/dev/null 2>&1 || miss+=("$t")
	done
	if [ "${#miss[@]}" -gt 0 ]; then
		echo "[!] Tool belum ada: ${miss[*]}"
		if command -v apt-get >/dev/null 2>&1; then
			command -v sudo >/dev/null 2>&1 && SUDO="sudo"
			$SUDO apt-get update -qq
			$SUDO apt-get install -y -qq git curl wget zip python3 bc flex bison make \
				libssl-dev libelf-dev cpio xz-utils lz4 ccache
		else
			echo "[×] Install manual: ${miss[*]}"
			exit 1
		fi
	fi
}

clone_kernel()
{
	echo "[*] Clone kernel source: $KERNEL_REPO (branch: $KERNEL_BRANCH)"
	git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL"
	cd "$KERNEL"

	COMMIT_SHORT="$(git rev-parse --short HEAD)"
	COMMIT_MSG="$(git log -1 --pretty=%s | tr -d '\r')"
	COMMIT_HEAD="$(git log --oneline -1)"
	BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD)"
	KERVER="$(make -s kernelversion 2>/dev/null | grep -E '^[0-9]' | head -n1 || true)"
	[ -n "$KERVER" ] || KERVER="unknown"
	echo "Branch  : $BRANCH_NAME"
	echo "Commit  : $COMMIT_HEAD"
	echo "Kernel  : $KERVER"
}

# Cari defconfig rova otomatis kalau DEFCONFIG tidak diisi / tidak ada.
validate_defconfig()
{
	cd "$KERNEL"
	local cfg_dir="arch/arm64/configs" cand found=""
	echo "[*] Defconfig tersedia yang berhubungan dengan rova/msm8917/msm8937:"
	(cd "$cfg_dir" && find . -type f -name '*defconfig*' | sed 's|^\./||' \
		| grep -iE 'rova|rolex|riva|8917|8937|mi8937' | sort | head -n 40) || true

	if [ -n "$DEFCONFIG" ] && [ -f "$cfg_dir/$DEFCONFIG" ]; then
		found="$DEFCONFIG"
	else
		[ -z "$DEFCONFIG" ] || echo "[!] DEFCONFIG='$DEFCONFIG' tidak ada, mencari otomatis..."
		for cand in rova_defconfig rova-perf_defconfig vendor/rova_defconfig \
			rolex_defconfig riva_defconfig msm8917-perf_defconfig msm8917_defconfig; do
			if [ -f "$cfg_dir/$cand" ]; then found="$cand"; break; fi
		done
		if [ -z "$found" ]; then
			found="$(cd "$cfg_dir" && find . -type f -name '*_defconfig' | sed 's|^\./||' \
				| grep -iE 'rova|rolex|riva|8917' | grep -viE 'debug|diag' | sort | head -n1 || true)"
		fi
	fi

	if [ -z "$found" ]; then
		echo "[×] Tidak ada defconfig rova yang cocok di branch '$BRANCH_NAME'."
		echo "    Isi arch/arm64/configs:"
		ls "$cfg_dir" | head -n 80 || true
		echo "    Set DEFCONFIG=<nama>_defconfig lewat workflow."
		exit 1
	fi
	DEFCONFIG="$found"
	echo "[+] Defconfig dipakai: $DEFCONFIG"

	local f
	for f in $FRAGMENTS; do
		if [ ! -f "$cfg_dir/$f" ]; then
			echo "[×] Fragment $f tidak ada di $cfg_dir"
			exit 1
		fi
		echo "[+] Fragment: $f"
	done
}

setup_toolchain()
{
	mkdir -p "$TC"
	case "$TOOLCHAIN" in
	proton)
		echo "[*] Clone Proton Clang (Clang + binutils GNU lengkap)"
		git clone --depth=1 "$PROTON_REPO" "$TC/clang"
		CLANG_DIR="$TC/clang"
		TC_PATH="$CLANG_DIR/bin"
		CROSS64="aarch64-linux-gnu-"
		CROSS32="arm-linux-gnueabi-"
		CLANG_TRIPLE_V="aarch64-linux-gnu-"
		;;
	zyc)
		echo "[*] Download ZyC Clang 17 + GCC 4.9"
		mkdir -p "$TC/clang"
		wget -q "$ZYC_CLANG_URL" -O "$WORKDIR/clang.tar.gz"
		tar -xf "$WORKDIR/clang.tar.gz" -C "$TC/clang"
		rm -f "$WORKDIR/clang.tar.gz"
		local cb
		cb="$(find "$TC/clang" \( -type f -o -type l \) -name clang -path '*/bin/*' 2>/dev/null | head -n1 || true)"
		if [ -z "$cb" ]; then
			echo "[×] clang tidak ditemukan setelah ekstrak"
			exit 1
		fi
		CLANG_DIR="$(dirname "$(dirname "$cb")")"
		git clone --depth=1 "$ZYC_GCC64_REPO" "$TC/gcc64"
		git clone --depth=1 "$ZYC_GCC32_REPO" "$TC/gcc32"
		TC_PATH="$CLANG_DIR/bin:$TC/gcc64/bin:$TC/gcc32/bin"
		CROSS64="aarch64-linux-android-"
		CROSS32="arm-linux-androideabi-"
		CLANG_TRIPLE_V="aarch64-linux-gnu-"
		;;
	*)
		echo "[×] TOOLCHAIN='$TOOLCHAIN' tidak dikenal (proton|zyc)"
		exit 1
		;;
	esac

	export PATH="$TC_PATH:$PATH"
	CLANG_VER="$(clang --version | head -n1 || true)"
	echo "[+] $CLANG_VER"
	local t
	for t in ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip; do
		command -v "$t" >/dev/null 2>&1 || { echo "[×] $t tidak ada di toolchain"; exit 1; }
	done

	echo "[*] Clone AnyKernel3 (osm0sis)"
	git clone --depth=1 "$ANYKERNEL_REPO" "$AK3"
}

find_ksu_kconfig()
{
	KSU_KCONFIG="$(grep -rlE '^config KSU$' --include='Kconfig*' \
		KernelSU drivers fs kernel security 2>/dev/null | head -n1 || true)"
}

# Hapus KernelSU lama bawaan source sebelum memasang yang baru
clean_ksu()
{
	echo "[*] Bersihkan KernelSU lama"
	rm -rf KernelSU drivers/kernelsu drivers/KernelSU
	[ ! -f drivers/Makefile ] || sed -i '/kernelsu/Id' drivers/Makefile
	[ ! -f drivers/Kconfig ] || sed -i '/kernelsu/Id' drivers/Kconfig
}

prepare_ksu()
{
	cd "$KERNEL"
	KSU_TEXT="Off"
	KSU_TAG=""
	KSU_MODE="none"

	if [ "$KSU" != "1" ]; then
		echo "[*] Root dimatikan (KSU=$KSU)"
		return 0
	fi

	find_ksu_kconfig
	local mode="$KSU_SOURCE"
	if [ "$mode" = "auto" ]; then
		if [ -n "$KSU_KCONFIG" ]; then mode="builtin"; else mode="next"; fi
		echo "[*] KSU_SOURCE=auto -> $mode"
	fi

	case "$mode" in
	builtin)
		if [ -z "$KSU_KCONFIG" ]; then
			echo "[×] Source ini tidak punya KernelSU bawaan. Pakai KSU_SOURCE=next / sukisu, atau KSU=0."
			exit 1
		fi
		KSU_TAG="KSU"
		KSU_TEXT="On (bundled: ${KSU_KCONFIG})"
		;;
	next)
		clean_ksu
		echo "[*] Pasang KernelSU-Next (branch legacy untuk non-GKI)"
		curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s legacy
		KSU_TAG="KSUNEXT"
		KSU_TEXT="On (KernelSU-Next legacy, hook: ${KSU_HOOK})"
		;;
	sukisu)
		clean_ksu
		echo "[*] Pasang SukiSU-Ultra"
		curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s main
		KSU_TAG="SUKISU"
		KSU_TEXT="On (SukiSU-Ultra, hook: ${KSU_HOOK})"
		;;
	*)
		echo "[×] KSU_SOURCE='$KSU_SOURCE' tidak dikenal (auto|builtin|next|sukisu)"
		exit 1
		;;
	esac
	KSU_MODE="$mode"

	find_ksu_kconfig
	if [ -z "$KSU_KCONFIG" ]; then
		echo "[×] Setelah setup, Kconfig 'config KSU' tidak ditemukan. Integrasi gagal."
		exit 1
	fi
	if [ "$mode" != "builtin" ]; then
		if ! grep -qi kernelsu drivers/Makefile || ! grep -qi kernelsu drivers/Kconfig; then
			echo "[×] drivers/Makefile atau drivers/Kconfig belum memuat kernelsu."
			exit 1
		fi
	fi
	echo "[+] KernelSU: $KSU_TEXT"
	echo "    Kconfig : $KSU_KCONFIG"

	if [ "$KSU_HOOK" = "manual" ]; then
		if ! grep -qs 'ksu_handle_' fs/exec.c fs/open.c; then
			echo "[×] KSU_HOOK=manual, tetapi hook ksu_handle_* tidak ada di fs/exec.c / fs/open.c."
			echo "    Hook manual harus sudah ada di source. Pakai KSU_HOOK=kprobes."
			exit 1
		fi
	fi
}

notify_start()
{
	local msg
	msg="$(printf '%s' "$COMMIT_MSG" | esc)"
	tg_msg "$(printf '%s\n' \
		"<b>${KERNEL_NAME} build started</b>${GITHUB_RUN_NUMBER:+ - run #${GITHUB_RUN_NUMBER}}" \
		"<b>Device:</b> <code>${MODEL} (${DEVICE})</code>" \
		"<b>Kernel:</b> <code>${KERVER}</code>" \
		"<b>Defconfig:</b> <code>${DEFCONFIG}</code>" \
		"<b>Toolchain:</b> <code>${CLANG_VER}</code>" \
		"<b>Root:</b> <code>${KSU_TEXT}</code>" \
		"<b>Core:</b> <code>$(nproc --all)</code>" \
		"<b>Commit:</b> <code>${COMMIT_SHORT} - ${msg}</code>")" || true
}

build_kernel()
{
	cd "$KERNEL"

	export ARCH=arm64 SUBARCH=arm64
	export KBUILD_BUILD_USER="$AUTHOR"
	export KBUILD_BUILD_HOST="github-actions"
	[ -z "${CUSTOM_LOCALVERSION:-}" ] || export LOCALVERSION="$CUSTOM_LOCALVERSION"

	local ARGS=(
		O=out ARCH=arm64
		LLVM=1 LLVM_IAS="$LLVM_IAS"
		CC=clang HOSTCC=clang HOSTCXX=clang++
		PYTHON=python3
		CROSS_COMPILE="$CROSS64"
		CROSS_COMPILE_ARM32="$CROSS32"
		CLANG_TRIPLE="$CLANG_TRIPLE_V"
		KCFLAGS=-Wno-error
	)
	local CFG=(scripts/config --file out/.config)

	echo "[*] make defconfig"
	rm -rf out
	make "${ARGS[@]}" "$DEFCONFIG"

	local f
	for f in $FRAGMENTS; do
		echo "[*] Merge fragment: $f"
		scripts/kconfig/merge_config.sh -m -O out out/.config "arch/arm64/configs/$f"
	done

	# Wajib untuk mount modul root
	"${CFG[@]}" -e OVERLAY_FS
	# vDSO 32-bit sering gagal dengan clang
	"${CFG[@]}" -d COMPAT_VDSO

	if [ "$ENABLE_LTO" != "1" ]; then
		"${CFG[@]}" -d LTO_CLANG -d THINLTO -d CFI_CLANG -d CFI_PERMISSIVE
	fi

	if [ "$KSU" = "1" ]; then
		if [ "$KSU_HOOK" = "manual" ]; then
			"${CFG[@]}" -e KSU -e KSU_MANUAL_HOOK -d KPROBES
		else
			# KPROBES di 4.19 bergantung pada MODULES
			"${CFG[@]}" -e MODULES -e KPROBES -e KSU -d KSU_MANUAL_HOOK
		fi
	fi
	make "${ARGS[@]}" olddefconfig

	if [ "$KSU" = "1" ]; then
		echo "--- CONFIG root di out/.config ---"
		grep -E '^CONFIG_(KSU|OVERLAY_FS|KPROBES|MODULES|EXT4_FS)=' out/.config || true
		if ! grep -Eq '^CONFIG_KSU=y' out/.config; then
			echo "[×] CONFIG_KSU=y tidak aktif setelah olddefconfig (dependency tidak terpenuhi)."
			echo "    Dihentikan agar tidak menghasilkan kernel tanpa root."
			exit 1
		fi
		if [ "$KSU_HOOK" != "manual" ] && ! grep -Eq '^CONFIG_KPROBES=y' out/.config; then
			echo "[×] CONFIG_KPROBES=y tidak aktif. Hook kprobes tidak bisa dipakai di source ini."
			exit 1
		fi
		echo "[+] Root AKTIF"
	fi

	echo "[*] Mulai kompilasi"
	local START END targets
	if grep -Eq '^CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y' out/.config; then
		APPENDED=1
		targets="Image.gz-dtb"
	else
		APPENDED=0
		targets="Image.gz dtbs"
		echo "[!] APPENDED_DTB_IMAGE tidak aktif: DTB tidak digabung ke kernel."
	fi
	START=$(date +%s)
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" "${ARGS[@]}" $targets
	END=$(date +%s)
	BUILD_TIME="$(( (END-START)/60 ))m $(( (END-START)%60 ))s"

	KREL="$(make -s "${ARGS[@]}" kernelrelease 2>/dev/null | tail -n1 || true)"
	[ -n "$KREL" ] || KREL="$KERVER"

	local BOOT=out/arch/arm64/boot
	ls -la "$BOOT" || true
	KIMG=""
	for f in Image.gz-dtb Image.gz Image; do
		if [ -s "$BOOT/$f" ]; then KIMG="$f"; break; fi
	done
	if [ -z "$KIMG" ]; then
		echo "[×] Tidak ada Image hasil build di $BOOT"
		exit 1
	fi
	if [ "$APPENDED" = 1 ] && [ "$KIMG" != "Image.gz-dtb" ]; then
		echo "[×] APPENDED_DTB aktif tetapi Image.gz-dtb tidak terbentuk."
		exit 1
	fi
	echo "[+] Kernel berhasil dikompilasi dalam $BUILD_TIME ($KIMG)"
	echo "[+] kernelrelease: $KREL"
	echo "[!] Jika ROM memakai modul vendor (.ko), kernelrelease harus sama dengan kernel bawaan ROM."
}

# anykernel.sh khusus rolex/riva (boot partition tunggal, bukan A/B)
write_anykernel()
{
	cat > "$AK3/anykernel.sh" <<'AKEOF'
### AnyKernel3 Ramdisk Mod Script
## Shisouka Kernel - Redmi 4A (rolex) / Redmi 5A (riva)

## AnyKernel setup
# begin properties
properties() { '
kernel.string=Shisouka Kernel for Redmi 4A / 5A (rova)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=rolex
device.name2=riva
device.name3=rova
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables (huruf besar = AK3 baru, huruf kecil = AK3 lama)
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=0;
ramdisk_compression=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install: ganti kernel saja, ramdisk bawaan ROM dipertahankan
split_boot;
flash_boot;
AKEOF
}

gen_zip()
{
	local BOOT="$KERNEL/out/arch/arm64/boot"
	local STAMP NAME
	STAMP="$(date +%Y%m%d-%H%M)"
	NAME="${KERNEL_NAME}-${DEVICE}"
	[ -z "$KSU_TAG" ] || NAME="${NAME}-${KSU_TAG}"
	NAME="${NAME}-${STAMP}-${COMMIT_SHORT}.zip"

	write_anykernel
	echo "[*] anykernel.sh untuk rolex/riva:"
	grep -nE 'device\.name|BLOCK=|IS_SLOT_DEVICE' "$AK3/anykernel.sh" || true

	# Bersihkan sisa kernel lama (kalau ada) lalu salin hasil build
	rm -f "$AK3"/Image* "$AK3"/zImage* "$AK3"/*.img 2>/dev/null || true
	cp "$BOOT/$KIMG" "$AK3/$KIMG"
	ls -la "$AK3"

	echo "[*] Zipping into a flashable zip"
	mkdir -p "$OUTDIR"
	(cd "$AK3" && zip -r9 "$OUTDIR/$NAME" . -x ".git*" -x "README.md" -x "LICENSE" -x "*.zip")

	ZIP_FINAL="$OUTDIR/$NAME"
	ZIP_MD5="$(md5sum "$ZIP_FINAL" | cut -d' ' -f1)"
	echo "[+] Zip: $ZIP_FINAL"
}

send_zip()
{
	local size run_url="" caption
	size="$(stat -c%s "$ZIP_FINAL")"
	echo "[*] Ukuran zip: $size bytes"
	if [ -n "${GITHUB_RUN_ID:-}" ]; then
		run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
	fi

	caption="$(printf '%s\n' \
		"<b>${KERNEL_NAME}</b> for ${MODEL}" \
		"Kernel: <code>${KREL}</code>" \
		"Build time: <code>${BUILD_TIME}</code>" \
		"Root: <code>${KSU_TEXT}</code>" \
		"Commit: <code>${COMMIT_SHORT}</code>" \
		"MD5: <code>${ZIP_MD5}</code>")"

	if [ "$size" -gt 50000000 ]; then
		tg_msg "$(printf '%s\n%s\n%s' \
			"<b>${KERNEL_NAME}</b> build SUKSES, tetapi zip lebih dari 50MB (tidak bisa dikirim via bot)." \
			"$caption" \
			"${run_url:+<a href=\"${run_url}\">Download dari Artifacts</a>}")" || true
	else
		tg_doc "$ZIP_FINAL" "$caption" || tg_msg "$(printf '%s\n%s' \
			"<b>${KERNEL_NAME}</b> build SUKSES, tetapi upload zip gagal." \
			"${run_url:+<a href=\"${run_url}\">Download dari Artifacts</a>}")" || true
	fi
}

##------------------------------------------------------##
##------------------------ Main ------------------------##

tg_init
ensure_deps
clone_kernel
validate_defconfig
setup_toolchain
prepare_ksu
notify_start
build_kernel
gen_zip
send_zip

echo "[+] Selesai."

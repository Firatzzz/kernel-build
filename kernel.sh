#!/bin/bash
# shellcheck disable=SC2154
#
# Build Shisouka Kernel - Redmi 10C (fog / SM6225)
# Source : https://github.com/Firatzzz/kernel_xiaomi_sm6225 (branch ye)
# Dijalankan dari GitHub Actions:  bash kernel.sh
#
# Variabel environment (dari workflow):
#   KERNEL_BRANCH : branch source kernel (default: ye)
#   DEFCONFIG     : defconfig relatif terhadap arch/arm64/configs
#   FOG_CFG       : fragment config tambahan (opsional)
#   KSU           : 1 = aktifkan KernelSU | 0 = matikan
#   KSU_SOURCE    : builtin = pakai KernelSU bawaan source ye (default, tanpa patch)
#                   nadeko  = ganti dengan NadekoSU (butuh patchs/KernelSU.patch)
#   TG_BOT_TOKEN  : token bot Telegram (WAJIB dari GitHub Secrets)
#   TG_CHAT_ID    : chat id grup Telegram (dari GitHub Secrets)

set -eo pipefail

##------------------------------------------------------##
##----------------- Konfigurasi dasar ------------------##

WORKDIR="$(pwd)"
KERNEL="$WORKDIR/kernel"
TC="$WORKDIR/toolchain"
AK3="$WORKDIR/AnyKernel3"
OUTDIR="$WORKDIR/output"
LOG="$WORKDIR/error.log"

KERNEL_REPO="https://github.com/Firatzzz/kernel_xiaomi_sm6225"
KERNEL_BRANCH="${KERNEL_BRANCH:-ye}"
ANYKERNEL_REPO="https://github.com/Kentanglu/AnyKernel3-680"
CLANG_URL="https://github.com/ZyCromerZ/Clang/releases/download/17.0.0-20230725-release/Clang-17.0.0-20230725.tar.gz"
GCC64_REPO="https://github.com/ZyCromerZ/aarch64-linux-android-4.9"
GCC32_REPO="https://github.com/ZyCromerZ/arm-linux-androideabi-4.9"
NADEKO_SETUP_URL="https://raw.githubusercontent.com/dre698/NadekoSU/main/kernel/setup.sh"

KERNEL_NAME="Shisouka-Kernel"
AUTHOR="Firatz"
MODEL="Redmi 10C"
DEVICE="fog"

# Branch ye punya vendor/fog-perf_defconfig dan vendor/fog_ksu.config
DEFCONFIG="${DEFCONFIG:-vendor/fog-perf_defconfig}"
FOG_CFG="${FOG_CFG:-}"

# KernelSU. 1 = YES | 0 = NO
KSU="${KSU:-1}"
# builtin = KernelSU bawaan source (backslashxx, hook syscall table) | nadeko = NadekoSU
KSU_SOURCE="${KSU_SOURCE:-builtin}"

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
		echo "[!] TG_BOT_TOKEN / TG_CHAT_ID kosong. Set di GitHub Secrets. Telegram dilewati."
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

validate_defconfig()
{
	cd "$KERNEL"
	local cfg_dir="arch/arm64/configs"
	echo "[*] Defconfig diminta: $DEFCONFIG"

	if [ ! -f "$cfg_dir/$DEFCONFIG" ]; then
		echo "[!] $DEFCONFIG tidak ada, mencari pengganti otomatis..."
		local found="" cand
		for cand in vendor/fog-perf_defconfig vendor/bengal-perf_defconfig vendor/bengal_defconfig; do
			if [ -f "$cfg_dir/$cand" ]; then found="$cand"; break; fi
		done
		if [ -z "$found" ]; then
			echo "[×] Tidak ada defconfig yang cocok di branch '$BRANCH_NAME'."
			ls "$cfg_dir/vendor" 2>/dev/null | head -n 50 || true
			exit 1
		fi
		DEFCONFIG="$found"
	fi
	# bengal-perf TIDAK punya CONFIG_BUILD_ARM64_DT_OVERLAY, sehingga target
	# dtb.img/dtbo.img tidak ada ("No rule to make target 'dtb.img'").
	# Workflow sering masih mengirim DEFCONFIG=bengal-perf, jadi paksa ke fog-perf.
	case "$DEFCONFIG" in
		vendor/bengal-perf_defconfig|vendor/bengal_defconfig)
			if [ -f "$cfg_dir/vendor/fog-perf_defconfig" ]; then
				echo "[!] $DEFCONFIG diganti ke vendor/fog-perf_defconfig (butuh dtb.img/dtbo.img)"
				DEFCONFIG="vendor/fog-perf_defconfig"
			fi
			;;
	esac
	echo "[+] Defconfig dipakai: $DEFCONFIG"

	# Fragment KernelSU bawaan source ye hanya untuk mode builtin
	if [ "$KSU" = "1" ] && [ "$KSU_SOURCE" = "builtin" ] && [ -z "$FOG_CFG" ] \
		&& [ -f "$cfg_dir/vendor/fog_ksu.config" ]; then
		FOG_CFG="vendor/fog_ksu.config"
	fi
	if [ -n "$FOG_CFG" ] && [ -f "$cfg_dir/$FOG_CFG" ]; then
		echo "[+] Fragment dipakai: $FOG_CFG"
	else
		[ -z "$FOG_CFG" ] || echo "[!] Fragment $FOG_CFG tidak ada, dilewati"
		FOG_CFG=""
		echo "[*] Tanpa fragment tambahan, hanya $DEFCONFIG"
	fi
}

setup_toolchain()
{
	echo "[*] Download Clang"
	mkdir -p "$TC/clang"
	wget -q "$CLANG_URL" -O "$WORKDIR/clang.tar.gz"
	tar -xf "$WORKDIR/clang.tar.gz" -C "$TC/clang"
	rm -f "$WORKDIR/clang.tar.gz"

	local clang_bin
	clang_bin="$(find "$TC/clang" \( -type f -o -type l \) -name clang -path '*/bin/*' 2>/dev/null | head -n1 || true)"
	if [ -z "$clang_bin" ]; then
		echo "[×] clang tidak ditemukan. Isi hasil ekstrak:"
		find "$TC/clang" -maxdepth 3 | head -n 60 || true
		exit 1
	fi
	CLANG_DIR="$(dirname "$(dirname "$clang_bin")")"
	"$clang_bin" --version | head -n1 || true
	ls "$CLANG_DIR/bin" | grep -E '^(ld\.lld|llvm-ar|llvm-nm|llvm-objdump|llvm-strip)$' \
		|| echo "[!] sebagian tool llvm tidak ada"

	echo "[*] Clone GCC 4.9 (aarch64 & arm32)"
	git clone --depth=1 "$GCC64_REPO" "$TC/gcc64"
	git clone --depth=1 "$GCC32_REPO" "$TC/gcc32"

	echo "[*] Clone AnyKernel3"
	git clone --depth=1 "$ANYKERNEL_REPO" "$AK3"
}

# builtin : pakai KernelSU yang sudah ada di source ye (tanpa patch, tanpa download)
# nadeko  : buang KernelSU bawaan, pasang NadekoSU segar (butuh hook manual)
prepare_ksu()
{
	cd "$KERNEL"
	KSU_TEXT="Off"
	KSU_HOOK="none"

	if [ "$KSU" != "1" ]; then
		echo "[*] KernelSU dimatikan (KSU=$KSU)"
		return 0
	fi

	if [ "$KSU_SOURCE" = "builtin" ]; then
		echo "[*] Pakai KernelSU bawaan source"
		if [ ! -f drivers/kernelsu/Kconfig ] || ! grep -qi kernelsu drivers/Makefile \
			|| ! grep -qi kernelsu drivers/Kconfig; then
			echo "[×] KernelSU bawaan tidak lengkap di source ini (drivers/kernelsu, Makefile, Kconfig)."
			echo "    Gunakan KSU_SOURCE=nadeko atau KSU=0."
			exit 1
		fi
		KSU_HOOK="syscall-table"
		local info
		info="$(git log -1 --pretty=%s -- KernelSU 2>/dev/null | head -c 80 || true)"
		KSU_TEXT="On (bundled, hook: ${KSU_HOOK})"
		echo "[+] KernelSU: $KSU_TEXT"
		[ -z "$info" ] || echo "    Commit KernelSU terakhir: $info"
		return 0
	fi

	echo "[*] Bersihkan KernelSU bawaan source"
	rm -rf KernelSU drivers/kernelsu drivers/KernelSU
	sed -i '/kernelsu/Id' drivers/Makefile drivers/Kconfig

	echo "[*] Setup NadekoSU"
	curl -LSs "$NADEKO_SETUP_URL" | bash -

	if [ ! -f KernelSU/kernel/Kconfig ]; then
		echo "[×] Setup NadekoSU gagal: KernelSU/kernel/Kconfig tidak ada."
		exit 1
	fi
	if ! grep -qi kernelsu drivers/Makefile || ! grep -qi kernelsu drivers/Kconfig; then
		echo "[×] drivers/Makefile atau drivers/Kconfig belum memuat kernelsu."
		exit 1
	fi

	local cnt ver
	cnt="$(cd KernelSU && git rev-list --count HEAD 2>/dev/null || echo 0)"
	ver=$((33300 + cnt))

	# Kernel 4.19 hanya cocok dengan hook manual
	if ! grep -q "KSU_MANUAL_HOOK" KernelSU/kernel/Kconfig; then
		echo "[×] NadekoSU ini tidak punya KSU_MANUAL_HOOK. Tidak bisa dipakai di kernel 4.19."
		exit 1
	fi
	KSU_HOOK="manual"
	KSU_TEXT="On (NadekoSU ${ver}, hook: ${KSU_HOOK})"
	echo "[+] KernelSU: $KSU_TEXT"
}

# Hanya untuk NadekoSU: source ye TIDAK punya hook KernelSU apa pun,
# jadi patchs/KernelSU.patch wajib cocok dengan kernel 4.19.325 ini.
apply_ksu_patch()
{
	[ "$KSU" = "1" ] && [ "$KSU_HOOK" = "manual" ] || return 0
	cd "$KERNEL"

	local p="$WORKDIR/patchs/KernelSU.patch"
	if [ ! -f "$p" ]; then
		echo "[×] $p tidak ditemukan. NadekoSU butuh patch hook manual."
		exit 1
	fi

	if patch -p1 --dry-run < "$p" >/dev/null 2>&1; then
		patch -p1 < "$p"
		echo "[+] KernelSU.patch diterapkan"
	else
		echo "[×] KernelSU.patch tidak cocok dengan source ye (kernel $KERVER)."
		echo "    Pakai KSU_SOURCE=builtin atau buat ulang patch sesuai panduan NadekoSU."
		patch -p1 --dry-run < "$p" 2>&1 | head -n 30 || true
		exit 1
	fi

	# ekspor simbol static yang dibutuhkan KernelSU
	sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
	sed -i 's/^static ssize_t (\*const write_op\[\])/ssize_t (*const write_op[])/' security/selinux/selinuxfs.c
	sed -i 's/^static void security_dump_masked_av(/void security_dump_masked_av(/' security/selinux/ss/services.c
	sed -i 's/^static void context_struct_compute_av(/void context_struct_compute_av(/' security/selinux/ss/services.c
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
		"<b>KernelSU:</b> <code>${KSU_TEXT}</code>" \
		"<b>Core:</b> <code>$(nproc --all)</code>" \
		"<b>Commit:</b> <code>${COMMIT_SHORT} - ${msg}</code>")" || true
}

build_kernel()
{
	cd "$KERNEL"

	export PATH="$CLANG_DIR/bin:$TC/gcc64/bin:$TC/gcc32/bin:$PATH"
	export ARCH=arm64 SUBARCH=arm64
	export KBUILD_BUILD_USER="$AUTHOR"
	export KBUILD_BUILD_HOST="github-actions"
	export LOCALVERSION="-${KERNEL_NAME}"

	local ARGS=(
		O=out ARCH=arm64
		LLVM=1 LLVM_IAS=1
		CC=clang HOSTCC=clang HOSTCXX=clang++
		PYTHON=python3
		CROSS_COMPILE=aarch64-linux-android-
		CROSS_COMPILE_ARM32=arm-linux-androideabi-
		CLANG_TRIPLE=aarch64-linux-gnu-
		KCFLAGS=-Wno-error
	)

	echo "[*] make defconfig"
	rm -rf out
	make "${ARGS[@]}" "$DEFCONFIG"

	if [ -n "$FOG_CFG" ]; then
		echo "[*] Merge fragment: $FOG_CFG"
		scripts/kconfig/merge_config.sh -m -O out out/.config "arch/arm64/configs/$FOG_CFG"
	fi

	# Wajib untuk mount modul KernelSU
	scripts/config --file out/.config -e OVERLAY_FS

	# vDSO 32-bit gagal dengan clang
	scripts/config --file out/.config -d COMPAT_VDSO

	# Wajib agar target dtb.img & dtbo.img tersedia
	scripts/config --file out/.config -e BUILD_ARM64_DT_OVERLAY

	if [ "$KSU" = "1" ]; then
		if [ "$KSU_HOOK" = "manual" ]; then
			scripts/config --file out/.config \
				-e KSU -e KSU_MANUAL_HOOK \
				-e KSU_MANUAL_HOOK_AUTO_INPUT_HOOK \
				-e KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
				-e KSU_MANUAL_HOOK_AUTO_INITRC_HOOK
		else
			scripts/config --file out/.config -e KSU
		fi
	fi
	make "${ARGS[@]}" olddefconfig

	# Patch hook manual dilakukan setelah config siap (mode nadeko)
	apply_ksu_patch

	if ! grep -Eq '^CONFIG_BUILD_ARM64_DT_OVERLAY=y' out/.config; then
		echo "[×] CONFIG_BUILD_ARM64_DT_OVERLAY=y tidak aktif, dtb.img/dtbo.img tidak bisa dibuat."
		exit 1
	fi

	if [ "$KSU" = "1" ]; then
		echo "--- CONFIG KernelSU di out/.config ---"
		grep -E '^CONFIG_(KSU|OVERLAY_FS|KPROBES)' out/.config || true
		if ! grep -Eq '^CONFIG_KSU=y' out/.config; then
			echo "[×] CONFIG_KSU=y tidak aktif setelah olddefconfig. Dihentikan agar tidak menghasilkan kernel tanpa root."
			exit 1
		fi
		if [ "$KSU_HOOK" = "syscall-table" ] && ! grep -Eq '^CONFIG_KSU_TAMPER_SYSCALL_TABLE=y' out/.config; then
			echo "[×] CONFIG_KSU_TAMPER_SYSCALL_TABLE tidak aktif (bergantung !CFI_CLANG). Root tidak akan berfungsi."
			exit 1
		fi
		echo "[+] KernelSU AKTIF"
	fi

	echo "[*] Mulai kompilasi"
	local START END
	START=$(date +%s)
	make -j"$(nproc --all)" "${ARGS[@]}" Image.gz dtb.img dtbo.img
	END=$(date +%s)
	BUILD_TIME="$(( (END-START)/60 ))m $(( (END-START)%60 ))s"

	local BOOT=out/arch/arm64/boot f
	ls -la "$BOOT" || true
	for f in Image.gz dtb.img dtbo.img; do
		if [ ! -s "$BOOT/$f" ]; then
			echo "[×] File hasil build tidak ada: $BOOT/$f"
			exit 1
		fi
	done
	echo "[+] Kernel berhasil dikompilasi dalam $BUILD_TIME"
}

gen_zip()
{
	local BOOT="$KERNEL/out/arch/arm64/boot"
	local STAMP NAME
	STAMP="$(date +%Y%m%d-%H%M)"
	NAME="${KERNEL_NAME}-${DEVICE}"
	if [ "$KSU" = "1" ]; then
		if [ "$KSU_SOURCE" = "nadeko" ]; then NAME="${NAME}-NDKSU"; else NAME="${NAME}-KSU"; fi
	fi
	NAME="${NAME}-${STAMP}-${COMMIT_SHORT}.zip"

	echo "[*] Cek device di anykernel.sh"
	grep -nE 'device\.name|do\.devicecheck' "$AK3/anykernel.sh" || true
	if ! grep -qiE 'device\.name[0-9]*=(fog|wind|rain)' "$AK3/anykernel.sh"; then
		echo "[!] anykernel.sh tidak menyebut fog/wind/rain. Zip mungkin ditolak recovery."
	fi

	cp "$BOOT/Image.gz" "$AK3/Image.gz"
	cp "$BOOT/dtb.img"  "$AK3/dtb.img"
	cp "$BOOT/dtbo.img" "$AK3/dtbo.img"
	ls -la "$AK3"

	echo "[*] Zipping into a flashable zip"
	mkdir -p "$OUTDIR"
	(cd "$AK3" && zip -r9 "$OUTDIR/$NAME" . -x ".git*" -x "README.md" -x "*.zip")

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
		"Build time: <code>${BUILD_TIME}</code>" \
		"KernelSU: <code>${KSU_TEXT}</code>" \
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
clone_kernel
validate_defconfig
setup_toolchain
prepare_ksu
notify_start
build_kernel
gen_zip
send_zip

echo "[+] Selesai."

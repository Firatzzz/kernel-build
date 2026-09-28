#!/bin/bash
# shellcheck disable=SC2154
#
# Build Shisouka Kernel - Redmi 10C (fog / SM6225)
# Dijalankan dari GitHub Actions:  bash kernel.sh
#
# Variabel yang bisa di-override lewat environment (dari workflow):
#   KERNEL_BRANCH  : branch source kernel (kosong = default branch)
#   DEFCONFIG      : defconfig relatif terhadap arch/arm64/configs
#   KSU            : 1 = aktifkan KernelSU | 0 = matikan
#   TG_BOT_TOKEN   : token bot Telegram (sebaiknya dari GitHub Secrets)
#   TG_CHAT_ID     : chat id grup Telegram

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
KERNEL_BRANCH="${KERNEL_BRANCH:-}"
ANYKERNEL_REPO="https://github.com/Kentanglu/AnyKernel3-680"
CLANG_URL="https://github.com/ZyCromerZ/Clang/releases/download/17.0.0-20230725-release/Clang-17.0.0-20230725.tar.gz"
GCC64_REPO="https://github.com/ZyCromerZ/aarch64-linux-android-4.9"
GCC32_REPO="https://github.com/ZyCromerZ/arm-linux-androideabi-4.9"

# Nama kernel (dipakai untuk nama zip & LOCALVERSION)
KERNEL_NAME="Shisouka-Kernel"
AUTHOR="Firatz"
MODEL="Redmi 10C"
DEVICE="fog"

# Redmi 10C (SM6225) memakai bengal. fog-perf_defconfig tidak ada di source.
DEFCONFIG="${DEFCONFIG:-vendor/bengal-perf_defconfig}"

# KernelSU. 1 = YES | 0 = NO
KSU="${KSU:-1}"

# Push ke Telegram. 1 = YES | 0 = NO
PTTG=1
CHATID="${TG_CHAT_ID:-"-1004403448296"}"
# Disarankan: simpan token di GitHub Secrets (TG_BOT_TOKEN), lalu hapus nilai cadangan ini.
TOKEN="${TG_BOT_TOKEN:-8201939373:AAHYv-Yrl_TpqkBKr_HaAXAmSJVRzJfl08E}"

export TZ="Asia/Jakarta"

# Semua output (stdout + stderr) juga disimpan ke error.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

##------------------------------------------------------##
##-------------------- Telegram ------------------------##

TG_ENABLED=0

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# Memanggil API Telegram. Error ditampilkan (bukan disembunyikan).
tg_api()
{
	local method="$1"; shift
	local out
	out="$(curl -sS --max-time 180 "https://api.telegram.org/bot${TOKEN}/${method}" "$@" 2>&1)" || true
	if echo "$out" | grep -q '"ok":true'; then
		return 0
	fi
	echo "[!] Telegram ${method} GAGAL: $(echo "$out" | head -c 400)"
	return 1
}

tg_msg()
{
	[ "$TG_ENABLED" = 1 ] || return 0
	tg_api sendMessage \
		-d chat_id="$CHATID" -d parse_mode=HTML -d disable_web_page_preview=true \
		--data-urlencode text="$1"
}

tg_doc()
{
	[ "$TG_ENABLED" = 1 ] || return 0
	tg_api sendDocument \
		-F chat_id="$CHATID" -F parse_mode=HTML \
		-F document=@"$1" -F caption="$2"
}

# Validasi token & akses grup sebelum build dimulai
tg_init()
{
	if [ "$PTTG" != 1 ]; then return 0; fi
	if [ -z "$TOKEN" ]; then
		echo "[!] TOKEN kosong. Notifikasi Telegram dilewati."
		return 0
	fi

	local r
	r="$(curl -sS --max-time 30 "https://api.telegram.org/bot${TOKEN}/getMe" 2>&1 || true)"
	if ! echo "$r" | grep -q '"ok":true'; then
		echo "[!] Token ditolak Telegram (kemungkinan sudah dicabut/salah): $(echo "$r" | head -c 300)"
		return 0
	fi
	echo "[+] Bot OK: $(echo "$r" | grep -o '"username":"[^"]*"' || true)"

	r="$(curl -sS --max-time 30 "https://api.telegram.org/bot${TOKEN}/getChat" -d chat_id="$CHATID" 2>&1 || true)"
	if ! echo "$r" | grep -q '"ok":true'; then
		echo "[!] Chat ID $CHATID tidak bisa diakses bot: $(echo "$r" | head -c 300)"
		echo "[!] Pastikan bot sudah masuk grup dan ID grup benar."
		return 0
	fi
	echo "[+] Grup OK: $(echo "$r" | grep -o '"title":"[^"]*"' || true)"
	TG_ENABLED=1
}

# Dipanggil otomatis saat script keluar; kalau gagal, kirim log ke Telegram
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
	echo "[*] Clone kernel source"
	git clone --depth=1 ${KERNEL_BRANCH:+-b "$KERNEL_BRANCH"} "$KERNEL_REPO" "$KERNEL"
	cd "$KERNEL"

	COMMIT_SHORT="$(git rev-parse --short HEAD)"
	COMMIT_MSG="$(git log -1 --pretty=%s | tr -d '\r')"
	COMMIT_HEAD="$(git log --oneline -1)"
	BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD)"
	KERVER="$(make kernelversion 2>/dev/null || echo unknown)"
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
			echo "Isi $cfg_dir/vendor:"
			ls "$cfg_dir/vendor" 2>/dev/null | head -n 50 || true
			exit 1
		fi
		DEFCONFIG="$found"
	fi
	echo "[+] Defconfig dipakai: $DEFCONFIG"

	ls "$cfg_dir/vendor" 2>/dev/null | grep -E '\.config$' || true
	ls "$cfg_dir/vendor/xiaomi" 2>/dev/null | head -n 30 || true
}

setup_toolchain()
{
	echo "[*] Download Clang"
	mkdir -p "$TC/clang"
	wget -q "$CLANG_URL" -O "$WORKDIR/clang.tar.gz"
	tar -xf "$WORKDIR/clang.tar.gz" -C "$TC/clang"
	rm -f "$WORKDIR/clang.tar.gz"

	# Tarball bisa flat / punya folder induk; bin/clang biasanya symlink
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

prepare_ksu()
{
	cd "$KERNEL"
	KSU_TEXT="Off"
	# Source sudah berisi integrasi KernelSU dan vendor/ksu.config,
	# jadi setup.sh tiann/NadekoSU TIDAK dijalankan (akan bentrok).
	if [ "$KSU" = "1" ]; then
		if [ -d KernelSU ] || [ -d drivers/kernelsu ]; then
			KSU_TEXT="On"
		else
			echo "[!] Folder KernelSU tidak ditemukan di source, build tanpa KernelSU."
			KSU_TEXT="Off (source tanpa KernelSU)"
			KSU=0
		fi
	fi
	echo "[+] KernelSU: $KSU_TEXT"
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

	# Mengikuti build.sh upstream source ini (LLVM=1 LLVM_IAS=1)
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

	# Gabungkan fragment: konfigurasi khusus fog + KernelSU (bila ada)
	local FRAGS=()
	[ -f arch/arm64/configs/vendor/xiaomi/fog.config ] && FRAGS+=(arch/arm64/configs/vendor/xiaomi/fog.config)
	if [ "$KSU" = "1" ] && [ -f arch/arm64/configs/vendor/ksu.config ]; then
		FRAGS+=(arch/arm64/configs/vendor/ksu.config)
	fi
	if [ "${#FRAGS[@]}" -gt 0 ]; then
		echo "[*] Merge fragment: ${FRAGS[*]}"
		scripts/kconfig/merge_config.sh -m -O out out/.config "${FRAGS[@]}"
		make "${ARGS[@]}" olddefconfig
	fi

	# Verifikasi KernelSU benar-benar aktif di config akhir
	if [ "$KSU" = "1" ]; then
		echo "--- CONFIG KernelSU di out/.config ---"
		grep -E '^CONFIG_KSU' out/.config || true
		if grep -Eq '^CONFIG_KSU=y' out/.config; then
			echo "[+] KernelSU AKTIF (CONFIG_KSU=y)"
		else
			echo "[!] CONFIG_KSU=y tidak ditemukan. Build berjalan TANPA KernelSU."
			KSU_TEXT="Off (CONFIG_KSU tidak aktif)"
			KSU=0
		fi
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
	[ "$KSU" = "1" ] && NAME="${NAME}-KSU"
	NAME="${NAME}-${STAMP}-${COMMIT_SHORT}.zip"

	echo "[*] Cek device di anykernel.sh"
	grep -nE 'device\.name|do\.devicecheck' "$AK3/anykernel.sh" || true
	if ! grep -qiE 'device\.name[0-9]*=(fog|wind|rain)' "$AK3/anykernel.sh"; then
		echo "[!] anykernel.sh tidak menyebut fog/wind/rain. Zip mungkin ditolak recovery (device check)."
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

	# Batas upload Bot API = 50 MB
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

#!/bin/bash
# shellcheck disable=SC2154
#
# Build Shisouka Kernel - Redmi 10C (fog / SM6225)
# Source : https://github.com/Firatzzz/kernel_fog_shisouka
# Dijalankan dari GitHub Actions:  bash kernel.sh
#
# Variabel environment (dari workflow):
#   KERNEL_BRANCH : branch source kernel (default: main)
#   DEFCONFIG     : defconfig relatif terhadap arch/arm64/configs
#   FOG_CFG       : fragment config tambahan (opsional)
#   KSU           : 1 = aktifkan KernelSU | 0 = matikan
#   KSU_SOURCE    : nadeko  = NadekoSU + hook manual, dipasang otomatis (default)
#                   builtin = KernelSU bawaan source (hook syscall table)
#   TG_BOT_TOKEN  : token bot Telegram
#   TG_CHAT_ID    : chat id grup Telegram

set -eo pipefail

##------------------------------------------------------##
##----------------- Konfigurasi dasar ------------------##

WORKDIR="$(pwd)"
KERNEL="$WORKDIR/kernel"
TC="$WORKDIR/toolchain"
AK3="$WORKDIR/AnyKernel3"
OUTDIR="$WORKDIR/output"
LOG="$WORKDIR/error.log"

KERNEL_REPO="https://github.com/Firatzzz/kernel_fog_shisouka"
KERNEL_BRANCH="${KERNEL_BRANCH:-main}"
ANYKERNEL_REPO="https://github.com/Kentanglu/AnyKernel3-680"
CLANG_URL="https://github.com/ZyCromerZ/Clang/releases/download/17.0.0-20230725-release/Clang-17.0.0-20230725.tar.gz"
GCC64_REPO="https://github.com/ZyCromerZ/aarch64-linux-android-4.9"
GCC32_REPO="https://github.com/ZyCromerZ/arm-linux-androideabi-4.9"
NADEKO_SETUP_URL="https://raw.githubusercontent.com/dre698/NadekoSU/main/kernel/setup.sh"

KERNEL_NAME="Shisouka-Kernel-V2"
AUTHOR="Firatz"
MODEL="Redmi 10C"
DEVICE="fog"

# Defconfig fog-perf (punya CONFIG_BUILD_ARM64_DT_OVERLAY)
DEFCONFIG="${DEFCONFIG:-vendor/fog-perf_defconfig}"
FOG_CFG="${FOG_CFG:-}"

# KernelSU. 1 = YES | 0 = NO
KSU="${KSU:-1}"
# nadeko = NadekoSU + hook manual | builtin = KernelSU bawaan source (syscall table)
KSU_SOURCE="${KSU_SOURCE:-nadeko}"

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

	# Fragment KernelSU bawaan source hanya untuk mode builtin
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

# builtin : pakai KernelSU yang sudah ada di source (tanpa patch, tanpa download)
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

	# Kernel 4.19 hanya cocok dengan hook manual (dipasang di apply_ksu_patch)
	if ! grep -q "KSU_MANUAL_HOOK" KernelSU/kernel/Kconfig; then
		echo "[×] NadekoSU ini tidak punya KSU_MANUAL_HOOK. Tidak bisa dipakai di kernel 4.19."
		exit 1
	fi
	KSU_HOOK="manual"
	KSU_TEXT="On (NadekoSU ${ver}, hook: ${KSU_HOOK})"
	echo "[+] KernelSU: $KSU_TEXT"
}

# FIX: "can't open file drivers/input/touchscreen/st/Kconfig"
# Source di repo kadang punya baris `source "path/Kconfig"` yang filenya tidak
# ikut ter-commit (folder driver hilang / submodule belum di-init). Akibatnya
# `make defconfig` langsung berhenti. Di sini:
#   1) submodule (bila ada) di-init dulu
#   2) setiap Kconfig yang direferensikan tapi tidak ada dibuatkan stub kosong
# Catatan: stub hanya meloloskan konfigurasi. Bila driver yang hilang memang
# dipakai device (mis. touchscreen ST), source-nya tetap harus dikembalikan
# ke repo supaya fiturnya berfungsi.
fix_missing_kconfig()
{
	cd "$KERNEL"

	if [ -f .gitmodules ]; then
		echo "[*] Init submodule"
		git submodule update --init --depth=1 --recursive || echo "[!] submodule gagal di-init"
	fi

	echo "[*] Cek referensi 'source' Kconfig yang hilang"
	local p miss=0
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		if [ ! -f "$p" ]; then
			echo "[!] Kconfig hilang: $p -> dibuat stub kosong"
			mkdir -p "$(dirname "$p")"
			printf '# stub dibuat otomatis oleh kernel.sh (source asli tidak ada di repo)\n' > "$p"
			miss=1
		fi
	done < <(grep -rhoE --include='Kconfig*' --exclude-dir=.git \
		'^[[:space:]]*source[[:space:]]+"[^"$]+"' . \
		| sed -E 's/^[[:space:]]*source[[:space:]]+"//; s/"$//' | sort -u)

	if [ "$miss" = 0 ]; then
		echo "[+] Semua source Kconfig lengkap"
	else
		echo "[!] Ada Kconfig yang di-stub. Pastikan driver terkait memang tidak dibutuhkan."
	fi
}

# NadekoSU (kernel 4.19) butuh hook manual. Source TIDAK punya hook KernelSU
# apa pun (KernelSU bawaannya memakai syscall table), jadi hook dipasang di sini
# langsung ke: fs/exec.c, fs/open.c, fs/stat.c, kernel/reboot.c.
# Hook setuid / init.rc / input ditangani otomatis lewat LSM & input_handler
# (opsi KSU_MANUAL_HOOK_AUTO_*), jadi tidak perlu edit kernel/sys.c,
# fs/read_write.c, atau drivers/input/input.c.
apply_ksu_patch()
{
	[ "$KSU" = "1" ] && [ "$KSU_HOOK" = "manual" ] || return 0
	cd "$KERNEL"

	command -v python3 >/dev/null 2>&1 || { echo "[×] python3 tidak ditemukan (dibutuhkan untuk memasang hook)."; exit 1; }

	local hp="$WORKDIR/ksu_hooks.py"
	cat > "$hp" <<'PYEOF'
"""Pasang hook manual NadekoSU ke kernel 4.19 (idempotent, gagal keras bila anchor tidak cocok)."""
import re, sys, os

root = sys.argv[1] if len(sys.argv) > 1 else "."
fail = []

def edit(path, fn, marker, desc):
    p = os.path.join(root, path)
    s = open(p, encoding="utf-8", errors="surrogateescape").read()
    if marker in s:
        print(f"[=] {path}: {desc} sudah ada")
        return
    n = fn(s)
    if n is None or n == s:
        fail.append(f"{path}: {desc}")
        print(f"[x] {path}: {desc} GAGAL (anchor tidak cocok)")
        return
    open(p, "w", encoding="utf-8", errors="surrogateescape").write(n)
    print(f"[+] {path}: {desc}")

def sub1(pattern, repl, s, flags=re.M | re.S):
    n, c = re.subn(pattern, repl, s, count=1, flags=flags)
    return n if c == 1 else None

# ---- fs/exec.c : do_execveat_common (wrapper -> __do_execve_file)
def exec_fn(s):
    decl = ("#ifdef CONFIG_KSU\n"
            "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n"
            "\t\t\t\tvoid *envp, int *flags);\n"
            "#endif\n\n")
    pat = r"(static int do_execveat_common\(int fd, struct filename \*filename,\s*struct user_arg_ptr argv,\s*struct user_arg_ptr envp,\s*int flags\)\s*\{\n)(\treturn __do_execve_file\(fd, filename, argv, envp, flags, NULL\);)"
    def r(m):
        return (decl + m.group(1) +
                "#ifdef CONFIG_KSU\n\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n#endif\n" +
                m.group(2))
    return sub1(pat, r, s)
edit("fs/exec.c", exec_fn, "ksu_handle_execveat", "hook execveat")

# ---- fs/open.c : do_faccessat
def open_fn(s):
    decl = ("#ifdef CONFIG_KSU\n"
            "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n"
            "\t\t\t\t int *__unused_flags);\n"
            "#endif\n\n")
    pat = r"(/\*\n \* access\(\) needs to use the real uid/gid.*?\n \*/\n)?(long do_faccessat\(int dfd, const char __user \*filename, int mode\)\n\{\n(?:.*?\n)*?\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n)"
    m = re.search(pat, s, re.S)
    if not m:
        return None
    start = m.start()
    # sisipkan deklarasi sebelum blok komentar/fungsi, dan call setelah deklarasi variabel
    head = s[:m.start()]
    block = m.group(0)
    call = "\n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n"
    block = block + call
    return head + decl + block + s[m.end():]
edit("fs/open.c", open_fn, "ksu_handle_faccessat", "hook faccessat")

# ---- fs/stat.c : vfs_statx, newfstat, fstat64
def stat_fn(s):
    decl = ("#ifdef CONFIG_KSU\n"
            "extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n"
            "extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);\n"
            "#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)\n"
            "extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);\n"
            "#endif\n"
            "#endif\n\n")
    # 1) deklarasi sebelum blok komentar vfs_statx
    pat = r"(/\*\*\n \* vfs_statx - Get basic and extra attributes by filename)"
    n = sub1(pat, lambda m: decl + m.group(1), s)
    if n is None: return None
    s = n
    # 2) call di awal vfs_statx (setelah deklarasi variabel)
    pat = (r"(int vfs_statx\(int dfd, const char __user \*filename, int flags,\s*struct kstat \*stat, u32 request_mask\)\n\{\n"
           r"\tstruct path path;\n\tint error = -EINVAL;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW \| LOOKUP_AUTOMOUNT;\n)")
    n = sub1(pat, lambda m: m.group(1) + "\n#ifdef CONFIG_KSU\n\tksu_handle_stat(&dfd, &filename, &flags);\n#endif\n", s)
    if n is None: return None
    s = n
    # 3) newfstat
    pat = (r"(SYSCALL_DEFINE2\(newfstat, unsigned int, fd, struct stat __user \*, statbuf\)\n\{\n"
           r"\tstruct kstat stat;\n\tint error = vfs_fstat\(fd, &stat\);\n\n\tif \(!error\)\n\t\terror = cp_new_stat\(&stat, statbuf\);\n)(\n\treturn error;)")
    n = sub1(pat, lambda m: m.group(1) + "\n#ifdef CONFIG_KSU\n\tksu_handle_newfstat_ret(&fd, &statbuf);\n#endif\n" + m.group(2), s)
    if n is None: return None
    s = n
    # 4) fstat64
    pat = (r"(SYSCALL_DEFINE2\(fstat64, unsigned long, fd, struct stat64 __user \*, statbuf\)\n\{\n"
           r"\tstruct kstat stat;\n\tint error = vfs_fstat\(fd, &stat\);\n\n\tif \(!error\)\n\t\terror = cp_new_stat64\(&stat, statbuf\);\n)(\n\treturn error;)")
    n = sub1(pat, lambda m: m.group(1) + "\n#ifdef CONFIG_KSU\n\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n" + m.group(2), s)
    return n
edit("fs/stat.c", stat_fn, "ksu_handle_stat", "hook stat/newfstat/fstat64")

# ---- kernel/reboot.c : reboot syscall
def reboot_fn(s):
    decl = ("#ifdef CONFIG_KSU\n"
            "extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n"
            "#endif\n\n")
    pat = r"(SYSCALL_DEFINE4\(reboot, int, magic1, int, magic2, unsigned int, cmd,\s*void __user \*, arg\)\n\{\n\tstruct pid_namespace \*pid_ns = task_active_pid_ns\(current\);\n\tchar buffer\[256\];\n\tint ret = 0;\n)"
    return sub1(pat, lambda m: decl + m.group(1) + "\n#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n", s)
edit("kernel/reboot.c", reboot_fn, "ksu_handle_sys_reboot", "hook reboot")

if fail:
    print("\n[x] Hook gagal dipasang:\n  " + "\n  ".join(fail))
    sys.exit(1)
print("[+] Semua hook manual terpasang")
PYEOF
	echo "[*] Pasang hook manual NadekoSU"
	python3 "$hp" "$KERNEL" || { echo "[×] Pemasangan hook gagal, source berbeda dari yang diperkirakan."; exit 1; }

	# Verifikasi sama seperti manual_hook_check.mk milik NadekoSU
	local miss=0 pair f h
	for pair in \
		"fs/exec.c:ksu_handle_execveat" \
		"fs/open.c:ksu_handle_faccessat" \
		"fs/stat.c:ksu_handle_stat" \
		"fs/stat.c:ksu_handle_newfstat_ret" \
		"fs/stat.c:ksu_handle_fstat64_ret" \
		"kernel/reboot.c:ksu_handle_sys_reboot"; do
		f="${pair%%:*}"; h="${pair##*:}"
		if grep -q "$h" "$f"; then echo "[+] hook $h ada di $f"; else echo "[×] hook $h HILANG di $f"; miss=1; fi
	done
	[ "$miss" = 0 ] || exit 1

	# KALLSYMS_ALL tidak bisa aktif di defconfig ini (butuh DEBUG_KERNEL), maka
	# NadekoSU meminta simbol SELinux diekspor (hapus 'static'), sesuai
	# tools/static_export_check.mk. Kernel 4.19 hanya butuh dua simbol ini.
	echo "[*] Ekspor simbol static SELinux"
	sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
	sed -i 's/^static ssize_t (\*const write_op\[\])/ssize_t (*const write_op[])/' security/selinux/selinuxfs.c
	if grep -q '^static const struct file_operations sel_handle_status_ops' security/selinux/selinuxfs.c \
		|| ! grep -q '^const struct file_operations sel_handle_status_ops' security/selinux/selinuxfs.c; then
		echo "[×] sel_handle_status_ops gagal diekspor di security/selinux/selinuxfs.c"
		exit 1
	fi
	if grep -q '^static ssize_t (\*const write_op\[\])' security/selinux/selinuxfs.c \
		|| ! grep -q '^ssize_t (\*const write_op\[\])' security/selinux/selinuxfs.c; then
		echo "[×] write_op gagal diekspor di security/selinux/selinuxfs.c"
		exit 1
	fi
	echo "[+] sel_handle_status_ops dan write_op diekspor"
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
				-e KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
				-d KSU_TRACEPOINT_HOOK -d KSU_SUSFS
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
		if [ "$KSU_HOOK" = "manual" ]; then
			if ! grep -Eq '^CONFIG_KSU_MANUAL_HOOK=y' out/.config; then
				echo "[×] CONFIG_KSU_MANUAL_HOOK=y tidak aktif setelah olddefconfig."
				exit 1
			fi
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
fix_missing_kconfig
notify_start
build_kernel
gen_zip
send_zip

echo "[+] Selesai."

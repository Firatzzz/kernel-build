#!/bin/bash
# shellcheck disable=SC2154

 # Script For Building Android arm64 Kernel
 #
 # Copyright (c) 2018-2021 Panchajanya1999 <rsk52959@gmail.com>
 #
 # Licensed under the Apache License, Version 2.0 (the "License");
 # you may not use this file except in compliance with the License.
 # You may obtain a copy of the License at
 #
 #      http://www.apache.org/licenses/LICENSE-2.0
 #
 # Unless required by applicable law or agreed to in writing, software
 # distributed under the License is distributed on an "AS IS" BASIS,
 # WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 # See the License for the specific language governing permissions and
 # limitations under the License.
 #

# Kernel building script
WORKDIR="$(pwd)"
KERNEL="$WORKDIR/kernel"

# Cloning Sources
git clone --single-branch --depth=1 https://github.com/ahmadsyahputra1222-boop/kernel_fog -b motregen $KERNEL && cd $KERNEL

# Bail out if script fails
set -e

# Function to show an informational message
msger()
{
	while getopts ":n:e:" opt
	do
		case "${opt}" in
			n) printf "[*] $2 \n" ;;
			e) printf "[×] $2 \n"; return 1 ;;
		esac
	done
}

cdir()
{
	cd "$1" 2>/dev/null || msger -e "The directory $1 doesn't exists !"
}

##------------------------------------------------------##
##----------Basic Informations, COMPULSORY--------------##

# The defult directory where the kernel should be placed
KERNEL_DIR="$(pwd)"
BASEDIR="$(basename "$KERNEL_DIR")"

# The name of the Kernel, to name the ZIP
ZIPNAME="Clover-test-v1"

# Build Author
# Take care, it should be a universal and most probably, case-sensitive
AUTHOR="Aspfork"

# Architecture
ARCH=arm64

# The name of the device for which the kernel is built
MODEL="Redmi 10C"

# The codename of the device
DEVICE="fog"

# The defconfig which should be used. Get it from config.gz from
# your device or check source
DEFCONFIG="vendor/bengal-perf_defconfig vendor/xiaomi/fog.config"

# Specify compiler.
# 'clang' or 'gcc'
COMPILER=clang

# Build modules. 0 = NO | 1 = YES
MODULES=0

# Specify linker.
# 'ld.lld'(default)
LINKER=ld.lld

# Clean source prior building. 1 is NO(default) | 0 is YES
INCREMENTAL=0

# Push ZIP to Telegram. 1 is YES | 0 is NO(default)
PTTG=1
if [ $PTTG = 1 ]
then
	# Set Telegram Chat ID
	CHATID="-1003984906981"
	TOKEN="8958541727:AAFJuU7mysRCS6TlXQtqZvrrR-pJd3zvt9c"
fi

# Generate a full DEFCONFIG prior building. 1 is YES | 0 is NO(default)
DEF_REG=0

# Files/artifacts
FILES=Image.gz

# Build dtbo.img (select this only if your source has support to building dtbo.img)
# 1 is YES | 0 is NO(default)
BUILD_DTBO=0

# PATCH KERNELSU
KSU=1
if [ $KSU = 1 ]
then
# kernel_fog ships an old vendored KernelSU/ copy, setup.sh would reuse it instead of cloning NadekoSU
rm -rf KernelSU drivers/kernelsu
curl -LSs "https://raw.githubusercontent.com/dre698/NadekoSU/main/kernel/setup.sh" | bash -
KSU_GIT_VERSION=$(cd KernelSU && git rev-list --count HEAD)
KERNELSU_VERSION=$((33300 + $KSU_GIT_VERSION))
# Pick hook method depending on what this NadekoSU version supports
if grep -q "KSU_MANUAL_HOOK" KernelSU/kernel/Kconfig
then
	KSU_HOOK=manual
else
	KSU_HOOK=branchlink
	DEFCONFIG="$DEFCONFIG vendor/ksu.config"
fi
echo "[+] KernelSU hook method: $KSU_HOOK"
fi

# Sign the zipfile
# 1 is YES | 0 is NO
SIGN=0
if [ $SIGN = 1 ]
then
	#Check for java
	if ! hash java 2>/dev/null 2>&1; then
		SIGN=0
		msger -n "you may need to install java, if you wanna have Signing enabled"
	else
		SIGN=1
	fi
fi

# Silence the compilation
# 1 is YES(default) | 0 is NO
SILENCE=0

# Verbose build
# 0 is Quiet(default)) | 1 is verbose | 2 gives reason for rebuilding targets
VERBOSE=0

# Debug purpose. Send logs on every successfull builds
# 1 is YES | 0 is NO(default)
LOG_DEBUG=0

##------------------------------------------------------##
##---------Do Not Touch Anything Beyond This------------##

# Check if we are using a dedicated CI ( Continuous Integration ), and
# set KBUILD_BUILD_VERSION and KBUILD_BUILD_HOST and CI_BRANCH

## Set defaults first

# shellcheck source=/etc/os-release
export DISTRO=$(source /etc/os-release && echo "${NAME}")
export KBUILD_BUILD_HOST=$(uname -a | awk '{print $2}')
TERM=xterm

#Check Kernel Version
KERVER=$(make kernelversion)

# Set a commit head
COMMIT_HEAD=$(git log --oneline -1)

# Set Date
DATE=$(TZ=Asia/Jakarta date +"%Y%m%d-%T")
WAKTU=$(date +"%F-%S")

#Now Its time for other stuffs like cloning, exporting, etc

 clone()
 {
	echo " "
	if [ $COMPILER = "gcc" ]
	then
		msger -n "|| Cloning GCC 9.3.0 baremetal ||"
		git clone --depth=1 https://github.com/mvaisakh/gcc-arm64.git gcc64
		git clone --depth=1 https://github.com/arter97/arm32-gcc.git gcc32
		GCC64_DIR=$KERNEL_DIR/gcc64
		GCC32_DIR=$KERNEL_DIR/gcc32
	fi

	if [ $COMPILER = "clang" ]
	then
                git clone https://gitlab.com/ElectroPerf/atom-x-clang clang-llvm --depth=1
		git clone https://github.com/ZyCromerZ/aarch64-linux-android-4.9 gcc64 --depth=1
                git clone https://github.com/ZyCromerZ/arm-linux-androideabi-4.9 gcc32 --depth=1
		GCC64_DIR=$KERNEL_DIR/gcc64
		GCC32_DIR=$KERNEL_DIR/gcc32
                for64=aarch64-linux-android
                for32=arm-linux-androideabi
		ClangMoreStrings="AR=llvm-ar NM=llvm-nm AS=llvm-as STRIP=llvm-strip OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf HOSTAR=llvm-ar HOSTAS=llvm-as LD_LIBRARY_PATH=$clangDir/lib LD=ld.lld HOSTLD=ld.lld"
		# Toolchain Directory defaults to clang-llvm
		TC_DIR=$KERNEL_DIR/clang-llvm
  		export LLVM=1
		export LLVM_IAS=1
                export LD_LIBRARY_PATH=$TC_DIR/bin/:$GCC64_DIR/bin/:$GCC32_DIR/bin/:$LD_LIBRARY_PATH
	fi

	msger -n "|| Cloning Anykernel ||"
	git clone --depth=1 https://github.com/alternoegraha/AnyKernel3-680 -b master AnyKernel3

	if [ $BUILD_DTBO = 1 ]
	then
		msger -n "|| Cloning libufdt ||"
		git clone https://android.googlesource.com/platform/system/libufdt "$KERNEL_DIR"/scripts/ufdt/libufdt
	fi
}

##------------------------------------------------------##

exports()
{
	KBUILD_BUILD_USER=$AUTHOR
	SUBARCH=$ARCH

	if [ $COMPILER = "clang" ]
	then
		KBUILD_COMPILER_STRING=$("$TC_DIR"/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')
		PATH=$TC_DIR/bin/:$GCC64_DIR/bin/:$GCC32_DIR/bin/:/usr/bin:$PATH
	elif [ $COMPILER = "gcc" ]
	then
		KBUILD_COMPILER_STRING=$("$GCC64_DIR"/bin/aarch64-elf-gcc --version | head -n 1)
		PATH=$GCC64_DIR/bin/:$GCC32_DIR/bin/:/usr/bin:$PATH
	fi

	BOT_MSG_URL="https://api.telegram.org/bot$TOKEN/sendMessage"
	BOT_BUILD_URL="https://api.telegram.org/bot$TOKEN/sendDocument"
	PROCS=$(nproc --all)

	export KBUILD_BUILD_USER ARCH SUBARCH PATH \
	       KBUILD_COMPILER_STRING BOT_MSG_URL \
	       BOT_BUILD_URL PROCS
}

##---------------------------------------------------------##

tg_post_msg()
{
	curl -s -X POST "$BOT_MSG_URL" -d chat_id="$CHATID" \
	-d "disable_web_page_preview=true" \
	-d "parse_mode=Markdown" \
	-d text="$1"

}

##----------------------------------------------------------##

tg_post_build()
{
	# Post MD5Checksum alongwith for easeness
	MD5CHECK=$(md5sum "$1" | cut -d' ' -f1)

	# Show the Checksum alongwith caption
	curl --progress-bar -F document=@"$1" "$BOT_BUILD_URL" \
	-F chat_id="$CHATID"  \
	-F "disable_web_page_preview=true" \
	-F "parse_mode=Markdown" \
	-F caption="$2 | *MD5 Checksum : *\`$MD5CHECK\`"
}

##----------------------------------------------------------##

build_kernel()
{
	if [ $INCREMENTAL = 0 ]
	then
		msger -n "|| Cleaning Sources ||"
		make mrproper && rm -rf out
fi

if [ "$PTTG" = 1 ]; then
    BUILD_DATE=$(TZ=Asia/Jakarta date)
    TG_MSG="*CI Build Triggered*%0A"
    TG_MSG+="*Docker OS:* \`$DISTRO\`%0A"
    TG_MSG+="*Kernel Version:* \`$KERVER\`%0A"
    TG_MSG+="*Date:* \`$BUILD_DATE\`%0A"
    TG_MSG+="*Device:* \`$MODEL [$DEVICE]\`%0A"
    TG_MSG+="*Host Core Count:* \`$PROCS\`%0A"
    TG_MSG+="*Compiler Used:* \`$KBUILD_COMPILER_STRING\`%0A"
    TG_MSG+="*KernelSU Version:* \`$KERNELSU_VERSION\`%0A"
    TG_MSG+="*Top Commit:* \`$COMMIT_HEAD\`"
    
    tg_post_msg "$TG_MSG"
fi

make O=out $DEFCONFIG

# Disable 32-bit compat vDSO (fails to build with clang: __NR_compat_* undeclared)
scripts/config --file out/.config -d COMPAT_VDSO
if [ "$KSU" = "1" ] && [ "$KSU_HOOK" = "manual" ]
then
	scripts/config --file out/.config \
		-e KSU -e KSU_MANUAL_HOOK \
		-e KSU_MANUAL_HOOK_AUTO_INPUT_HOOK \
		-e KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
		-e KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
		-d KSU_HACK_ARM64_BRANCH_LINK
fi
make O=out olddefconfig
if [ $DEF_REG = 1 ]; then

		cp .config arch/arm64/configs/$DEFCONFIG
		git add arch/arm64/configs/$DEFCONFIG
		git commit -m "$DEFCONFIG: Regenerate

						This is an auto-generated commit"
	fi


if [ "$KSU" = "1" ] && [ "$KSU_HOOK" = "manual" ]
then
	cp -r "$WORKDIR/patchs" "$KERNEL_DIR/"
	patch -p1 < "$KERNEL_DIR/patchs/KernelSU.patch"
	# static symbol export (KALLSYMS_ALL gets dropped without DEBUG_KERNEL)
	sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
	sed -i 's/^static ssize_t (\*const write_op\[\])/ssize_t (*const write_op[])/' security/selinux/selinuxfs.c
	sed -i 's/^static void security_dump_masked_av(/void security_dump_masked_av(/' security/selinux/ss/services.c
	sed -i 's/^static void context_struct_compute_av(/void context_struct_compute_av(/' security/selinux/ss/services.c
fi

BUILD_START=$(date +"%s")

	if [ $COMPILER = "clang" ]
	then
		MAKE+=(
  			CC=clang \
			CROSS_COMPILE=$for64- \
			CROSS_COMPILE_ARM32=$for32- \
   			CLANG_TRIPLE=aarch64-linux-gnu- \
        		HOSTCC=gcc \
	  		HOSTCXX=g++ ${ClangMoreStrings}
	) 
	elif [ $COMPILER = "gcc" ]
	then
		MAKE+=(
			CROSS_COMPILE_ARM32=arm-eabi- \
			CROSS_COMPILE=aarch64-elf- \
			AR=aarch64-elf-ar \
			OBJDUMP=aarch64-elf-objdump \
			STRIP=aarch64-elf-strip \
			NM=aarch64-elf-nm \
			OBJCOPY=aarch64-elf-objcopy \
			LD=aarch64-elf-$LINKER
		)
	fi

	if [ $SILENCE = "1" ]
	then
		MAKE+=( -s )
	fi

	msger -n "|| Started Compilation ||"
	make -kj"$PROCS" O=out \
		V=$VERBOSE \
		"${MAKE[@]}" 2>&1 | tee error.log
	if [ $MODULES = "1" ]
	then
	    msger -n "|| Started Compiling Modules ||"
	    make -j"$PROCS" O=out \
		 "${MAKE[@]}" modules_prepare
	    make -j"$PROCS" O=out \
		 "${MAKE[@]}" modules INSTALL_MOD_PATH="$KERNEL_DIR"/out/modules
	    make -j"$PROCS" O=out \
		 "${MAKE[@]}" modules_install INSTALL_MOD_PATH="$KERNEL_DIR"/out/modules
	    find "$KERNEL_DIR"/out/modules -type f -iname '*.ko' -exec cp {} AnyKernel3/modules/system/lib/modules/ \;
	fi

		BUILD_END=$(date +"%s")
		DIFF=$((BUILD_END - BUILD_START))

		if [ -f "$KERNEL_DIR"/out/arch/arm64/boot/$FILES ]
		then
			msger -n "|| Kernel successfully compiled ||"
			if [ $BUILD_DTBO = 1 ]
			then
				msger -n "|| Building DTBO ||"
				tg_post_msg "\`Building DTBO..\`"
				python2 "$KERNEL_DIR/scripts/ufdt/libufdt/utils/src/mkdtboimg.py" \
					create "$KERNEL_DIR/out/arch/arm64/boot/dtbo.img" --page_size=4096 "$KERNEL_DIR/out/arch/arm64/boot/dts/$DTBO_PATH"
			fi
				gen_zip
			else
			if [ "$PTTG" = 1 ]
 			then
				tg_post_build "error.log" "*Build failed to compile after $((DIFF / 60)) minute(s) and $((DIFF % 60)) seconds*"
			fi
		fi

}

##--------------------------------------------------------------##

gen_zip()
{
	msger -n "|| Zipping into a flashable zip ||"
	mv "$KERNEL_DIR"/out/arch/arm64/boot/$FILES AnyKernel3/$FILES
	if [ $BUILD_DTBO = 1 ]
	then
		mv "$KERNEL_DIR"/out/arch/arm64/boot/dtbo.img AnyKernel3/dtbo.img
	fi
	cdir AnyKernel3
	zip -r $DEVICE-$ZIPNAME-"$WAKTU" . -x ".git*" -x "README.md" -x "*.zip"

	## Prepare a final zip variable
	ZIP_FINAL="$DEVICE-$ZIPNAME-$WAKTU"

	if [ $SIGN = 1 ]
	then
		## Sign the zip before sending it to telegram
		if [ "$PTTG" = 1 ]
 		then
 			msger -n "|| Signing Zip ||"
			tg_post_msg "\`Signing Zip file with AOSP keys..\`"
 		fi
		curl -sLo zipsigner-3.0.jar https://github.com/Magisk-Modules-Repo/zipsigner/raw/master/bin/zipsigner-3.0-dexed.jar
		java -jar zipsigner-3.0.jar "$ZIP_FINAL".zip "$ZIP_FINAL"-signed.zip
		ZIP_FINAL="$ZIP_FINAL-signed"
	fi

	if [ "$PTTG" = 1 ]
 	then
		tg_post_build "$ZIP_FINAL.zip" "Build took : $((DIFF / 60)) minute(s) and $((DIFF % 60)) second(s)"
	fi
	cd ..
}

clone
exports
build_kernel

if [ $LOG_DEBUG = "1" ]
then
	tg_post_build "error.log" "$CHATID" "Debug Mode Logs"
fi

##----------------*****-----------------------------##

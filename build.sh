#!/bin/sh
set -e

WORKDIR=$(pwd)
VERSION="10.4p1"
PREFIX="/storage/Users/currentUser/openssh-${VERSION}-ohos-arm64"

# 如果存在旧的目录和文件，就清理掉
# 仅清理工作目录，不清理系统目录，因为默认用户每次使用新的容器进行构建（仓库中的构建指南是这么指导的）
rm -rf *.tar.gz \
    deps \
    "openssh-${VERSION}" \
    "openssh-${VERSION}-ohos-arm64"

# 下载一些命令行工具，并将它们软链接到 bin 目录中
cd /opt
echo "coreutils 9.10
busybox 1.37.0
grep 3.12
gawk 5.3.2
make 4.4.1
tar 1.35
gzip 1.14
perl 5.42.0" >/tmp/tools.txt
while read -r name ver; do
    curl -fLO https://github.com/Harmonybrew/ohos-$name/releases/download/$ver/$name-$ver-ohos-arm64.tar.gz
done </tmp/tools.txt
ls | grep tar.gz$ | xargs -n 1 tar -zxf
rm -rf *.tar.gz
ln -sf $(pwd)/*-ohos-arm64/bin/* /bin/

# 准备 ohos-sdk
curl -fL -o ohos-sdk-full_6.1-Release.tar.gz https://cidownload.openharmony.cn/version/Master_Version/OpenHarmony_6.1.0.31/20260311_020435/version-Master_Version-OpenHarmony_6.1.0.31-20260311_020435-ohos-sdk-full_6.1-Release.tar.gz
tar -zxf ohos-sdk-full_6.1-Release.tar.gz
rm -rf ohos-sdk-full_6.1-Release.tar.gz ohos-sdk/windows ohos-sdk/linux
cd ohos-sdk/ohos
busybox unzip -q native-*.zip
busybox unzip -q toolchains-*.zip
rm -rf *.zip
cd $WORKDIR

# 把 llvm 里面的命令封装一份放到 /bin 目录下，只封装必要的工具。
# 为了照顾 clang （clang 软链接到其他目录使用会找不到 sysroot），
# 对所有命令统一用这种封装的方案，而非软链接。
essential_tools="clang
clang++
clang-cpp
ld.lld
lldb
llvm-addr2line
llvm-ar
llvm-cxxfilt
llvm-nm
llvm-objcopy
llvm-objdump
llvm-ranlib
llvm-readelf
llvm-size
llvm-strings
llvm-strip"
for executable in $essential_tools; do
    cat <<EOF > /bin/$executable
#!/bin/sh
exec /opt/ohos-sdk/ohos/native/llvm/bin/$executable "\$@"
EOF
    chmod 0755 /bin/$executable
done

# 把 llvm 软链接成 cc、gcc 等命令
cd /bin
ln -s clang cc
ln -s clang gcc
ln -s clang++ c++
ln -s clang++ g++
ln -s ld.lld ld
ln -s llvm-addr2line addr2line
ln -s llvm-ar ar
ln -s llvm-cxxfilt c++filt
ln -s llvm-nm nm
ln -s llvm-objcopy objcopy
ln -s llvm-objdump objdump
ln -s llvm-ranlib ranlib
ln -s llvm-readelf readelf
ln -s llvm-size size
ln -s llvm-strip strip

mkdir $WORKDIR/deps
cd $WORKDIR/deps

# 编 openssl
curl -fLO https://github.com/openssl/openssl/releases/download/openssl-3.6.1/openssl-3.6.1.tar.gz
tar -zxf openssl-3.6.1.tar.gz
cd openssl-3.6.1
# 修改证书目录和聚合文件路径，让它能在 OpenHarmony 平台上正确地找到证书
sed -i 's|OPENSSLDIR "/certs"|"/etc/ssl/certs"|' include/internal/common.h
sed -i 's|OPENSSLDIR "/cert.pem"|"/etc/ssl/certs/cacert.pem"|' include/internal/common.h
./Configure \
    --prefix=/opt/deps \
    --openssldir=/etc/ssl \
    no-legacy \
    no-module \
    no-shared \
    no-engine \
    linux-aarch64
make -j$(nproc)
make install_sw
cd ..

# 编 zlib
curl -fLO https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
tar -zxf zlib-1.3.1.tar.gz
cd zlib-1.3.1
./configure --prefix=/opt/deps --static
make -j$(nproc)
make install
cd ..

cd $WORKDIR

# 编译 openssh
curl -fLO https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${VERSION}.tar.gz
tar -zxf openssh-${VERSION}.tar.gz
cd openssh-${VERSION}

# 应用 OHOS 补丁
for patch_file in $WORKDIR/Patches/openssh/*.patch; do
    patch -p1 < "$patch_file"
done

# 替换 @@HOMEBREW_PREFIX@@ 占位符为实际 prefix
for f in pathnames.h defines.h ssh-agent.c sshd.c sshd-auth.c; do
    if [ -f "$f" ]; then
        sed -i "s|@@HOMEBREW_PREFIX@@|${PREFIX}|g" "$f"
    fi
done

./configure \
    --prefix="${PREFIX}" \
    --sysconfdir="${PREFIX}/etc/ssh" \
    --without-pam \
    --without-ldns \
    --without-libedit \
    --without-kerberos5 \
    --without-shadow \
    --with-ssl-dir=/opt/deps \
    --without-openssl-header-check \
    --with-zlib=/opt/deps \
    --without-stackprotect \
    --with-hardening=no \
    --with-sandbox=no \
    --disable-etc-default-login \
    --disable-lastlog \
    --disable-libutil \
    --disable-pututline \
    --disable-pututxline \
    --disable-strip \
    --disable-utmp \
    --disable-utmpx \
    --disable-wtmp \
    --disable-wtmpx \
    --with-privsep-path="${PREFIX}/var/lib/sshd" \
    --with-pid-dir="${PREFIX}/var/run" \
    --with-default-path="${PREFIX}/bin" \
    ac_cv_header_linux_if_tun_h=no
make -j$(nproc)
make install-nokeys

# 创建符号链接 slogin -> ssh
ln -sf "${PREFIX}/bin/ssh" "${PREFIX}/bin/slogin"

# 创建 var 目录
mkdir -p "${PREFIX}/var/lib/sshd"
mkdir -p "${PREFIX}/var/run"

# 清理旧的 .default 配置文件，让下面的 sed 能匹配到原始内容
rm -f "${PREFIX}/etc/ssh/ssh_config.default" "${PREFIX}/etc/ssh/sshd_config.default"

# 对 sshd_config 进行定制
SSHD_CONFIG="${PREFIX}/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    # OHOS: sandbox 下目录属主不可变，关掉 StrictModes
    sed -i 's/^#\?StrictModes yes$/StrictModes no/' "$SSHD_CONFIG"
    # OHOS: 没有 PAM，只允许公钥认证
    sed -i 's/^#\?PasswordAuthentication yes$/PasswordAuthentication no/' "$SSHD_CONFIG"
    # OHOS: 非特权端口 8022 替代 22
    sed -i 's/^#\?Port 22$/Port 8022/' "$SSHD_CONFIG"
    # OHOS: 修正 sftp-server 路径
    sed -i 's|^Subsystem\s\+sftp\s\+/usr/libexec/sftp-server|Subsystem\t'"${PREFIX}"'/libexec/sftp-server|' "$SSHD_CONFIG"
fi

# 生成主机密钥
"${PREFIX}/bin/ssh-keygen" -A
for key in "${PREFIX}/etc/ssh/ssh_host_"*_key; do
    if [ -f "$key" ]; then
        chmod 0644 "$key"
    fi
done

# 安装 moduli（如果不存在）
if [ -f "moduli" ] && [ ! -f "${PREFIX}/etc/ssh/moduli" ]; then
    cp "moduli" "${PREFIX}/etc/ssh/moduli"
fi

cd $WORKDIR

# 进行代码签名
cd "${PREFIX}"
find . -type f \( -perm -0111 -o -name "*.so*" \) | while read FILE; do
    if file -b "$FILE" | grep -iqE "elf|sharedlib|ELF|shared object"; then
        echo "Signing binary file $FILE"
        ORIG_PERM=$(stat -c %a "$FILE")
        /opt/ohos-sdk/ohos/toolchains/lib/binary-sign-tool sign -inFile "$FILE" -outFile "$FILE" -selfSign 1
        chmod "$ORIG_PERM" "$FILE"
    fi
done
cd $WORKDIR

# 履行开源义务，把使用的开源软件的 license 全部聚合起来放到制品中
cat <<EOF > "${PREFIX}/licenses.txt"
This document describes the licenses of all software distributed with the
bundled application.
==========================================================================

openssh
=============
$(cat openssh-${VERSION}/LICENCE)

openssl
=============
$(cat deps/openssl-3.6.1/LICENSE.txt)
$(cat deps/openssl-3.6.1/AUTHORS.md)

zlib
=============
$(cat deps/zlib-1.3.1/LICENSE)
EOF

# 打包最终产物
cp -r "${PREFIX}" "openssh-${VERSION}-ohos-arm64"
tar -zcf "openssh-${VERSION}-ohos-arm64.tar.gz" "openssh-${VERSION}-ohos-arm64"

# 这一步是针对手动构建场景做优化。
# 在 docker run --rm -it 的用法下，有可能文件还没落盘，容器就已经退出并被删除，从而导致压缩文件损坏。
# 使用 sync 命令强制让文件落盘，可以避免那种情况的发生。
sync

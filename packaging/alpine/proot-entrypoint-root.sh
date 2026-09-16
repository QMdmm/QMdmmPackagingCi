#!/bin/sh
# Alpine v3.24 虚拟根入口（proot，全程零 root）—— QMdmm APKBUILD 线专用
#   alpine              进 shell（伪 root，apk 装包用这个身份）
#   alpine <cmd>        跑单条命令（伪 root）
#   alpine-abuild <..>  abuild 专用（proot 无 -S 绑定，改用 -r；-i 与 -S/-0 冲突）
# 必须：env HOME=/root —— 否则宿主 ~/.abuild 会被 -S 的 $HOME bind 带进来遮蔽
# guest /root/.abuild（同 fedora 线 ~/.rpmmacros 坑）。
export LD_LIBRARY_PATH="$HOME/.local/proot/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export PROOT_NO_SECCOMP=1
PROOT="$HOME/.local/proot/usr/bin/proot"
ROOTFS="$HOME/alpine-rootfs"
[ -x "$PROOT" ] || { echo "proot 缺失: $PROOT" >&2; exit 1; }
[ -d "$ROOTFS/usr" ] || { echo "rootfs 未建或损坏: $ROOTFS" >&2; exit 1; }
if [ $# -eq 0 ]; then
  exec "$PROOT" -S "$ROOTFS" env HOME=/root TERM="${TERM:-xterm}" /bin/sh -l
else
  exec "$PROOT" -S "$ROOTFS" env HOME=/root "$@"
fi

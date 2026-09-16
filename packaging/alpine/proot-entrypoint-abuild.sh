#!/bin/sh
# abuild 身份入口：proot 里 -i/-0/-S 三者共享一个槽位，只有最后一个生效，
# 所以伪造 uid 100:100 时必须放弃 -S 的手势，显式给 -r 和绑定。
# 文件系统权限反而更松：rootfs 全部是宿主普通用户所有，proot 不做 fs 翻译时
# 真实 uid(1001) 对它们有完整写权，chown 失败由 abuild 自带的 fakeroot 兜底。
export LD_LIBRARY_PATH="$HOME/.local/proot/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export PROOT_NO_SECCOMP=1
PROOT="$HOME/.local/proot/usr/bin/proot"
ROOTFS="$HOME/alpine-rootfs"
if [ $# -eq 0 ]; then
  exec "$PROOT" -i 100:100 -r "$ROOTFS" -b /dev -b /proc -b /sys -b /tmp \
    env HOME=/root TERM="${TERM:-xterm}" /bin/sh -l
else
  exec "$PROOT" -i 100:100 -r "$ROOTFS" -b /dev -b /proc -b /sys -b /tmp \
    env HOME=/root "$@"
fi

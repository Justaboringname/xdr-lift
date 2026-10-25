# XDRLift

*[English](README.md)*

_Last updated: 2026-10-25_

让 Apple XDR 显示器（为 2026 款 Studio Display XDR 写的）的 SDR 亮度常态突破苹果的室内上限。做法是乘一个固定倍数，所以控制中心和键盘上的原生亮度调节照常能用。

Studio Display XDR 只在环境光传感器判断房间很亮时，才放开 1000 nits 的 SDR 亮度。XDRLift 的做法：

1. 在屏幕角落放一个 1×1、几乎透明的 EDR 窗口，向系统申请 2.0× 余量，让 macOS 把屏幕切到 EDR 模式。这时 SDR 白（1.0）只占整个亮度范围的一部分，剩下的是余量 `H`；
2. 把这块屏幕的 gamma（transfer）表整体乘以 `k^(1/2.2)`，SDR 白就被推进余量里，大约变成原生亮度的 `k` 倍。

实际倍数取 `min(k, 0.95·H)`。EDR 没开、屏幕休眠、锁屏、屏保运行时都回到 1。把原生亮度调低，`H` 会变大，所以输出还是跟着原生亮度走。gamma 表作用在窗口合成之后，所以切 Space、调度中心期间提亮不中断，鼠标指针也一起变亮，截图里也不会带上提亮效果。进程退出时 WindowServer 会自动恢复 gamma 表，`kill -9` 也一样。

## 使用

```sh
make            # 编译出 build/XDRLift.app
make selftest   # 每 2 秒在 1.0× 和 1.4× 之间切换，共 12 秒，记录余量和 gamma 表，然后退出
make install    # 复制到 /Applications 并启动
/Applications/XDRLift.app/Contents/MacOS/XDRLift --login on   # 开机自启（菜单里也能开）
```

菜单栏的太阳图标提供这些功能：
- 开关提亮，任何地方按 ⌃⌥⌘B 都行；
- 调倍数（1.00–1.60×，每台显示器分别记住）；
- 开机自启。

Vivid、BetterDisplay、Lunar、BrightIntosh 或 f.lux 在运行，或者有别的程序反复改 gamma 表时，菜单里会显示提醒。

日志写在系统统一日志里：

```sh
/usr/bin/log stream --predicate 'subsystem == "com.justaboringname.xdrlift"'
defaults write com.justaboringname.xdrlift trace -bool true   # 重启 app 后每 50 ms 记录一次状态
```

## 注意事项

- 屏幕上出现 HDR 内容时会自动暂停提亮。只要本进程挂着 gamma 表（哪怕是原样的表），EDR 内容就会被截在 SDR 白，所以之前开着 XDRLift 时 HDR 视频看起来和普通视频一样。现在只要有别的内容申请比触发窗口的 2.0× 更多的余量（HDR 视频、HDR 照片），提亮就渐暗退出，gamma 表交还给系统；HDR 内容消失约 15 秒后（macOS 降余量比较慢）再恢复提亮。另外，提亮停在 1× 时也会把表交还给系统。
- gamma 表里存的是 gamma 编码后的值。判断依据：用 EDR 1.4× 的白场做参照，和 gamma 表乘 1.10–1.46 的 SDR 白轮流切换，结果低端（≈ 1.4^(1/2.2) = 1.165）最不闪。这是肉眼判断，没有仪器测量，`k` 按眼睛挑就行。
- 如果别的程序写了 gamma 表（Vivid、f.lux、Lunar 等），XDRLift 会先让开，停在 1×。等 gamma 表连续 30 秒没人再改，就恢复提亮。如果写进来的是没提亮的普通表（比如换了颜色配置文件、唤醒后系统重新加载），就以它为新基准，在上面渐变提亮回去。
- 亮度 nits 数是估算（SDR 白 ≈ `2000 / H`），没有实测。
- 第一版用的是全屏 `multiply` 叠加层。WindowServer 播放切 Space 动画时不合成叠加层，所以每次 Ctrl+←/→ 屏幕都会暗大约 1 秒；那一版的鼠标指针也不提亮，截图里还会带上提亮效果。

## 许可

MIT

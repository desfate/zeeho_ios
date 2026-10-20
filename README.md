# iOS 极核签到

Mac 版 [zeeho](https://github.com/desfate/macOS_for_zeeho_auto_signin) 的 iOS 移植：用你自己已经登录的 Token 做每日签到，并在主屏幕小组件上显示积分和车辆。

非官方个人工具，与极核 / 春风动力无关。本机 Token 写在 `Shared/LocalToken.swift`，该文件已 gitignore。App 和小组件都会编译进这份 Token。

## 能做什么

- 还没签到就签到，签过就只刷新状态。流程与 Mac 版脚本一致：先看 `lastTime` 是不是今天，未签才 POST，再查一次确认。
- 可以保存多个账号。主屏幕小组件（小 / 中 / 大）和锁屏小组件会列出每个账号的签到、积分；只有一个账号时仍显示连签、电量、续航。
- **小组件自动打卡**：系统刷新小组件时，每个今天还没签的账号都会直接请求签到。过了零点，小组件会先变成「今日未签到」，随后再签。
- 打开过 App 后注册后台刷新，尽量在每天 08:30（上海）前后再跑一次。
- 快捷指令「极核签到」可以做成每天 08:30 的自动化，这是 iOS 上最稳的定时方式。

iOS 不允许 App 像 Mac 的 launchd 那样准点醒来。小组件刷新和后台刷新都由系统决定时间；要卡在 08:30，用快捷指令自动化。

## 打开

需要 Xcode 15+，iOS 17+。

```bash
open ZeehoSignin.xcodeproj
```

jie的 iPhone 已经连着这台电脑。装到手机上还要你本人做两件事：

1. Xcode → Settings → Accounts → 左下角加号 → 用 Apple ID 登录（免费账号即可）。然后选中 App 和小组件两个 target，Signing 勾上 Automatically manage signing，Team 选 Personal Team。
2. 在 iPhone 上打开「设置 → 隐私与安全性 → 开发者模式」，打开后按提示重启，并在手机上确认。

完成后，运行目标选 jie的 iPhone，再按运行。

## 填 Token

当前这台电脑的 Mac 版 Token 已经写进 `Shared/LocalToken.swift`，第一次打开会把它收成第一个账号。再加账号时，在 App 里点「添加账号」，粘贴另一段 Authorization。只需要 UUID。已有账号不会被覆盖。

官方 App 是单会话，别处使用同一个 Token 可能把手机上的极核 App 挤下线。

## 加上自动打卡

1. 长按主屏幕，添加「极核签到」小组件。
2. 想准点：快捷指令 → 自动化 → 特定时间 → 每天 08:30 → 运行「极核签到」。
3. 小组件上的「签到」会立刻再请求一次。

接口如果返回 `30125`，在 App 底部「签名密钥」里更新 H5 密钥。那是公开客户端的签名参数，不是登录 Token。

## 目录

```
Shared/            签到、签名、状态，App 和小组件共用
ZeehoSignin/       主 App、后台刷新
ZeehoWidget/       小组件
```

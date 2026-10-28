# Codex 本地初始化模拟：hosts / SOCKS5 双模式

Windows 10/11，Node.js 18+ 已安装并位于 PATH。只用 Node 内置模块和系统 PowerShell，**没有 npm/pip 依赖需要安装，Python 不需要使用**。

双击 `start.cmd` 后选择 **1 = hosts** 或 **2 = SOCKS5**，再同意管理员提示。也可以在 CMD 执行 `start.cmd hosts` / `start.cmd s5` 跳过菜单。首次自动生成并信任本机证书，通过 WMI 独立启动 Node；关闭 CMD 或 Codex 不会结束服务。

## hosts 模式

监听 `127.0.0.1:443`，自动备份 hosts 并添加 `127.0.0.1 ab.chatgpt.com`，不启动 SOCKS5。端口 443 被占用或发现已有该域名映射时会报错，不覆盖其他服务。若安装过旧包，请先用旧包停止并恢复。

此模式要求应用使用本地解析并直连该域名；系统代理、Proxifier 或 v2rayN/TUN 若接管连接，需要为该域名及本地回环设置绕过，并停用原先指向本包 1089 的规则。脚本不修改代理软件设置。

## SOCKS5 模式

1. 选择 2 启动，不添加 hosts 映射。
2. Proxifier → Proxy Servers：添加 **SOCKS5 / 127.0.0.1 / 1089**，不启用用户名密码认证。它只支持下面的指定目标，通用代理检查访问其他网站失败是预期行为。
3. Proxification Rules：添加规则，Applications 选择实际发请求的 Codex 程序（当前版本 `ChatGPT.exe`）；Target hosts 填 `ab.chatgpt.com`，Target ports 填 `443`，Action 选上述本地 SOCKS5，规则置于通用代理规则之前。
4. Name Resolution：启用 **Resolve hostnames through proxy**，保证 SOCKS 请求携带 `ab.chatgpt.com` 原始域名。不要让该域名落入本地 DNS 排除名单。不同 Proxifier 版本选项名称可能略有不同。
5. 给 **node.exe → 127.0.0.1 → 18443** 配置 `Direct`，放在通用规则之前，避免转接程序的内部连接再次被代理。保留本地代理端口本身的回环直连规则。
6. 若此前安装过旧 hosts 包，先用旧包的 `停止并恢复.cmd` 撤销它，并确认 hosts 没有 `ab.chatgpt.com` 的旧条目。本模式不新增 hosts 映射，不自动改代理软件。
7. 重启 Codex，查看 `requests.jsonl` 是否出现 `POST /v1/initialize`、`status:200`，再核对界面。
8. 停用时双击 `stop.cmd` 并禁用对应代理规则。两种模式共用此停止脚本：停止本包进程，移除本包 hosts 标记块及本包添加的证书信任，保留其他 hosts 内容；不会停止其他 Node 进程。切换模式请先 stop.cmd 再 start.cmd，运行时选择不同模式会提示停止。

SOCKS5 连接路径：`Codex → SOCKS5 127.0.0.1:1089 → HTTPS 127.0.0.1:18443`。客户端 URL、TLS SNI 仍为 `ab.chatgpt.com`。只接受 SOCKS5 域名型 CONNECT `ab.chatgpt.com:443`，不支持 IP 型目标、其他网站或其他端口。两种模式使用相同的初始化内容；HTTPS 路由只提供模拟初始化及诊断接收，不代理聊天或账户接口。

## 配置 JSON

当前配置包含 **4 个功能开关、2 个配置层，共 7 个参数**。下表记录的是本地模拟服务器的下发值，不是恢复出的官方历史响应。功能含义依据此前对当前版本客户端读取逻辑的核对。

原记录的配置源文件：[overrides.json](D:/wd/随便聊聊/output/codex-init-mock/overrides.json)。本包实际读取 `server.cjs` 同目录的 [overrides.json](./overrides.json)，内容如下：

```json
{
  "feature_gates": {
    "3085093835": true,
    "410065390": true,
    "410262010": true,
    "1506311413": true
  },
  "layer_configs": {
    "72216192": { "enable_i18n": true, "locale_source": "SYSTEM" },
    "741821319": { "enabled": true }
  },
  "dynamic_configs": {}
}
```

### 配置文件与初始化响应

配置文件直接保存功能开关的布尔值和配置层的参数对象。服务器生成初始化响应时，将每项配置放入 `value` 字段。例如，文件中的 `feature_gates.3085093835` 对应响应中的 `feature_gates.3085093835.value`。编辑配置文件时，不要额外添加 `value` 包装。

`feature_gates` 有 4 个布尔开关。`layer_configs` 有 2 个配置层，其中 `72216192` 包含 2 个参数，`741821319` 包含 1 个参数。`dynamic_configs` 当前为空，不增加参数。

### 各参数的下发值与作用范围

下面路径均以初始化响应 JSON 为起点，`value` 是客户端实际读取的值。

| 配置路径 | 下发原文 | 对应含义与作用范围 |
| --- | --- | --- |
| `feature_gates.3085093835.value` | `true` | 开启新版导航相关逻辑，包括 Work／Codex 导航分支。Work 登录方式与可用性另行检查，因此不保证单凭它就显示切换入口。 |
| `feature_gates.410065390.value` | `true` | 开启外部 Chrome／Chromium 浏览器控制功能的实验开关。仍依赖 `browser_use_external`、实际配置要求和运行环境。 |
| `feature_gates.410262010.value` | `true` | 开启 Codex 内置浏览器的代理操作功能。仍依赖 `browser_use`、内置浏览器能力和实际配置要求。 |
| `feature_gates.1506311413.value` | `true` | 开启桌面 Computer Use 功能的实验开关。仍检查 `computer_use`、系统支持、权限及适用的账户条件。 |
| `layer_configs.72216192.value.enable_i18n` | `true` | 启用界面国际化／翻译初始化。即使本地已设置中文，这一层关闭也可能导致界面没有中文翻译。 |
| `layer_configs.72216192.value.locale_source` | `"SYSTEM"` | 指定系统语言来源策略。这个值本身不是“强制中文”。原记录中的本机另有 `localeOverride = "zh-CN"`，它不属于此 JSON 的 7 个参数。 |
| `layer_configs.741821319.value.enabled` | `true` | 开启内置 Computer Use 插件自动安装逻辑。它不代表插件已经安装成功，也不直接授予控制权限。 |

### 修改与生效

编辑本包的 `overrides.json`，保留有效 JSON 格式。布尔值使用 `true` 或 `false`，不要加引号。语言来源使用字符串，例如 `"SYSTEM"`。

服务器每次处理初始化请求时重新读取配置，无需重启服务。客户端需要再次请求初始化才会读取新值，可重启 Codex 后核对。配置开关不替代插件、账户、组织、权限或运行环境要求，未配置功能采用客户端默认值。

## 运行文件与排错

首次启动会自动生成 `server.pfx`、`server.cer`、`runtime.json`，证书有效期 90 天。它们只属于本机；复制到其他设备时只复制压缩包中的七个文件，不要复制生成的证书或 runtime.json。证书到期后先停止，再删除这三个生成文件，重新启动即可。私钥及密码留在本地，不写入日志。`setup.log` 是启停诊断，`server-error.log` 是启动错误，`requests.jsonl` 不保存请求正文、查询参数或密钥。

遇到连接失败，双击 `status.cmd` 查看端口、HTTPS 健康检查及最近日志。`socks.jsonl` 记录代理握手阶段：没有 connected 表示请求没到本服务；domain_required_enable_proxy_dns 表示客户端传了 IP，需要启用通过代理解析域名；target_not_allowed 表示目标不是 ab.chatgpt.com:443；tunnel_ready 表示已连上内部 HTTPS；tls_error 表示客户端 TLS 握手失败，需要结合浏览器错误和证书状态判断。更新本包时先 stop.cmd，覆盖压缩包中的文件，再 start.cmd；保留本机生成的证书和 runtime.json。

可在本目录执行 `node server.cjs status` 检查进程与初始化计数。这里的检查直接使用本包证书验证本地 HTTPS，不测试 Proxifier 规则。完整验证需要观察 Proxifier 连接日志及真实 Codex 初始化请求。

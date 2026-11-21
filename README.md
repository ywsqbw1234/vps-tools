# VPS 节点与私密订阅管理

本仓库维护德国 VPS 的 Cloudflare 优选 IP、固定节点列表和完整分流规则。服务器读取公开配置，结合本机私密节点配置，生成现有 HTTPS 订阅。

**GitHub 保存脚本、IP 和规则；节点凭据及完整订阅只保存在服务器。**

## 日常使用

以下命令在已配置好的德国 VPS 上以 root 执行，不是在 Windows PowerShell 中执行。

| 目的 | 命令 |
| --- | --- |
| 更新固定 IP、自动优选 IP 和规则 | `update-cf-subscription` |
| 只更新规则，不修改节点 IP | `update-cf-subscription --rules-only` |
| 更新固定 IP 和规则，保留自动优选 IP | `update-cf-subscription --fixed-only` |
| 只检查规则，不发布 | `update-cf-subscription --rules-only --dry-run` |
| 完整测速与检查，不发布 | `update-cf-subscription --dry-run` |
| 仅导出服务器当前配置，不下载规则或测速 | `export-private-subscriptions` |

原来的 GitHub 脚本入口继续有效：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ywsqbw1234/vps-tools/main/cfsub_v10_germany.sh)
```

只更新规则：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ywsqbw1234/vps-tools/main/cfsub_v10_germany.sh) --rules-only
```

成功后在客户端点击“更新订阅”，HTTPS 地址不变。更新命令不重启代理、不更换凭据、不切换客户端节点。客户端应用新订阅时如何处理已有连接，取决于客户端自身。

## 文件说明

| 文件 | 功能 |
| --- | --- |
| [cf_fixed_ip.txt](cf_fixed_ip.txt) | 手工固定的 Cloudflare IP/域名 |
| [cf_custom_rules.txt](cf_custom_rules.txt) | 完整分流规则，按原顺序匹配 |
| [cfsub_v10_germany.sh](cfsub_v10_germany.sh) | 调用已安装的更新器，支持传递参数 |
| [update_cf_subscription.py](update_cf_subscription.py) | 下载配置、优选 IP、校验和发布订阅 |
| [export_private_subscriptions.py](export_private_subscriptions.py) | 结合本机凭据与私密模板导出订阅 |
| [cfsub_v10_1.sh](cfsub_v10_1.sh) | 旧版兼容入口，仅调用已安装的导出器 |
| [test_update_cf_subscription.py](test_update_cf_subscription.py) | IP、规则解析和失败回退等测试 |

## 修改固定 IP

1. 在 GitHub 编辑 `cf_fixed_ip.txt`，提交到 `main`。
2. 在德国 VPS 运行 `update-cf-subscription --fixed-only`，或运行完整更新命令。
3. 客户端更新订阅。

格式为“名称 地址”，名称可省略。支持公网 IPv4、域名和可选端口，默认 443：

```text
# 示例地址，请按客户端实际线路测试
提供商A 104.16.1.1
备用 162.159.44.19:443
```

空行和整行 `#` 注释被忽略，同地址同端口去重，最多 100 条。固定节点按文件顺序保留，不因探测失败删除，因此不保证每个固定节点在线。

`yx`、`japan2` 两个名称还用于同步对应的 `CF-WARP` 节点地址。此列表用于德国 CF 节点，不自动修改私密配置中的日本节点 IP。

## 自动优选 IP

默认从 Cloudflare 官方 IPv4 网段测试 80 个候选 IP，使用 8 个测速线程，选取 12 个通过 TLS/WebSocket 校验的地址，不执行大文件下载测速。

```bash
update-cf-subscription --candidates 80 --keep-top 12
```

`--keep-top` 范围 1–24；`--candidates` 不小于保留数量，最大 160。可加 `--fixed-file /root/my-fixed-ip.txt` 使用本地固定列表。

测速在德国 VPS 执行，不能保证这些地址在家庭宽带或手机网络上也最快。客户端体验不佳时，可使用手工固定节点进行对比。

## 修改完整分流规则

`cf_custom_rules.txt` 是完整列表，不是增量文件。首次接入时包含全部 131 条原有规则，顺序不变。

1. 在 GitHub 修改文件，提交到 `main`。
2. 执行 `update-cf-subscription --rules-only --dry-run` 检查输出。
3. 执行 `update-cf-subscription --rules-only` 发布。
4. 客户端更新订阅，并使用规则模式。

每行一条，支持空行和整行 `#` 注释。靠前的匹配规则优先，具体规则应放在可能覆盖它的通用规则之前。最后必须保留唯一一条 `MATCH` 兜底规则。

```text
# 示例：添加到适当位置，不要用示例替换整个文件
DOMAIN-SUFFIX,example.com,Google
DOMAIN,api.example.org,JP-CF-WS
DOMAIN-SUFFIX,example.net,DE-HY2-直连

# 完整文件的最后一条
MATCH,漏网之鱼
```

目标填写现有策略组、节点名或 `DIRECT` / `REJECT`。建议优先使用稳定的策略组，避免引用随固定列表变化的节点名称。

现有策略组：`节点选择`、`自动选择`、`X专用`、`ChatGPT`、`Google`、`T专用`、`Grok`、`流媒体`、`Steam`、`国内服务`、`漏网之鱼`。每组实际使用哪条线路由客户端选择。

**`DIRECT` 是本地网络直连；`DE-HY2-直连` 仍然经过德国 VPS。**

支持的类型：

- 域名：`DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`。
- 进程：`PROCESS-NAME`、`PROCESS-PATH`，需客户端平台支持进程识别。
- 地址：`IP-CIDR`、`IP-CIDR6`、`SRC-IP-CIDR`、`GEOIP`，支持相应 `no-resolve` 选项。
- 网络与端口：`NETWORK`、`DST-PORT`、`SRC-PORT`。
- 逻辑和兜底：`AND`、`OR`、`NOT`、`MATCH`。

暂不支持 `RULE-SET` 等外部规则集引用。修改此文件不会创建策略组或节点；规则不会自动排序或去重。

## 更新流程与故障处理

常规流程：下载固定列表 → 优选 IP → 下载完整规则 → 生成临时订阅 → 校验 → 备份 → 发布 HTTPS 文件。
`--rules-only` 跳过固定列表下载和 IP 测试。

| 情况 | 处理方式 |
| --- | --- |
| 固定列表下载失败 | 使用上次有效缓存；无缓存则停止 |
| 固定列表格式错误、测速失败或有效自动 IP 不足 | 停止，保留旧订阅 |
| 规则下载失败、格式错误或目标不存在 | 提示并保留当前规则；IP 更新仍可继续 |
| 重复节点、无效策略组引用或更新期间配置变化 | 停止，避免发布冲突配置 |
| 发布出错 | 尝试恢复备份并报错 |

出现 `Rules download failed` 或 `retaining current rules` 表示没有应用 GitHub 新规则，即使之后显示订阅更新成功，也应修正问题再重试。

更新有互斥锁和私有备份。Clash YAML 与通用链接订阅分别替换，不是跨文件事务。
**完整分流规则只包含在 Clash YAML 中；通用链接/base64 订阅仅提供节点，不能携带策略组与规则。**

常见问题：

- GitHub 文件改了但客户端没变化：先运行服务器更新命令，检查输出，再更新客户端订阅。
- 提示 `Private IP updater is not installed`：脚本入口只是调用器，服务器尚未安装相应程序。
- 提示更新已在运行：等待当前任务完成，不要反复启动。
- 反代慢但直连正常：优选 IP、Cloudflare 路径或反代限流都可能影响体验；更新订阅不等于调整服务参数。

## 服务器维护与代码升级

这是已有服务器的维护仓库，不是全新 VPS 的一键安装器。服务器需已有 Python 3、`cfst`、sing-box、Cloudflare Tunnel、HTTPS 发布环境及私密配置。

| 服务器位置 | 用途 |
| --- | --- |
| `/usr/local/sbin/update-cf-subscription` | 已安装的更新器 |
| `/usr/local/sbin/export-private-subscriptions` | 已安装的导出器 |
| `/root/private-subscriptions/` | 私密模板、节点配置、生成文件及备份 |
| `/srv/private-subscriptions/` | HTTPS 服务读取的订阅文件 |

GitHub shell 入口仅调用已安装程序，不自动升级服务器的 Python 代码。修改 IP/规则文本后直接运行更新命令即可；修改 Python 功能后需另行测试和部署。

后续修改代码时：

1. 核对 Git 状态与服务器版本，保留已有未提交修改。
2. 在 Linux 环境运行 `python3 -m unittest -v test_update_cf_subscription`。更新器依赖 `fcntl`，不适合直接在原生 Windows Python 中测试。
3. 备份服务器脚本和私密配置，核对额外节点支持，不能盲目覆盖导出器。
4. 部署更新器后先执行 `--rules-only --dry-run`，再按需完整预演。
5. 发布后核对实际 HTTPS 内容、规则顺序和代理进程。

截至本次整理，服务器导出器已有日本 HY2 等本地扩展，不要假设仓库导出器与服务器版本完全一致。日常更新 IP 和规则不需要重新部署导出器。

## 更新记录

以下记录仓库功能演进，服务器独立配置变更不代表都包含在仓库代码中。

| 日期 | 提交 | 更新内容 |
| --- | --- | --- |
| 2026-11-19 | `387723a` | 停止公开完整订阅，改用私密导出 |
| 2026-11-19 | `27a5bef` | 支持私密 HTTPS 发布及日本节点 |
| 2026-11-19 | `971bf87` | 恢复原有策略组和规则，支持独立私密 CF 节点 |
| 2026-11-19 | `feea945` | 恢复低流量自动优选 IP、固定列表和 HTTPS 发布 |
| 2026-11-21 | `a9d81b0` | 接入完整规则文件、校验回退及 `--rules-only` |
| 2026-11-21 | 本次文档整理 | 汇总功能、命令、修改流程、故障处理和维护说明 |

以后新增功能时，请同步更新本 README 的命令、参数、兼容性说明和更新记录。

## 凭据与公开范围

不要提交完整 YAML、UUID/密码、Cloudflare token、私钥或包含随机访问路径的订阅链接。HTTPS 订阅链接本身具有访问权限，只通过私密方式分享。规则文件也不要包含不希望公开的内部域名。

历史 Git 版本可能包含过去的凭据；删除公开文件不能代替撤销或更换旧凭据。

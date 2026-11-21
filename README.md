# vps-tools

Public subscription publishing was retired on 2026-11-19 following credential exposure.

The legacy shell entry points now only invoke the installed private exporter on the
German server. They do not upload files or credentials. Generated subscriptions are
root-only files under `/root/private-subscriptions`, retrieved through authenticated
SSH or a shared HTTPS endpoint protected by a random bearer path. The endpoint URL is stored privately on the server; it is never committed here.

`export_private_subscriptions.py` reads the current three Hysteria2 inbounds and a
private routing template, plus privately stored, validated JP and German CF nodes. It updates the restricted HTTPS serving directory when configured. It does not rotate credentials, restart services, or make
network requests. It pins the existing server certificate in the Clash configuration.

Old generated files have been removed from the current branch. Historical revisions
may still contain revoked credentials; deletion is not a substitute for rotation.

The exporter preserves the historical rule list and proxy-group order. Unavailable nodes are filtered, and the old HY2 50M/100M labels map to the actual 15M/30M limits. German CF runs in a separate service with independent credentials, local ingress guards, resource limits and blocked SMTP/private-network destinations. Generated credentials and shared subscription URLs are never committed.

## 更新固定节点和自动优选 IP

完整分流规则保存在 [`cf_custom_rules.txt`](cf_custom_rules.txt)，每行一条，按顺序匹配。
该文件替换完整规则列表，不是增量追加；首次导入保留原有 131 条规则的顺序。
空行和整行 `#` 注释会被忽略，必须保留唯一的末尾 `MATCH` 兜底规则。
目标填写现有策略组、节点名称或 `DIRECT` / `REJECT`；建议优先使用稳定的策略组名称。
支持 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、PROCESS-NAME、PROCESS-PATH、IP-CIDR、
IP-CIDR6、SRC-IP-CIDR、GEOIP、DST-PORT、SRC-PORT、NETWORK、AND/OR/NOT 和 MATCH。
暂不支持规则集引用及其他类型，避免未配置的依赖导致客户端加载失败。
公开文件不要填写密码、UUID、token、订阅链接或不希望公开的域名。

原来的更新命令和 GitHub shell 入口会同时拉取该文件并更新 HTTPS 订阅。
如仅修改分流规则、不更新任何节点 IP，可运行：

```bash
update-cf-subscription --rules-only
```

可加 `--dry-run` 只校验不发布。下载失败、格式错误或目标不存在时会提示并保留
当前有效规则（IP 更新仍可继续）；规则顺序不被排序或去重。生成过程不重启服务。

在德国 VPS 上以 root 运行：

```bash
update-cf-subscription
```

每次从本仓库 `main` 分支读取 `cf_fixed_ip.txt`，保留手工节点的顺序；使用
Cloudflare 官方 IPv4 网段，默认低并发测试 80 个候选 IP，再选取 12 个通过
TLS/WebSocket 握手验证的延迟优选 IP。没有大文件下载测速。测速视角是德国 VPS，
不能保证这些 IP 在中国或其他客户端网络上也最快。

完成后自动更新现有 HTTPS 订阅文件，订阅地址不变。客户端点“更新订阅”即可。
不更换 UUID/密码，不重启代理、不切换客户端、不上传任何订阅或凭据到 GitHub。
固定节点按手工配置保留，不因为测速失败被删除，也不保证每个固定节点在线。

`cf_fixed_ip.txt` 格式为“名称 地址”，支持 IPv4、域名和可选端口：

```text
yx 108.162.198.205
主域名 de.ywsqbw.uk
备用 162.159.44.19:443
```

空行和以 `#` 开头的注释会被忽略，同地址同端口去重。`yx` 和 `japan2` 两个名称
也会同步对应 `CF-WARP` 节点的连接地址，其凭据和 WARP 出口保持不变。

只更新固定节点、保留当前自动节点：

```bash
update-cf-subscription --fixed-only
```

仅预演，不发布：`update-cf-subscription --dry-run`。
高级参数：`--candidates 80 --keep-top 12`；上限分别为 160 和 24。
可使用 `--fixed-file /root/my-fixed-ip.txt` 临时指定本地列表。

下载 GitHub 固定列表失败时使用上次验证成功的缓存；格式错误、测速失败或有效
自动节点不足时保留旧订阅。更新带互斥锁、发布前校验和私有回滚备份。
共享订阅地址及凭据只保存在服务器私有文件中。

原 GitHub 脚本入口 `cfsub_v10_germany.sh` 现在调用该更新命令，需要服务器已安装
`/usr/local/sbin/update-cf-subscription` 和私有导出器。单独运行
`export-private-subscriptions` 仍仅重新导出当前配置，不做 IP 优选。

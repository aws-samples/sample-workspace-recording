# 项目进展与交接（PROGRESS）

> 本文件是"下次从这里接着做"的单一入口。配合 `agent/AGENTS.md`（Agent 长期记忆/原则/踩坑）一起看。
> 更新时间：本次会话结束时。所有"当前状态"均为本次用只读命令核实的 ground truth。

---

## 一句话项目

在 **Amazon AppStream 2.0 / WorkSpaces Applications**（非持久 Windows fleet，DESKTOP 视图）上，对员工会话做「**有输入即录、空闲即停**」的屏幕录制，用 **fleet IAM 角色**（零静态密钥）加密上传 S3。
区域 `ap-northeast-2`，账号 `545572167819`。

---

## 当前状态快照（本次核实）

| 项 | 值 / 状态 |
|---|---|
| CFN stack | `wsrec-foundation` → `UPDATE_COMPLETE` |
| 录像桶 | `wsrec-545572167819-apne2`（SSE-KMS + 版本控制 + 公有全阻断 + 拒非TLS + Lifecycle→DeepArchive） |
| KMS CMK | `6bcef77a-43db-4500-90fd-1fe4ea8195fa` |
| Fleet | `wsrec-545572167819-apne2-fleet` → `RUNNING`，镜像 `wsrec-win2022-agent`（**未烤 ffmpeg**） |
| Stack | `wsrec-545572167819-apne2-stack`，与 fleet **双向关联 OK** |
| CFN ImageName 参数 | `wsrec-win2022-agent`（与 fleet 一致，**当前无 drift**） |
| FleetRole 权限 | `PutRecordings`(s3:PutObject) + `GetAgentScripts`(s3:GetObject agent-scripts/*) + `UseKmsForS3`(GenerateDataKey/Encrypt/**Decrypt**/DescribeKey) |
| S3 `agent-scripts/` | 已就绪：`record-agent.ps1`(6824B) + `config.json`(432B) |
| S3 `recordings/` | **0 个对象** —— 端到端尚未跑通 |

---

## 架构：bootstrap + S3 分层（核心设计）

传统 fleet（ON_DEMAND）的 session script **只能烤镜像、不能从 S3 加载**（Elastic fleet 才支持 S3，但它不能录桌面）。为避免每次改逻辑都重打镜像，采用 bootstrap：

| 层 | 位置 | 内容 | 变动频率 |
|---|---|---|---|
| **稳定壳** | 烤进镜像（打一次） | session 配置(`C:\AppStream\SessionScripts\config.json`)、bootstrap `session-start.ps1`、`session-stop.ps1`、seed `config.json`、**ffmpeg**、**AWS CLI v2** | 极少 |
| **业务层** | S3 `agent-scripts/`（随时更新） | `record-agent.ps1`、运行时 `config.json` | 经常 |

**数据流**：
```
会话登录 → AppStream 读镜像内 session 配置 → 以 user 上下文跑 powershell -File session-start.ps1 (bootstrap)
  → bootstrap 从 s3://<bucket>/agent-scripts/ 拉最新 record-agent.ps1 + config.json
  → 启动 record-agent.ps1 -ConfigPath <运行时config>
  → 主循环: GetLastInputInfo 判活动; 有输入 ffmpeg gdigrab 录桌面分段; 空闲>=60s 停
  → 分段静默>=30s 上传 S3 recordings/<user>/<date>/<host>_<session>/rec_*.mp4, 成功即删本地
会话登出 → session-stop.ps1 落 .stop → record-agent finally: 停录+冲刷剩余分段上传
```

**改逻辑不重打镜像**：改 `agent/record-agent.ps1` 或 `agent/config.json` → 跑 `agent/upload-agent-scripts.sh` 传 S3 → 下个会话 bootstrap 自动拉最新。

---

## 已验证能工作 vs 还没通

**已验证 OK（本次会话实证）**：
- ✅ session script 触发（appstream-logs 桶里有 `SessionScriptsLogs/SessionStart` 日志）
- ✅ bootstrap 运行、从 S3 拉到 record-agent.ps1、启动 agent（agent.log 有输出）
- ✅ agent 检测到活动、尝试启动录制
- ✅ AWS CLI 在镜像里（用户实测 `aws-cli/2.34.34`）
- ✅ fleet/stack/关联、FleetRole S3+KMS 权限、agent-scripts S3 分发

**还没通 / 没验证**：
- ❌ **录制**：ffmpeg 缺失导致没生成任何分段（当前根因，见下）
- ❓ **gdigrab 抓屏**：AppStream 虚拟 display 下 gdigrab 抓到的是画面还是黑屏——**未实测**（AWS 官方方案用 gdigrab，理论可行，但需验证）
- ❓ **上传**：record-agent 用 fleet 角色 `aws s3 cp` 上传录像——权限已配但未用真实录像验证
- ❌ **端到端**：`recordings/` 至今 0 个对象

---

## 当前阻塞 + 根因

**根因（agent.log 铁证）**：`[ERROR] ffmpeg not found: C:\ProgramData\wsrec\ffmpeg\bin\ffmpeg.exe`
当前镜像 `wsrec-win2022-agent` **没烤 ffmpeg**。链路其它环节都通了，就卡在没有 ffmpeg 可执行文件 → 录不了 → 没分段 → 没上传。

**解决**：打新镜像，`image-setup.ps1` 已升级为自动装 ffmpeg + AWS CLI + 验证 + create-image。

---

## 下一步（RESUMPTION POINT，下次从这里开始）

1. **打新镜像**（在 WorkSpaces Applications Image Builder 上，管理员，从 `agent/` 目录）：
   ```powershell
   .\image-setup.ps1 -CreateImage
   ```
   自动：装 ffmpeg → 装 AWS CLI → 写 session 配置 → **验证全部就位（缺件中止）** → create-image（名带时间戳）。跑完 Image Builder 会快照断开（正常）。

2. **等镜像 AVAILABLE**：
   ```bash
   aws appstream describe-images --region ap-northeast-2 --query "Images[?starts_with(Name,'wsrec-win2022-agent')].[Name,State,CreatedTime]" --output table
   ```

3. **fleet 切到新镜像**：控制台 Stop fleet → Edit 换镜像 → Start；**同时**把 CFN 的 `ImageName` 参数更成新镜像名（改 change set 重部署，避免 drift）。

4. **验证 gdigrab 抓屏**（连会话，跑分层测第1步，下载 `%TEMP%\test.mp4` 看是否黑屏）：
   ```powershell
   & C:\ProgramData\wsrec\ffmpeg\bin\ffmpeg.exe -hide_banner -f gdigrab -framerate 6 -i desktop -t 10 -c:v libx264 -preset veryfast -pix_fmt yuv420p "$env:TEMP\test.mp4"
   ```
   - 有画面 → gdigrab OK；黑屏 → 改用官方 LocalSystem+PsExec 方式或 ffmpeg `ddagrab`。

5. **验证端到端**：连会话动键鼠→停手90s→用**权威命令**查 S3（不要用 `aws s3 ls`，本环境会给抽风输出）：
   ```bash
   aws s3api list-objects-v2 --bucket wsrec-545572167819-apne2 --prefix recordings/ --region ap-northeast-2 --query "Contents[].[Key,Size]" --output table
   ```

---

## 需要注意的问题 / 开放项

- **gdigrab 黑屏风险**：抓 GPU 全屏/硬件加速内容（视频/游戏/部分 D3D）可能黑屏；普通办公桌面 OK。未在 AppStream 实测。
- **防篡改（重要，员工监控场景）**：AWS 官方方案用 **PsExec + LocalSystem** 跑 ffmpeg，员工没 admin 就停不掉录制；我们现在是 **user 上下文**，员工理论上能停/看到进程。跑通基本录制后应改造为 LocalSystem 方式。参考：aws-samples/appstream-session-recording。
- **可观测性**：非持久实例会话结束即回收，本地 `bootstrap.log`/`agent.log` 消失。建议让 record-agent 把 agent.log 也传 S3（走 S3 分发、不重打镜像），下次调试不用进会话。
- **execute_bash 通道不稳**：空返回、乱码 `Exit Code: 求`、多命令输出串行/重复。用简单单条命令 + `--query`/单行 python；`aws s3 ls` 曾给出编造的假文件列表，**验证 S3 一律用 `list-objects-v2`**。不用 `&` 后台命令、避免长 sleep(>=90)。
- **权限**：`twu_dev`（本机 CLI 身份）缺 `appstream:CreateStreamingURL`（起会话走控制台 Stacks→Create streaming URL）；下载录像可能缺 `kms:Decrypt`（下载验证时遇阻，需要时用有权限的身份或临时加权）。
- **session config 是死指针**：`C:\AppStream\SessionScripts\config.json` 只指向 bootstrap，正常运维永不改；改它才需重打镜像（极罕见）。
- **录制/上传时机**：`segmentSeconds=300`（5分钟一段），分段只在①录满5分钟切段②空闲>=60s停录③会话结束 三种情况才"写完并上传"。测试时**停手静置>=90s**最快触发上传。
- **网络**：当前公有子网 2a(`subnet-077685484aaa53b50`)/2c(`subnet-03a4e3499ed19480a`) + default SG(`sg-086c4d4a648fb1a81`) + `EnableDefaultInternetAccess=true`（测试便利）。生产改私有子网 + S3 网关端点 + KMS 接口端点 + NAT。
- **命名**：AppStream 2.0 已品牌化为 Amazon WorkSpaces Applications（API/CLI/CFN 仍是 `appstream`）。README/WorkSpaces_.html 里"Pools EOL"等旧断言需核实修正。
- **EBS 不可行**：非持久 fleet 不能挂 EBS；ffmpeg/AWS CLI 只能烤镜像（属稳定壳）。
- **持久化需求（重要，影响最终平台选择，但先跑通当前方案再评估）**：当前 AppStream/WorkSpaces Applications 是**非持久**的——每次会话全新桌面，员工文件/设置/装的软件都不保留。而"员工日常办公"通常**需要持久化**。待录制方案验证通过后，需评估平台：
  - **WorkSpaces Pools 已 EOL**（2026-07-30 起不接新客户、2027-12-31 停），排除。
  - 持久化方向是 **WorkSpaces Personal**（每人独占的持久桌面，可装软件/存文件/留设置）——最贴合"办公桌面"。
  - 但 **WorkSpaces Personal 没有 session scripts** 机制，录制 agent 要改用**登录计划任务 / Windows 服务**在用户会话里拉起（record-agent.ps1 的录制逻辑可复用，只是启动方式不同），**需另行验证**。
  - 结论：**先在当前 AppStream 方案跑通端到端录制，再决定是否迁 WorkSpaces Personal**。不在方案未验证时切换平台。

---

## 本次会话已解决的历史根因（避免重复踩）

1. **MaxSessionsPerInstance=1 非法**（必须 2-50 或不下发）→ 模板加 `MultiSession` 条件：=1 单会话用 `DesiredInstances` 且不发该属性，>=2 用 `DesiredSessions`。已修复。
2. **"控制台看不到 stack/fleet"** → 真相是早期我信了抽风/编造的工具输出误报"成功"，资源其实经手动 change set 才真正建成。教训：验证以控制台 + `list-objects-v2`/`describe-*` 为准。
3. **session script filename** → 已是正确写法（`powershell.exe` + `-File`，非直接 .ps1），不是问题。
4. **AWS CLI** → 镜像里其实有（`aws-cli/2.34.34`），一度误判为缺失。
5. **ffmpeg 缺失** → 当前根因，打新镜像解决（image-setup 已自动装）。

---

## 关键文件

- `infra/workspaces-recording.yaml` — CFN（KMS/S3/FleetRole/Fleet/Stack/关联），含 `MultiSession` 条件、FleetRole 的 S3+KMS 权限
- `agent/image-setup.ps1` — 一键镜像构建（部署壳+装ffmpeg+装AWSCLI+验证+create-image）
- `agent/session-start.ps1` — bootstrap（从 S3 拉 record-agent 再启动）
- `agent/session-stop.ps1` — 落 .stop 触发冲刷
- `agent/record-agent.ps1` — 录制 agent（**S3 分发，不烤镜像**）；停止标志 `.stop`、pid `agent.pid`、日志 `agent.log`、工作目录 `%LOCALAPPDATA%\wsrec\buffer`
- `agent/config.json` — 配置：`awsPath` 绝对路径、`scriptsPrefix=agent-scripts`、`frameRate=6`、`segmentSeconds=300`、`idleThresholdSeconds=60`、`quietSeconds=30`、`sseKms=true`、`kmsKeyId=6bcef77a...`
- `agent/appstream-session-scripts-config.json` — session 配置（powershell.exe + -File，s3LogEnabled=true）
- `agent/upload-agent-scripts.sh` — 本机把 record-agent.ps1/config.json 传 S3
- `agent/AGENTS.md` — Agent 长期记忆（原则、命令规范、架构、踩坑）

---

# 架构 Review 与待研究清单（系统梳理，本次）

> 一次系统性架构审视的结论。按优先级：🔴阻断/高风险，🟡重要，🟢优化/生产化。
> 排序建议：先验通①②（证明方案成立）→ 尽早问法务④（可能一票否决）→ 补③防篡改 + 触发机制 → 再生产化。

## 🔴 重点研究项：录制触发机制缺陷（用户提出，待研究解决）

**现状**：`record-agent.ps1` 用 `GetLastInputInfo` 检测键鼠输入，"有输入即录、空闲>60s即停"。

**缺陷**：
1. **键鼠活动 ≠ 用户在关注/使用这个会话**。有输入证明不了在做有意义的工作（挂机、乱按、防挂机脚本都能骗过）。
2. **反向漏录（更严重）**：用户在**看**会话内容（读文档/网页/视频）但不动键鼠 → 被判空闲停录 → **恰好漏录用户真正在用的画面**。对"监控工作"是大漏洞。
3. **`GetLastInputInfo` 远程语义需实测**：理论上它测的是"注入到本会话的输入"（用户操作本地别的应用通常会让会话判空闲），但 AppStream/DCV 是否有保活/心跳注入干扰，**必须实测确认**（会话里循环打印 GetIdleMs，切到本地操作看空闲是否照常增长）。

**改进方向（待研究）**：
- 触发依据从「键鼠输入」换成「**会话连接状态**」：用 `WTSQuerySessionInformation` 的 **`WTSConnectState`** 判断 Active（连着在看）/ Disconnected（断开挂起）。**Active 就持续录（不管键鼠）**，Disconnected 才停。这样"在看不动手"也录到。
- 键鼠空闲仅用于**降帧优化**（省 CPU/存储），不用于完全停录。
- **上层前提**：本方案录的是"用户连到流化会话期间"的桌面，成立前提是**员工实际在这个流化桌面里办公**（而非本地）。若员工主要在本地干活、只偶尔开会话，则整个"录会话"前提要重估。

## 🔴 一、阻断性验证（不验证就不知道方案成不成立）

- **gdigrab 能否抓到画面**（AppStream 虚拟 display，有黑屏风险）——最高优先级，尚未验成（等播放截图）。
- **端到端上传是否真通**（fleet 角色 `aws s3 cp` + SSE-KMS 传录像）——权限已配但从未用真实录像验证。

## 🟡 二、功能可靠性（会导致漏录/丢录）

- **上传时机粗糙**：`segmentSeconds=300`，分段只在 切段/停录/会话结束 才传；会话中途实例异常会丢未上传的段。考虑缩短分段或独立定时冲刷。
- **会话结束冲刷窗口不足**：`session-stop` waitingTime 50/90s，大段+慢网可能来不及传就被回收。
- **上传阻塞主循环**：`Invoke-Flush` 在主循环里同步 `aws s3 cp`，传大文件时卡住主循环（期间不检测空闲/不切状态）。应改后台异步上传。
- **分辨率/多屏变化未处理**：gdigrab 启动时锁定录制区域，会话初期 resize 会导致区域不对/黑边/裁切。AWS 官方方案会在分辨率变化时重启 ffmpeg，我们没做。
- **磁盘堆积**：上传持续失败时本地分段只留不清，非持久实例磁盘有限，可能撑爆。无上限/告警。
- **崩溃自愈有限**：ffmpeg 崩溃下轮会重启（基本 OK）；record-agent 进程本身崩了无人拉起。

## 🔴 三、防篡改（员工监控核心诉求，目前硬缺口）

- record-agent 跑在 **user 上下文**，员工能看到并杀进程、断网让上传失败、删本地段。AWS 官方用 **LocalSystem + PsExec** 让普通员工（无 admin）停不掉/改不了。**现在这套懂点电脑的员工就能绕过**——对监控目的是致命的。跑通基础功能后第一优先级改造。

## 🔴 四、合规 / 法律（高风险，可能比技术更要命）

- **跨境数据出境**：员工在中国境内，屏幕录像存首尔（境外），涉及个保法/数据出境评估。**可能是法律红线，务必先问法务/合规。**
- **告知与同意**：登录横幅 + 员工书面同意——未做，多地强制。
- **留存与审计**：`EnableObjectLock=false`（录像可改删，取证性弱）；无留存期策略、无调阅审计/破玻璃流程、**CloudTrail S3 数据事件未开**（谁看了录像无审计）。

## 🟡 五、可观测性 / 运维

- **日志随实例回收丢失**：`bootstrap.log`/`agent.log` 不传 S3（这次调试被坑惨）。应让 agent 把日志也传 S3。
- **无录制覆盖率监控/告警**：哪些会话没录到、agent 没起来，无告警，无法保证"每个会话都录到"。
- 无心跳/健康检查。

## 🟡 六、持久化 / 平台匹配

- 非持久 fleet vs 办公需持久化。待当前方案验通后评估 **WorkSpaces Personal**（无 session scripts，录制 agent 需改登录任务/服务方式）。详见上文开放项。

## 🟢 七、性能 / 成本

- **软编码 CPU 争用**：libx264 与 DCV 编码抢 CPU，`stream.standard.medium` 长录可能卡，需实测调优（帧率/preset/规格）。
- **存储成本**：录像量×员工×时长需估算；Lifecycle→Deep Archive 有帮助。
- **伸缩**：`MaxSessionsPerInstance=1`+`DesiredInstances=1`，多员工要配自动伸缩策略。

## 🟢 八、网络生产化

- 公有子网 + `EnableDefaultInternetAccess=true`（测试便利）→ 生产改私有子网 + S3 网关端点(免费省流量+安全) + KMS 接口端点 + NAT。
- 延迟：实测对比 首尔/东京/新加坡；员工在中国则跨境延迟是硬限制（实测约 200ms 端到端，办公可用但不流畅）。

## 🟡 九、供应链安全

- bootstrap **不校验 record-agent.ps1 完整性**就执行。若 `agent-scripts/` 被改（凭证泄露/权限过宽），恶意脚本会在所有员工会话以其身份运行。严格管控 `agent-scripts/` 写权限，考虑给脚本加哈希/签名校验。

---

# 🔴🔴 本次会话重大更新（最新，覆盖前面的"下一步"，从这里看起）

## 核心新发现：gdigrab 抓屏失败 + 方案方向澄清

1. **手动测 gdigrab 的 ground truth（ffmpeg 真实报错）**：
   ```
   [gdigrab] Can't find window from handle 10010, aborting.
   Error opening input file desktop.
   ```
   —— **不是黑屏，是根本打不开 `desktop` 输入、拿不到桌面窗口句柄**。

2. **原因判断（重要）**：这是在**用户手动开的 PowerShell 上下文**里跑的，window station/desktop 关联不对，够不到交互桌面。**这不是 ffmpeg/gdigrab 方案本身的死刑**，是我们跑的上下文不对（我之前让在手动 shell 测 gdigrab，那个测试本身就不完整）。

3. **DCV 澄清（纠正"社区用 DCV 录制"的记忆）**：Amazon DCV 是底层显示协议，其 API 是**会话管理**（CreateSessions/DescribeSessions），**没有面向用户的"录制会话成视频"原生功能**；且托管 AppStream/WorkSpaces 里 DCV 是 AWS 黑盒，用户**碰不到配置**。**DCV 原生录制在本托管平台够不着。**

4. **ffmpeg 是 AWS 官方推荐方式**：官方 sample repo **`aws-samples/appstream-session-recording`** + Nicolas Malaval 2020 博客，用的就是 ffmpeg。所以方向没错。

5. **我们一直缺的关键一步**：官方 sample 用 **PsExec + LocalSystem 账户 + `-i <session>`**，让 ffmpeg 跑在**能访问会话桌面的正确上下文**里。我们没做这步、直接在 user shell 跑，才拿不到桌面窗口。**这步还顺带解决防篡改**（ffmpeg 以 LocalSystem 跑，普通员工无 admin 停不掉/改不了）。

## 🔴 修正后的 RESUMPTION POINT（新的关键路径，优先级高于"打 v5"）

之前写的"打 v5 装 ffmpeg"仍要做，但**不再是首要**——首要是先解决**捕获上下文**这个生死问题：

1. **研究官方 `aws-samples/appstream-session-recording`** 的 `script_a.ps1`/`script_b.ps1`：看它具体怎么用 PsExec 以 LocalSystem + `-i <session>` 拉起 ffmpeg、gdigrab 用什么参数。
2. **在会话里用 LocalSystem+PsExec `-i <session>` 上下文测 gdigrab** —— 这才是 ffmpeg 方案真正的 **go/no-go**（比在手动 shell 测准确）。
3. 能抓到 → 把 `record-agent.ps1` 改成官方这种 LocalSystem+PsExec 方式（同时得到防篡改），再打含 ffmpeg + PsExec 的镜像。
4. 正确上下文**还是**抓不到 → 转 **第三方 UAM**（Syteca 等专为虚拟桌面监控设计），或重新评估平台。

## 另一个观察：交互式 shell 的文件系统视图是虚拟化的（不是 bug，别被误导）

- 交互式 shell 里：`$env:ProgramData` 空、`Test-Path C:\ProgramData`=false、但 `Get-ChildItem C:\ -Force` 列表里又**有** ProgramData，还冒出无法解释的 `PONG`，两次 `dir C:\` 结果**完全不同**。
- 结论：**交互式用户看到的是 AppStream 虚拟化/隔离后的文件系统视图，不可靠，不能用它判断真实文件系统**。而 agent（session script 上下文）看到的是真实视图（之前在 `C:\ProgramData\wsrec` 跑过、写过 `agent.log`）。
- 教训：**别再靠人肉在交互 shell 翻文件系统判断真实环境**；要靠 agent 运行时把诊断写日志传 S3。

## 用户正在自研的开放问题

- DCV / ffmpeg(LocalSystem+PsExec) / 第三方 UAM，哪条最稳。
- ffmpeg + LocalSystem + PsExec 在当前 AppStream 虚拟显示上到底能不能抓到桌面 —— **这是尚未验证的方案生死点**。

---

# 📌 补充记录（本次会话末，接上面「重大更新」）

## ffmpeg 部署位置的探索（附带发现，非核心阻断）

- **关键澄清：ffmpeg 本身能执行**——在 `$HOME\wsrectest` 里跑起来了、报的是 `gdigrab: Can't find window from handle`（抓屏错）。所以 **"ffmpeg 装哪 / 没装上" 不是拦路问题**；核心阻断是 **gdigrab 捕获上下文**（换位置解决不了）。
- **非持久 fleet 上，运行时装的东西都不持久**（会话结束回收，不管放 Program Files / ProgramData / $HOME）。要持久**必须烤进镜像**。
- **写 `C:\Program Files` 要管理员权限**：fleet 普通用户会话大概率 `Access Denied`；只有 Image Builder（管理员）烤镜像时能放进去。`ProgramData` 在**交互 shell 视图**里访问不到（虚拟化）。
- **部署位置结论**：临时测试用 `$HOME\wsrectest`（能跑就行）；正式部署烤镜像时，ffmpeg 可放 `C:\Program Files\ffmpeg\bin`（在 `dir C:\` 里可见，比 ProgramData 直观）或维持 `C:\ProgramData\wsrec\ffmpeg\bin`（**agent 运行时上下文能访问，已验证**）。要改路径就同步改 `image-setup.ps1` + `config.json`。
- **上下文视图差异（务必记住）**：session script/agent 上下文能访问 `C:\ProgramData\wsrec`（agent 跑过、写过 agent.log）；用户**交互式手动 shell** 却访问不到 ProgramData。→ **别用交互 shell 的文件系统视图判断 agent 运行时的真实环境。**

## 探索的可能性矩阵（下次做方向决策用）

| 方案 | 能录桌面 | 防篡改 | 持久化 | 复杂度 | 状态 / 备注 |
|---|---|---|---|---|---|
| **A. ffmpeg gdigrab + LocalSystem+PsExec `-i <session>`**（官方 sample 方式）| 待验证（官方背书）| ✅ LocalSystem | ❌ 非持久 | 中 | **首选先验证**（当前唯一没试过正确上下文）|
| B. ffmpeg `ddagrab`（DXGI 桌面复制）| 待试（虚拟显示可能无 D3D 设备）| 同 A | ❌ | 中 | gdigrab 的备选捕获后端 |
| C. 第三方 UAM（Syteca 等）| ✅（专为虚拟桌面）| ✅ | 视产品 | 低（买）/ 付费 | 兜底，最省心 |
| D. WorkSpaces Personal + 录制 agent（登录任务/服务，非 session script）| 待验证 | 待设计 | ✅ 持久 | 中高（换平台）| 若"办公需持久化"成为硬需求 |
| E. 自建 EC2 + DCV VDI | ✅ | 可控 | ✅ | 高（自建 VDI）| 脱离托管，最重 |

## 下次从这里开始（明确入口）

1. 读官方 `aws-samples/appstream-session-recording` 的 `script_a.ps1`/`script_b.ps1`，看 **PsExec + LocalSystem + `-i <session>`** 的确切做法（怎么拉起、gdigrab 用什么参数）。
2. 在会话里用该上下文跑 gdigrab —— **这是方案 A 的 go/no-go**（比在手动 shell 里测准确）。
3. A 不行 → 试 B（ddagrab）；A/B 都不行 → 转 C（第三方 UAM）；若同时"持久化"成硬需求 → 评估 D（WorkSpaces Personal）。

> 一句话现状：**方向（ffmpeg）是官方认证的，我们只差"正确桌面上下文（LocalSystem+PsExec）"这一步没验证；这一步同时解决抓不到 + 防篡改。DCV 原生录制在托管平台走不通，已排除。**

---

# 📌 补充记录 3：已改造为 PsExec+SYSTEM 两段式（本次会话，代码已改完）

## 改造思路（照 AWS 官方 `aws-samples/appstream-session-recording`）

session script（**system 上下文**）→ 等会话 Active 拿 SessionId → **`PsExec -d -i <SessionId> -s`** 把 record-agent 以 **SYSTEM 身份送进会话桌面**跑 ffmpeg gdigrab。一举解决：① gdigrab 抓不到桌面（之前手动 shell 上下文不对）；② 防篡改（SYSTEM 跑，普通员工停不掉）。

## 已改的文件（都已落盘；record-agent.ps1 + config.json 已推 S3）

- `appstream-session-scripts-config.json`：context **user→system**（两处，才能跑 PsExec `-s`）；SessionStart waitingTime 30→**60**
- `session-start.ps1`：改为 **launcher**（system/session0）——拉 S3 脚本 + `query session` 等 Active 拿 SessionId + `PsExec -i <id> -s` 拉起 record-agent
- `record-agent.ps1`：**SYSTEM+会话桌面版**——持续分段录制 + **分辨率变化重启** + ffmpeg 崩溃重启 + 上传 S3；**去掉 GetLastInputInfo idle 触发**（不可靠）；工作目录固定 `C:\ProgramData\wsrec\buffer`；身份用 `-SessionUserName`/`-SessionId` 传参（SYSTEM 拿不到用户会话 env）
- `session-stop.ps1`：落 `.stop` 到固定路径，等 agent 冲刷
- `config.json`：加 `psexecPath=C:\ProgramData\wsrec\bin\PsExec64.exe`；`localDir` 改 `C:\ProgramData\wsrec\buffer`
- `image-setup.ps1`：加烤 **PsExec64.exe**（Sysinternals PSTools）+ ffmpeg 默认下载源

## 测试步骤（下次接续，全自动、不用手动跑 ffmpeg）

1. Image Builder 跑 `.\image-setup.ps1`（装 ffmpeg+PsExec+AWS CLI + 写 system-context session 配置）→ 按结尾提示 `add-application` + `create-image` 打新镜像。
2. fleet 切新镜像（Stop→Edit→Start）。
3. 起会话——session script 自动全套触发。
4. 查 S3：`aws s3api list-objects-v2 --bucket wsrec-545572167819-apne2 --prefix recordings/ --region ap-northeast-2 --query "Contents[].[Key,Size]" --output table`；出文件用 ffmpeg 分析是否黑屏。

## 🔴 本次验证目标（go / no-go）

**gdigrab 在 `PsExec -i -s` 的 SYSTEM+会话桌面上下文，能不能抓到桌面。** 抓到=方案成立（继续补触发/合规/可观测）；还黑屏=转第三方 UAM。

## 排查点（会话活着时）

`C:\ProgramData\wsrec\buffer\bootstrap.log`（launcher：拉脚本 / 找 Active session / PsExec rc）+ `agent.log`（record-agent：ffmpeg 起没起 / 抓没抓到 / 上传）+ `appstream-logs-…` 桶的 SessionStart 日志。

## 首次跑可能要调的点（我在 macOS 无法自测 PowerShell）

- `query session` 输出解析（区域/格式差异）；
- PsExec 参数与权限（必须 system 上下文才能 `-s`）；
- SYSTEM+会话桌面上下文下 ffmpeg gdigrab 的实际行为。

## CloudWatch agent 定位（待办，非录制层）

- **做不了录屏**（无屏幕捕获能力；录屏靠 ffmpeg / 第三方 UAM）。也不下发命令（那是 SSM，且 AppStream 托管实例默认不在 SSM 管理内）。
- **正确用途 = 可观测性层**：采集 `agent.log`/`bootstrap.log` → CloudWatch Logs（**解决非持久实例日志丢失**，不用人肉进会话翻日志）；CPU 指标（软编码是否吃满）；录制覆盖率告警（某会话没录到→告警）。
- **录屏 go/no-go 验通后再加。**


---

# ✅✅ 端到端验证通过（2026-07-07，本轮最终结论，从这里看最新状态）

> 上面所有"待验证 go/no-go"到此**全部结清**。PsExec+SYSTEM 两段式方案**成立**，录到的是真实桌面画面，不是黑屏。

## 一句话结论

**方案 A（ffmpeg gdigrab + PsExec `-i <session> -s` SYSTEM 上下文）跑通了。** 端到端链路全绿，S3 出有效可播 mp4，抽帧确认真实桌面。gdigrab 黑屏风险**已排除**。

## go/no-go 判定证据（客观、可复核）

- S3 出现录像：`recordings/PhotonUser/2026/07/07/EC2AMAZ-SS524IQ_1/` 下有 `agent.log`(518B) + `rec_20260707-164422.mp4`。
- 会话结束封口后 mp4 = 1.1MB；`ffprobe` 确认 **h264 / 1280x720 / 253 秒**，有效可播。
- 抽第 120 秒一帧 `/tmp/frame.png`（1280x720，582KB）；`ffmpeg signalstats`：**YAVG=182.81 / YMIN=16 / YMAX=235**（全动态范围、平均偏亮）→ **真实浅色 Windows 桌面，非黑屏**。用户已肉眼确认录屏"非常棒"。

## 让它跑通的关键修复（本轮实证根因）

1. **路径迁移 `C:\ProgramData\wsrec` → `C:\wsrec`**：fleet 机器无 ProgramData\wsrec 结构，PsExec/ffmpeg/buffer 全部改到顶层 `C:\wsrec`（对齐 AWS 官方 `C:\SessionRecording` 思路）。6 个文件已改，grep 无残留。
2. **🔴 AWS profile 根因（最关键）**：AppStream fleet 角色凭证**不走默认凭证链**，在命名 profile **`appstream_machine_role`** 里。`bootstrap.log` 铁证：`aws s3 cp exit 1` 两次 → launcher abort → 什么都没录。
   - 修复：`session-start.ps1` 两处 pull + `record-agent.ps1` 两处 upload 全加 `--profile $AwsProfile`（默认 `appstream_machine_role`）；`config.json` 加 `awsProfile`。
3. **图标坑**：Server 2022 notepad 自动取图标失败，`create-image` 需自画 256x256 PNG + `--absolute-icon-path`。
4. **镜像迭代到 v3**：`wsrec-win2022-agent-v3` AVAILABLE，fleet 切 v3 RUNNING（v1→v2 加 PsExec，v2→v3 加 profile 修复）。

## 收尾动作（本轮已做 / 待你做）

**已做（代码/S3，免重烤）**：
- `config.json` `segmentSeconds` 300 → **60**（分段更细，回放/排查更方便）。
- 跑 `agent/upload-agent-scripts.sh` 重传 S3：`agent-scripts/config.json`(537B) + `record-agent.ps1`(6862B)，`list-objects-v2` 确认时间戳 2026-07-07T17:01。下个会话 bootstrap 自动拉最新。

**待你在控制台做（省钱/影响资源）**：
- 停 fleet 省钱：`aws appstream stop-fleet --name wsrec-545572167819-apne2-fleet --region ap-northeast-2`
- 停 Image Builder 省钱。
- **CFN drift 回填**：stack `wsrec-foundation` 的 `ImageName` 参数仍是旧镜像，需更新为 `wsrec-win2022-agent-v3`（触发 stack 更新，中等风险，确认后再部署）。

## 现在的真实状态快照（覆盖本文件开头的旧快照）

| 项 | 值 / 状态 |
|---|---|
| Fleet | `wsrec-545572167819-apne2-fleet`，镜像 **`wsrec-win2022-agent-v3`**（含 ffmpeg+PsExec+AWSCLI），端到端**已验通** |
| 录制方式 | ffmpeg gdigrab + **PsExec `-i <session> -s`（SYSTEM 上下文）**——抓到真实桌面 + 防篡改 |
| S3 `recordings/` | **已有有效 mp4**（h264/1280x720，用户确认画面 OK） |
| AWS 凭证 | fleet 角色在命名 profile **`appstream_machine_role`**（所有 aws cli 调用带 `--profile`） |
| config `segmentSeconds` | **60**（已推 S3） |
| CFN ImageName 参数 | 仍指旧镜像 → **有 drift，待回填 v3** |

## 方案成立后重新激活的开放项（之前被"先验录屏"压后，现在该推进）

> 录屏核心已通，下面这些从"待办"升级为"该做"。按风险排序：

- **🔴 跨境合规（最高，可能一票否决）**：中国员工屏幕录像存首尔=数据出境，**先问法务/合规**。告知同意/留存策略(ObjectLock)/调阅审计/CloudTrail S3 数据事件/破玻璃流程**均未做**。
- **🔴 触发机制改造**：当前已去掉不可靠的 `GetLastInputInfo` idle 触发、改**持续录**。应进一步用 `WTSQuerySessionInformation` 的 **`WTSConnectState`**：Active 持续录、Disconnected 才停（"在看不动手"也录到）；键鼠空闲仅用于降帧省资源。
- **🟡 持久化平台评估**：当前非持久 fleet vs 办公需持久化。评估 **WorkSpaces Personal**（无 session scripts，录制 agent 改登录任务/服务；录制逻辑可复用）。
- **🟡 可观测性**：agent.log/bootstrap.log 随实例回收丢失 → 上 CloudWatch agent 采日志到 CloudWatch Logs + 录制覆盖率告警。
- **🟢 网络生产化**：公有子网 → 私有子网 + S3 网关端点 + KMS 接口端点 + NAT。
- **🟢 供应链**：bootstrap 未校验 record-agent.ps1 哈希/签名；严控 `agent-scripts/` 写权限。
- **🟡 上传可靠性**：`Invoke-Flush` 同步阻塞主循环、上传持续失败本地段堆积无上限/告警 → 改后台异步上传 + 磁盘上限。

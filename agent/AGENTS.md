# AGENTS.md — workspace-recordings 项目 Agent 记忆

本文件是给 AI coding assistant 的长期记忆。**每次在本仓库工作前先读它**，尤其是做 AWS 部署 / 运维类任务时。

## 项目一句话

在 Amazon AppStream 2.0（品牌名 Amazon WorkSpaces Applications；API/CLI/CFN 仍用 `appstream`）上，对远程员工会话做「有输入即录、空闲即停」的屏幕录制，用 fleet IAM 角色加密上传 S3。地基层 stack 名 `wsrec-foundation`，区域 `ap-northeast-2`，账号 `545572167819`。

---

## 核心原则（Harness：用外部工具和数据约束行为，而非凭自己的理解）

> 这些原则源自一次真实事故：agent 曾把「工具抽风的输出 + 一次编造的输出」当成真相，向用户汇报「部署成功 / Fleet RUNNING」，而实际 stack 一直停在 `UPDATE_ROLLBACK_COMPLETE`，什么都没建成。控制台 Stacks(0) 才是真相。

1. **绝不编造工具输出。** 没拿到返回，就明说没拿到，然后重试或换命令。虚构任何一行工具输出都是不可接受的。
2. **外部权威数据 > 自己的理解。** 当外部信号（控制台、用户观察、独立查询）与我的内部结论冲突时，**立即以外部为准**，并用干净命令复核，而不是用我的结论去"解释掉"矛盾。
3. **关键状态必须独立二次验证。** `rc=0`、或返回一段像样的 JSON，都 ≠ 操作成功。对关键里程碑（stack 状态、fleet 状态、资源是否存在）要用独立、干净、可复现的查询再确认一遍。
4. **区分「已验证事实」与「推断」。** 只有被工具证实的才作为事实汇报或写入记忆；推断要标明是推断。
5. **事实性断言先查权威源。** 可证伪的产品/命名/行为断言，先用官方文档确认；不确定就明说不确定，不要自信地说错。

---

## 本环境（execute_bash / shell）的已知约束 —— 固化的命令规范

这个 shell 通道不稳定，观察到：空返回、乱码 `Exit Code: 求`、多条命令输出串行/重复、多行内容被压平。为降低噪声：

- **不要用 `&` 后台命令**（本 shell 不生效，返回空）。长任务用「提交 + 轮询」而非后台等待。
- **避免长 `sleep`（≥ 90s）**，容易触发空返回；用较短 sleep 多轮轮询。
- **避免 `--max-items` 和复杂 JMESPath**，易出错/空返回。
- **不要写多行内联 python**（换行会被压平成一行→IndentationError）；用单行 python，或优先用 `aws --query`。
- **关键结果用结构化取数并二次核对**：`aws ... --query "..." --output text/json`，或 `... --output json | python3 -c '单行'`。
- **CloudFormation 更新优先用手动 change set 流程**（`create-change-set` → `wait change-set-create-complete` → `describe-change-set`(python解析) → `execute-change-set` → 轮询 `describe-stacks` 状态），比 `cloudformation deploy` 在本环境更可控、可见。

---

## 本项目 AWS 部署要点（已验证）

- **stack 名是 `wsrec-foundation`**（不是 `wsrec`）。
- **AppStream Fleet 由 CloudFormation 建出后初始状态是 `STOPPED`**，不会自动启动；必须 `aws appstream start-fleet` 或控制台点启动才到 `RUNNING`。别再误报 RUNNING。
- **`MaxSessionsPerInstance` 必须 2–50**；=1（单会话）时**不能下发该属性**，否则 fleet CREATE_FAILED 回滚。模板已用 `MultiSession` 条件处理：=1 走单会话（用 `DesiredInstances`、不发 `MaxSessionsPerInstance`），≥2 走多会话（用 `DesiredSessions`）。
- **fleet 起不来又退回 STOPPED、且 `FleetErrors` 为空**：优先怀疑 **AppStream 实例并发配额**（新账号常见 quota=0，需在 Service Quotas 申请提额）。
- **验证资源是否真实存在**：以 `aws appstream describe-fleets/describe-stacks`（数量+状态）和控制台为准，两者对齐才算数。
- **凭证**：默认 profile `[default]` → 账号 545572167819 / `user/twu_dev`；无 endpoint 覆盖（env 仅 `AWS_PAGER`，无 `~/.aws/config`）。`twu_dev` 缺 `appstream:CreateStreamingURL`，起会话走控制台分配用户可绕开。
- **数据安全**：S3 桶与 KMS 为 `DeletionPolicy: Retain`；对基础设施只做 Add 类变更，破坏性操作前必须先与用户确认。

---

## Session Script + Bootstrap 架构（关键，别再搞错）

**AppStream/WorkSpaces Applications 传统 fleet（ON_DEMAND/ALWAYS_ON）的 session script 只能烤在镜像里**，不支持从 S3 加载脚本（只有 Elastic fleet 的 `SessionScriptS3Location` 支持 S3，但 Elastic 只能应用流化、不能录桌面）。WorkSpaces Pools 同理（配置在 `C:\AWSEUC\SessionScripts\config.json`，也要重打 bundle）。

为避免每次改录制逻辑都重打镜像，采用 **bootstrap 模式**：
- **镜像里只烤"稳定壳"（打一次）**：`C:\AppStream\SessionScripts\config.json`（session script 配置）+ bootstrap `session-start.ps1` + `session-stop.ps1` + seed `config.json` + **ffmpeg** + **AWS CLI v2**。
- **可变的业务逻辑走 S3**：`record-agent.ps1` 和运行时 `config.json` 放 `s3://<bucket>/agent-scripts/`，bootstrap 每次会话从 S3 拉最新再启动。改逻辑只跑 `agent/upload-agent-scripts.sh`，**不重打镜像**。
- fleet IAM 角色需 `s3:GetObject`(agent-scripts/*) + `kms:Decrypt`（已在模板 `FleetRole` 里）。

**session script 配置文件正确写法**（`.ps1` 不能直接当 filename）：
```json
"filename": "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
"arguments": "-NoProfile -ExecutionPolicy Bypass -File C:\\ProgramData\\wsrec\\session-start.ps1",
"s3LogEnabled": true
```

## 端到端调试踩过的坑（都验证过）

- **AWS CLI 必须烤进镜像**：bootstrap/record-agent 都靠 `aws` 拉脚本/传录像，而 AWS CLI 没法从 S3 动态拉（鸡生蛋）。`image-setup.ps1` 现在会自动静默安装 AWS CLI v2。**症状**：agent 起不来、`bootstrap.log`/`agent.log` 空、`recordings/` 无文件。
- **`awsPath` 用绝对路径** `C:\Program Files\Amazon\AWSCLIV2\aws.exe`，避免 session script 早期 PATH 未刷新找不到 `aws`。
- **Image Builder ≠ fleet 会话**：session script 只在**真正的 fleet 流化会话**里跑，Image Builder 里不跑（所以那里的 `bootstrap.log` 永远空）。测试必须走 **Stack → Create streaming URL** 连进去。
- **诊断 session script**：`s3LogEnabled:true` 会把脚本 stdout/stderr 传到 AppStream 自动建的日志桶 `appstream-logs-<region>-<account>-<rand>`，路径 `.../SessionScriptsLogs/SessionStart|SessionTermination/`。注意 bootstrap 把日志写本地文件、stdout 只有 BOM(3字节)，所以要看本地 `%LOCALAPPDATA%\wsrec\buffer\bootstrap.log`（会话活着时）。
- **`describe-sessions` 有盲区**：默认只返回 API(streaming URL)类型会话，指定 `--authentication-type` 又强制要 `--user-id`。**判断有无活跃会话用 `describe-fleets` 的 `ComputeCapacityStatus.InUse`** 最可靠（不依赖类型/user-id）。
- **非持久实例**：会话结束实例即回收，本地 `bootstrap.log`/`agent.log` 随之消失。要留存日志需让 record-agent 主动传 S3。
- **"看不到 C 盘"≠无磁盘**：AppStream 默认镜像用组策略把盘符从文件资源管理器隐藏（安全默认，只暴露 Home Folder 类位置），但 `C:\` 路径对程序/脚本**照常可读写**（agent 就往 `C:\ProgramData\wsrec` + `%LOCALAPPDATA%\wsrec\buffer` 写，已验证）。实例有 200–500GB 根卷。别被"看不到 C 盘"误判为无盘。注意：根卷空间有限 + 非持久，录像必须及时传 S3、上传失败堆积会撑爆。
- **录制触发机制有设计缺陷（用户提出，待研究）**：`GetLastInputInfo` 测的是"注入本会话的键鼠"，但键鼠活动 ≠ 用户在用/关注该会话；尤其"**在看不动手**"（读文档/看视频）会被误判空闲而停录、漏录。改进方向：改用 `WTSQuerySessionInformation` 的 `WTSConnectState`（会话 Active/Disconnected）作触发依据，键鼠仅用于降帧优化。详见 `PROGRESS.md` 架构 Review。
- **gdigrab 抓屏在"手动 shell 上下文"失败（关键，方案生死点，未最终定论）**：手动跑 `ffmpeg -f gdigrab -i desktop` 报 `Can't find window from handle ... aborting`（**拿不到桌面窗口句柄，不是黑屏**）。原因是用户手动 shell 的 window station/desktop 上下文不对，够不到交互桌面。**AWS 官方 sample `aws-samples/appstream-session-recording` 用 PsExec + LocalSystem + `-i <session>`** 让 ffmpeg 跑在正确的会话桌面上下文——这是抓屏成败关键，且顺带解决防篡改。**DCV 无面向用户的原生录制功能、托管平台也碰不到 DCV 配置**（纠正"社区用DCV"的误解）；ffmpeg 才是官方推荐方式。**尚未验证：LocalSystem+PsExec 正确上下文下 gdigrab 能否抓到桌面**——这是 ffmpeg 方案的 go/no-go。详见 `PROGRESS.md` 重大更新。

## 待办（截至本次）

> 完整进展与"下次从这里开始"的交接见根目录 `PROGRESS.md`。
> **当前状态：端到端已验证跑通（2026-07-07）。** 生产镜像 `wsrec-win2022-agent-v3`；录像 S3 有有效 mp4（h264/1280x720，抽帧确认真实桌面）。

- [x] **打镜像装 ffmpeg + PsExec + AWS CLI**：Image Builder 跑 `.\image-setup.ps1` → `add-application` + `create-image` → v3 AVAILABLE。
- [x] **端到端验证通过**：起会话→PsExec 拉起 record-agent→ffmpeg gdigrab 抓到真实桌面→分段上传→S3 `recordings/PhotonUser/2026/07/07/EC2AMAZ-SS524IQ_1/` 出 `rec_*.mp4`（有效可播）。
- [x] **可观测性（初步）**：`record-agent.ps1` 已把 `agent.log` 定期/退出时传 S3（`Send-Log`），实例回收也能拿到录制端日志。
- [x] **CFN `ImageName` drift 已修复**：stack `wsrec-foundation` 参数更新为 `wsrec-win2022-agent-v3`（fleet 停机 → change set → UPDATE_COMPLETE）。
- [x] **客户复现文档**：`agent/REPRODUCE.md`（从零到端到端，含每条命令）。
- [ ] **触发机制改造**：去掉不可靠的 `GetLastInputInfo`，改用 `WTSConnectState`（Active 持续录、Disconnected 停），键鼠仅用于降帧。
- [ ] 修正 WorkSpaces_.html 里的产品命名措辞，核实"Pools EOL"等断言。
- [ ] 网络生产化：私有子网 + S3 网关端点 + KMS 接口端点 + NAT，替换当前公有子网 + `EnableDefaultInternetAccess=true`。
- [ ] 🔴 合规：跨境数据出境评估（先问法务）、告知同意横幅、Object Lock/WORM、CloudTrail S3 数据事件、调阅审计。

---

## 重大更新 2026-07-07（PsExec+SYSTEM 两段式端到端调试，逼近 go/no-go）

本轮把方案从"session script 直接录"改造为 **AWS 官方 PsExec+SYSTEM 两段式**并端到端跑通了大半，记录几条硬结论：

1. **路径全部从 `C:\ProgramData\wsrec` 迁到顶层 `C:\wsrec`**（对齐 AWS 官方 `C:\SessionRecording` 模式）。原因：`C:\ProgramData` 在交互 shell 虚拟化视图里表现诡异（`$env:ProgramData` 空、`Test-Path` false），虽然 agent 运行时其实能写，但顶层目录更稳、可实证持久（`C:\AppStream` 就在）。所有脚本+config 已统一 `C:\wsrec`。

2. **【根因·已实证】AppStream/WorkSpaces Applications 上 `aws` CLI 必须带 `--profile appstream_machine_role`。** fleet IAM 角色的凭证**不走默认凭证链**（IMDS 取不到），而是暴露在这个命名 profile 里（AWS 官方 sample script_b 用的就是 `-ProfileName appstream_machine_role`）。
   - **症状**：`bootstrap.log` 里 `aws s3 cp ... 失败 (exit 1)`，两个 S3 拉取全挂，launcher `[ERROR] no record-agent.ps1 available; abort`，`recordings/` 和 `agent.log` 全空。
   - **实证**：在会话里 `aws s3 cp <obj> . --region ...` 不带 profile 失败（Unable to locate credentials）；带 `--profile appstream_machine_role` 成功。
   - **修复**：`session-start.ps1` 两处 pull + `record-agent.ps1` 两处 upload(Invoke-Flush/Send-Log) 全部加 `--profile $AwsProfile`；config.json 加 `awsProfile: "appstream_machine_role"`。**launcher 是烤进镜像的 → 必须重烤镜像**（record-agent 走 S3 分发不用）。

3. **record-agent 加了自诊断 `Send-Log`**：每轮循环/启动/退出都把 `agent.log` 传 `s3://<bucket>/<Prefix>/agent.log`，这样实例回收后仍能看录制端日志（不用重烤，走 S3）。

4. **诊断手段（本轮验证有效）**：会话活着时，让用户在会话内 PowerShell `Get-Content C:\wsrec\buffer\bootstrap.log` 直接读——顶层 `C:\wsrec` 用户上下文能读到 SYSTEM 写的日志（比 ProgramData 时代的虚拟化视图靠谱）。这是定位 launcher 失败的关键一招。

5. **镜像/图标坑**：`create-image` 前必须 `add-application`；Server 2022 上 `notepad.exe` 自动取图标会失败（"icon file cannot be loaded"），要自画一张 256x256 PNG 用 `--absolute-icon-path` 传入。

**当前 go/no-go 仍未定**：修完 profile、重烤镜像 v3、fleet 切 v3 后，才第一次能真正跑到 ffmpeg gdigrab 在 PsExec `-i -s` SYSTEM+会话桌面上下文抓屏这一步。抓到画面=方案成立；黑屏=转第三方 UAM。

---

## ✅ go/no-go 结论：GO（2026-07-07，端到端已验证）

> 上面"go/no-go 仍未定"到此**结清**。方案成立。

- **证据**：S3 `recordings/PhotonUser/2026/07/07/EC2AMAZ-SS524IQ_1/` 出现 `agent.log` + `rec_20260707-164422.mp4`；会话结束封口后 mp4=1.1MB，`ffprobe` 确认 **h264 / 1280x720 / 253 秒**；抽第 120 秒一帧 `ffmpeg signalstats` YAVG=182.81 / YMIN=16 / YMAX=235 → **真实浅色桌面，非黑屏**，用户肉眼确认 OK。
- **gdigrab 黑屏风险已排除**：PsExec `-i <SessionId> -s`（SYSTEM+会话桌面）上下文下 gdigrab 正常抓屏。
- **让它跑通的关键修复**：① 路径 `C:\ProgramData\wsrec`→`C:\wsrec`；② `aws` 全部带 `--profile appstream_machine_role`（fleet 角色凭证在命名 profile，不走默认链）；③ 图标坑（自画 PNG + `--absolute-icon-path`）；④ 镜像迭代到 v3。
- **收尾**：`segmentSeconds` 300→60（已推 S3，免重烤）；CFN `ImageName` drift 修复为 v3；fleet 停机省钱。
- **下一步重点**（方案成立后升级为"该做"）：跨境合规（最高，先问法务）、触发机制改用 `WTSConnectState`、可观测性上 CloudWatch、网络生产化。

> 客户从零复现完整步骤（含每条命令）见 `agent/REPRODUCE.md`。

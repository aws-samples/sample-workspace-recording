# WorkSpaces / AppStream 远程员工屏幕录制 Agent

在 **Amazon WorkSpaces Applications（原 AppStream 2.0）** 的非持久 Windows 会话上，用 **ffmpeg gdigrab** 连续录制桌面，以 **SYSTEM 身份 + PsExec 进会话桌面**跑（既能抓到画面，又让普通员工无法停止/篡改），录像用 **fleet IAM 角色**加密上传 S3。

> **状态（2026-07-07）**：端到端已验证跑通。录像 S3 有有效 mp4（h264 / 1280x720），抽帧确认真实桌面、非黑屏。当前生产镜像 `wsrec-win2022-agent-v3`。
> **完整可复现步骤（从零到端到端，含每条命令）见 [`REPRODUCE.md`](./REPRODUCE.md)。** 本文件是速览。

- 平台：WorkSpaces Applications（非持久 / Windows / DESKTOP 视图）
- 区域：`ap-northeast-2`（首尔；正式定区域前请从目标网络实测延时）
- 触发：**会话期间持续录制**（早期基于 `GetLastInputInfo` 的"空闲即停"已移除——"在看不动手"会漏录；后续改用 `WTSConnectState`）
- 上传：会话内 `aws s3 cp`，凭证走 fleet IAM 角色，**但必须带 `--profile appstream_machine_role`**（见下）

## 架构：bootstrap + S3 分层（改逻辑不重烤镜像）

传统 fleet 的 session script 只能烤进镜像、不能从 S3 加载。为避免每次改逻辑都重烤镜像，分两层：

| 层 | 位置 | 内容 | 变动频率 |
|---|---|---|---|
| **稳定壳** | 烤进镜像（打一次） | session 配置、bootstrap `session-start.ps1`/`session-stop.ps1`、seed `config.json`、**ffmpeg**、**PsExec**、**AWS CLI v2** | 极少 |
| **业务层** | S3 `agent-scripts/` | `record-agent.ps1`、运行时 `config.json` | 经常 |

**两段式启动流**（照 AWS 官方 `aws-samples/appstream-session-recording`）：

```
会话登录
  -> AppStream 以 SYSTEM 上下文跑 session-start.ps1 (launcher)
     -> 从 s3://<bucket>/agent-scripts/ 拉最新 record-agent.ps1 + config.json（带 --profile）
     -> query session 等会话 Active、拿 SessionId
     -> PsExec -d -i <SessionId> -s powershell -File record-agent.ps1   # SYSTEM 进会话桌面
        -> ffmpeg gdigrab 连续分段录桌面；分辨率变化/崩溃自动重启
        -> 分段静默 >= quietSeconds 上传 S3 recordings/...，成功即删本地
会话登出
  -> session-stop.ps1 落 .stop -> record-agent 停录 + 冲刷剩余分段上传
```

## 文件

| 文件 | 作用 |
|---|---|
| `config.json` | 配置（S3 桶、区域、路径、帧率、分段时长、profile、KMS 等） |
| `record-agent.ps1` | 录制 Agent（**S3 分发**）：SYSTEM+会话桌面，ffmpeg 连续分段 + 分辨率/崩溃重启 + 上传 S3 + `agent.log` 传 S3 自诊断 |
| `session-start.ps1` | SessionStart launcher（**烤进镜像**，SYSTEM）：拉 S3 脚本 + 等 Active + PsExec 拉起 record-agent |
| `session-stop.ps1` | SessionTermination（**烤进镜像**，SYSTEM）：落停止标志并等冲刷 |
| `appstream-session-scripts-config.json` | AppStream 会话脚本配置（**context=system**，被 image-setup 写到 `C:\AppStream\SessionScripts\config.json`） |
| `image-setup.ps1` | 在 Image Builder 上运行：部署稳定壳 + 装 ffmpeg/PsExec/AWS CLI + 写会话脚本配置 |
| `upload-agent-scripts.sh` | 本机把 `record-agent.ps1`/`config.json` 传到 S3 `agent-scripts/`（改逻辑免重烤） |
| `../infra/workspaces-recording.yaml` | CloudFormation：KMS + S3 + fleet IAM 角色 + AppStream Fleet/Stack（过 cfn-lint） |

## 配置项（config.json）

| 字段 | 说明 |
|---|---|
| `s3Bucket` | 录像目标 S3 桶名（**改成你的桶**，需与 `region` 同区） |
| `region` | 部署区域，默认 `ap-northeast-2` |
| `ffmpegPath` | 镜像内 ffmpeg 绝对路径，默认 `C:\wsrec\ffmpeg\bin\ffmpeg.exe` |
| `awsPath` | AWS CLI 绝对路径，默认 `C:\Program Files\Amazon\AWSCLIV2\aws.exe` |
| `awsProfile` | **fleet 角色的命名 profile，默认 `appstream_machine_role`**（关键，见下） |
| `psexecPath` | PsExec 绝对路径，默认 `C:\wsrec\bin\PsExec64.exe` |
| `scriptsPrefix` | S3 脚本前缀，默认 `agent-scripts` |
| `localDir` | 本地录像缓冲目录，默认 `C:\wsrec\buffer` |
| `frameRate` | 录制帧率，默认 6 |
| `segmentSeconds` | 分段时长（秒），默认 **60** |
| `pollSeconds` | 主循环轮询间隔，默认 5 |
| `quietSeconds` | 文件多少秒无写入才认为"写完可上传"，默认 30 |
| `idleThresholdSeconds` | （保留字段，当前**不用于停录**，持续录） |
| `sseKms` | 是否用 SSE-KMS 上传，默认 true |
| `kmsKeyId` | 指定 CMK；留空且 `sseKms=true` 时用默认 aws:kms |

S3 key 结构：`recordings/<用户>/<yyyy>/<MM>/<dd>/<主机>_<会话>/rec_<时间戳>.mp4`

## 关键坑（都已实证）

- **🔴 `aws` 必须带 `--profile appstream_machine_role`**：AppStream fleet 角色凭证**不走默认凭证链**（IMDS 取不到），暴露在这个命名 profile 里。不带 profile → `aws s3 cp` 报 `Unable to locate credentials`、exit 1 → launcher abort → 什么都不录。所有脚本已内置该 profile。
- **SYSTEM + PsExec `-i <SessionId> -s` 是抓屏成败关键**：在普通 user shell / session 0 里 `ffmpeg -f gdigrab -i desktop` 会报 `Can't find window from handle ... aborting`（拿不到桌面窗口，不是黑屏）。必须让 ffmpeg 跑在会话桌面上下文。这一步同时解决**防篡改**（SYSTEM 跑，员工无 admin 停不掉）。因此 session 脚本 context 必须是 **system**（才能 PsExec `-s`）。
- **PowerShell 脚本必须 ASCII-only**：Windows PS 5.1 按 ANSI 读 `.ps1`，中文会乱码破坏解析。
- **路径统一在 `C:\wsrec`**（不要用 `C:\ProgramData\wsrec`——fleet 机器无此结构、交互 shell 视图虚拟化不可靠）。
- **create-image 前必须 `add-application`**，否则报 "No applications are in the application catalog"；Server 2022 上 `notepad.exe` 自动取图标会失败，需自画 256x256 PNG 用 `--absolute-icon-path` 传入。
- **验证 S3 一律用 `aws s3api list-objects-v2`**，不要用 `aws s3 ls`（本环境曾给出不可靠输出）。

## 合规 / 生产化（Agent 之外，需在方案层落实）

- **🔴 跨境数据出境**：员工在境内、录像存境外（如首尔）涉数据出境评估，**先问法务/合规**。
- **告知与同意**：登录横幅 + 员工书面同意（多地强制）。
- **留存与审计**：`EnableObjectLock=true`（WORM）、CloudTrail S3 数据事件、调阅审计/破玻璃流程。
- **可观测性**：`agent.log`/`bootstrap.log` 随非持久实例回收丢失；record-agent 已把 `agent.log` 传 S3，进一步可上 CloudWatch。
- **网络生产化**：私有子网 + S3 网关端点 + KMS 接口端点 + NAT，替换当前公有子网 + `EnableDefaultInternetAccess=true`。
- **持久化**：当前非持久 fleet。若"办公需持久桌面"，评估 WorkSpaces Personal（无 session scripts，录制 agent 改登录任务/服务）。

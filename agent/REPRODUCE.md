本指南帮助你在**自己的 AWS 账号**中从零部署同一套会话录屏方案。
镜像属于账号私有，需要自行烤入 `ffmpeg + PsExec + AWS CLI`；CloudFormation 模板、脚本、配置模板和部署流程均可复用。

> 已验证结论：本方案端到端跑通，录到真实桌面（h264 / 1280x720），gdigrab 黑屏风险已排除。
> 架构与配置速览见 [`../README.md`](../README.md)；本文件给**每一步的具体命令**。

---

## 0. 方案与顺序总览

```
用户登录会话
  -> AppStream 以 SYSTEM 跑 session-start.ps1 (launcher, 烤在镜像里)
     -> 从 S3 agent-scripts/ 拉最新 record-agent.ps1 + 已渲染的运行时 config.json (带 --profile appstream_machine_role)
     -> 等会话 Active 拿 SessionId -> PsExec -d -i <SessionId> -s 把 record-agent 以 SYSTEM 送进会话桌面
        -> ffmpeg gdigrab 连续分段录桌面 -> 分段上传 S3 recordings/...
用户登出 -> session-stop.ps1 落 .stop -> record-agent 停录 + 冲刷上传
```

**为什么这个顺序**：镜像里的 fleet 要填镜像名，镜像里的脚本要往你的桶传录像。存在先有鸡还是先有蛋。推荐分两段部署：

1. 先建**地基层**（S3 / KMS / fleet IAM 角色），`DeployStreaming=false`，让桶和 KMS Key 先存在。
2. 复制 `.env.example` 为本地 `.env`，填入 CloudFormation 输出；脚本生成 `config.runtime.json` 并上传运行时文件。
3. 把不含 `.env` 的 Agent 包复制到 Image Builder，烤入稳定壳和生成的 seed 配置。
4. 用镜像名**重新部署**，`DeployStreaming=true`，创建 Fleet / Stack / 关联。
5. 启动 fleet，连接会话测试并验证 S3。

---

## 前置条件

- 一个 AWS 账号，目标区域支持 WorkSpaces Applications / AppStream 2.0（示例使用 `us-east-1`，请按需替换）。
- 本机装好 **AWS CLI v2**，且凭证有足够权限（CloudFormation / S3 / KMS / IAM / AppStream）。
- 目标区域里有一个 **VPC**，至少一个**子网**和一个**安全组**（能出网到 S3：公网出网，或配 S3 网关端点）。
- 拿到本仓库的 `infra/workspaces-recording.yaml` 和整个 `agent/` 目录。
- **AppStream 实例并发配额 > 0**（新账号常见 quota=0，需在 Service Quotas 申请，否则 fleet 起不来）。

### 设置环境变量（后续命令都用它们）

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
# S3 桶名必须全局唯一
export BUCKET=wsrec-${ACCOUNT_ID}-${AWS_REGION}
export STACK=wsrec-foundation
# 你的网络（换成你自己的）
export SUBNETS=subnet-aaaaaaaa,subnet-bbbbbbbb
export SGS=sg-xxxxxxxx
# 你要给镜像起的名字
export IMAGE_NAME=wsrec-win2022-agent-v1
echo "region=$AWS_REGION account=$ACCOUNT_ID bucket=$BUCKET"
```

---

## 步骤 1：部署地基层（S3 + KMS + fleet IAM 角色）

`DeployStreaming=false` 时只建 S3 桶、KMS CMK、fleet IAM 角色，**不建 fleet**（此时还没镜像）。

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK" \
  --template-file infra/workspaces-recording.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      RecordingsBucketName="$BUCKET" \
      DeployStreaming=false
```

验证建好了（拿桶名和 KMS CMK ARN）：

```bash
aws cloudformation describe-stacks --stack-name "$STACK" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs" --output table
```

记下 `RecordingsBucket` 和 `RecordingsKeyArn`。KMS 别名固定为 `alias/$BUCKET`，后续可把别名或 Key ID 写入本地 `.env`。

取得 KMS Key ID：

```bash
export KMS_KEY_ID=$(aws kms describe-key --key-id "alias/$BUCKET" --region "$AWS_REGION" \
  --query "KeyMetadata.KeyId" --output text)
```

---

## 步骤 2：创建本地环境配置并生成运行时 JSON

`config.template.json` 只包含 `${WSREC_*}` 占位符，可以安全提交。真实环境值写入 `agent/.env`；该文件和生成的 `agent/config.runtime.json` 均被 `.gitignore` 忽略。

```bash
cd agent
cp .env.example .env
```

编辑 `.env`，至少替换以下值：

```dotenv
WSREC_S3_BUCKET=replace-with-your-recordings-bucket
WSREC_REGION=us-east-1
WSREC_KMS_KEY_ID=replace-with-your-kms-key-id
```

也可以由当前 shell 变量生成本地 `.env`，同时保留示例中的其余默认值：

```bash
cp .env.example .env
python3 - <<'PY'
import os
from pathlib import Path
p = Path('.env')
text = p.read_text()
text = text.replace('WSREC_S3_BUCKET=replace-with-your-recordings-bucket', f'WSREC_S3_BUCKET={os.environ["BUCKET"]}')
text = text.replace('WSREC_REGION=us-east-1', f'WSREC_REGION={os.environ["AWS_REGION"]}')
text = text.replace('WSREC_KMS_KEY_ID=', f'WSREC_KMS_KEY_ID={os.environ["KMS_KEY_ID"]}')
p.write_text(text)
PY
```

生成并验证强类型运行时配置，但暂不上传：

```bash
./upload-agent-scripts.sh --render-only
python3 -m json.tool config.runtime.json >/dev/null
cd ..
```

`.env` 不会被执行或上传。渲染器只解析键值、替换占位符，并把数字和 Boolean 恢复为 JSON 原生类型。

---

## 步骤 3：把 Agent 脚本和运行时配置传到 S3

`record-agent.ps1` 和生成的 `config.runtime.json` 走 S3 分发。上传时，运行时配置对象仍命名为 `config.json`，以兼容 bootstrap。

```bash
cd agent
chmod +x upload-agent-scripts.sh
./upload-agent-scripts.sh          # 传 record-agent.ps1 + config.json
cd ..
```

验证（**用 list-objects-v2，不要用 `aws s3 ls`**）：

```bash
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix agent-scripts/ \
  --region "$AWS_REGION" --query "Contents[].{Key:Key,Size:Size}" --output table
```

应看到 `agent-scripts/record-agent.ps1` 和 `agent-scripts/config.json`。

---

## 步骤 4：在 Image Builder 烤镜像（你自己烤，不复用别人的镜像）

### 4.1 启动一个 Image Builder
 
用控制台最省事（**WorkSpaces Applications / AppStream 2.0 → Images → Image Builder → Launch Image Builder**），
选一个 **Windows Server 2022** 基础镜像、`stream.standard.medium`、放进你的 VPC/子网/SG。

或用 CLI —— 先找一个 AWS 提供的 Windows Server 2022 基础镜像名：

```bash
aws appstream describe-images --type PUBLIC --region "$AWS_REGION" \
  --query "Images[?contains(Name,'WinServer2022')].Name" --output table
```

用上面某个名字启动 builder（换掉 `<BASE_IMAGE_NAME>`）：

```bash
aws appstream create-image-builder \
  --name wsrec-builder \
  --image-name "<BASE_IMAGE_NAME>" \
  --instance-type stream.standard.medium \
  --vpc-config "SubnetIds=[$(echo $SUBNETS | cut -d, -f1)],SecurityGroupIds=[$SGS]" \
  --enable-default-internet-access \
  --region "$AWS_REGION"

# 等到 RUNNING
aws appstream describe-image-builders --names wsrec-builder --region "$AWS_REGION" \
  --query "ImageBuilders[0].State" --output text
```

Builder 到 `RUNNING` 后，在控制台点 **Connect** 用管理员身份流化进去。

### 4.2 把 agent/ 目录弄进 Builder

Builder 是干净的 Windows，需要把 `agent/` 这几个小文本文件弄进去。最简单：打包传 S3，进 Builder 用 `Invoke-WebRequest` 拉预签名 URL。

**在你本机**：

```bash
cd agent
# Ensure config.runtime.json exists before packaging.
./upload-agent-scripts.sh --render-only
# Never include the local .env file in the Image Builder package.
zip -r /tmp/agent.zip . -x '*.md' '.env' '.env.example'
aws s3 cp /tmp/agent.zip "s3://$BUCKET/tmp/agent.zip" --region "$AWS_REGION" --sse aws:kms
# 生成 1 小时有效的预签名下载链接
aws s3 presign "s3://$BUCKET/tmp/agent.zip" --expires-in 3600 --region "$AWS_REGION"
cd ..
```

复制打印出来的 URL。**在 Builder 里的 PowerShell（管理员）**：

```powershell
Invoke-WebRequest -Uri "<粘贴预签名URL>" -OutFile C:\agent.zip
Expand-Archive C:\agent.zip -DestinationPath C:\agent -Force
cd C:\agent
```

> 用完记得删桶里的临时包：`aws s3 rm "s3://$BUCKET/tmp/agent.zip" --region "$AWS_REGION"`

### 4.3 运行 image-setup.ps1（装 ffmpeg + PsExec + AWS CLI + 写会话脚本配置）

**在 Builder 里（管理员 PowerShell，`C:\agent` 目录下）**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\image-setup.ps1
```

它会：把稳定壳脚本拷到 `C:\wsrec`；下载安装 **ffmpeg**（`C:\wsrec\ffmpeg\bin\ffmpeg.exe`）、**PsExec64**（`C:\wsrec\bin`）、**AWS CLI v2**；把 `appstream-session-scripts-config.json` 写到 `C:\AppStream\SessionScripts\config.json`（**context=system**）。

自检（都应存在）：

```powershell
Test-Path C:\wsrec\ffmpeg\bin\ffmpeg.exe
Test-Path C:\wsrec\bin\PsExec64.exe
Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
Test-Path C:\AppStream\SessionScripts\config.json
```

### 4.4 封装镜像（add-application + create-image）

`create-image` 前**必须先加至少一个应用**，否则报 "No applications are in the application catalog"。
Server 2022 上 `notepad.exe` 自动取图标会失败，需自画一张 256x256 PNG 当图标。

**在 Builder 里**（先做一张占位图标）：

```powershell
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 256,256
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::SteelBlue)
$bmp.Save("C:\wsrec\icon.png",[System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

$ia = "C:\Program Files\Amazon\Photon\ConsoleImageBuilder\image-assistant.exe"
& $ia add-application --name Notepad --display-name Notepad `
    --absolute-app-path "C:\Windows\System32\notepad.exe" `
    --absolute-icon-path "C:\wsrec\icon.png"
& $ia create-image --name "wsrec-win2022-agent-v1"    # 字面量，要和本机 $IMAGE_NAME 一致
```

> Builder 里是 Windows PowerShell，没有你本机 bash 的 `$IMAGE_NAME` 变量，`--name` 直接写字面量（如 `wsrec-win2022-agent-v1`），务必和步骤 0 设的 `$IMAGE_NAME` 一致。
> 跑完 Builder 会快照并断开连接（正常）。

**在你本机**等镜像 AVAILABLE：

```bash
aws appstream describe-images --type PRIVATE --region "$AWS_REGION" \
  --query "Images[?Name=='$IMAGE_NAME'].{Name:Name,State:State}" --output table
```

---

## 步骤 5：部署流化层（Fleet + Stack + 关联）

镜像 AVAILABLE 后，用**同一个 stack**、同一个模板，打开 `DeployStreaming=true` 并填镜像名/网络。
`MaxSessionsPerInstance=1` 为单会话 fleet（模板会自动处理容量参数）。

```bash
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK" \
  --template-file infra/workspaces-recording.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      RecordingsBucketName="$BUCKET" \
      DeployStreaming=true \
      ImageName="$IMAGE_NAME" \
      SubnetIds="$SUBNETS" \
      SecurityGroupIds="$SGS" \
      EnableDefaultInternetAccess=true \
      MaxSessionsPerInstance=1
```

拿 fleet / stack 名：

```bash
aws cloudformation describe-stacks --stack-name "$STACK" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='FleetName'||OutputKey=='StackName'].{K:OutputKey,V:OutputValue}" \
  --output table
```

fleet 名是 `${BUCKET}-fleet`，stack（AppStream Stack）名是 `${BUCKET}-stack`。

---

## 步骤 6：启动 fleet

CloudFormation 建出的 fleet 初始是 **STOPPED**，必须手动启动：

```bash
aws appstream start-fleet --name "${BUCKET}-fleet" --region "$AWS_REGION"

# 轮询到 RUNNING
aws appstream describe-fleets --names "${BUCKET}-fleet" --region "$AWS_REGION" \
  --query "Fleets[0].State" --output text
```

> 起不来又退回 STOPPED 且 `FleetErrors` 为空 → 多半是 **AppStream 实例并发配额=0**，去 Service Quotas 申请提额。

---

## 步骤 7：连入会话测试

给用户授权并拿一个流化 URL（测试用）。`--user-id` 用任意标识邮箱：

```bash
aws appstream create-streaming-url \
  --stack-name "${BUCKET}-stack" \
  --fleet-name "${BUCKET}-fleet" \
  --user-id "test@example.com" \
  --region "$AWS_REGION" \
  --query "StreamingURL" --output text
```

> 若报权限不足（缺 `appstream:CreateStreamingURL`），改用控制台：**Stacks → 选中 stack → Actions → Create streaming URL**。

把 URL 贴到浏览器打开，进入桌面后**动一下鼠标键盘、正常操作几十秒**（session script 会以 SYSTEM 自动拉起录制，无需你手动做任何事）。

---

## 步骤 8：验证 S3 出录像

分段在"录满 `segmentSeconds`（默认 60s）/ 会话结束"时才写完并上传，且要静默 `quietSeconds`（默认 30s）。
所以**操作 1-2 分钟后**再查，或直接登出会话触发冲刷：

```bash
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix recordings/ \
  --region "$AWS_REGION" --query "Contents[].{Key:Key,Size:Size,Modified:LastModified}" --output table
```

应看到 `recordings/<用户>/<yyyy>/<MM>/<dd>/<主机>_<会话>/rec_*.mp4` 和 `agent.log`。

**下载并确认不是黑屏**（在本机，需有 `kms:Decrypt` 权限 + 装 ffmpeg）：

```bash
# 换成上一步列出的真实 key
KEY="recordings/.../rec_XXXX.mp4"
aws s3 cp "s3://$BUCKET/$KEY" /tmp/rec.mp4 --region "$AWS_REGION"

# 看编码/分辨率/时长
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,duration \
  -of default=noprint_wrappers=1 /tmp/rec.mp4

# 抽一帧算平均亮度，排除黑屏（YAVG 接近 16=黑；越大越亮=有画面）
ffmpeg -hide_banner -loglevel info -i /tmp/rec.mp4 -vf "select=eq(n\,120),signalstats,metadata=print" \
  -frames:v 1 -f null - 2>&1 | grep -Ei "YAVG|YMIN|YMAX"
```

看到 `h264 / 1280x720`、`YAVG` 明显 > 16，就是**真实桌面、方案跑通**。

---

## 步骤 9：排查（跑不通时按这个查）

会话**还活着**时，进会话内 PowerShell 直接读日志（顶层 `C:\wsrec` 用户上下文能读到 SYSTEM 写的日志）：

```powershell
Get-Content C:\wsrec\buffer\bootstrap.log   # launcher: 拉脚本 / 找 Active session / PsExec rc
Get-Content C:\wsrec\buffer\agent.log       # record-agent: ffmpeg 起没起 / 抓没抓到 / 上传结果
```

`agent.log` 也会被传到 `s3://$BUCKET/agent-scripts/agent.log`（实例回收后也能看）：

```bash
aws s3 cp "s3://$BUCKET/agent-scripts/agent.log" /tmp/agent.log --region "$AWS_REGION" && cat /tmp/agent.log
```

session script 的 stdout/stderr 在 AppStream 自动建的日志桶（前缀 `appstream-logs-`）：

```bash
aws s3api list-buckets --query "Buckets[?starts_with(Name,'appstream-logs')].Name" --output text
# 然后 list-objects-v2 看 .../SessionScriptsLogs/SessionStart|SessionTermination/
```

**常见症状 → 原因**：

| 症状 | 原因 / 处理 |
|---|---|
| `bootstrap.log` 里 `aws s3 cp ... (exit 1)`、`no record-agent.ps1; abort` | 没带 `--profile appstream_machine_role`（脚本已内置；若你改过脚本要保留）；或 fleet 角色缺 S3/KMS 权限 |
| `recordings/` 一直空、`agent.log` 空 | launcher 没拉到脚本（见上）；或 fleet 用的镜像没烤 ffmpeg/PsExec |
| `agent.log` 里 `ffmpeg not found` | 镜像没烤进 ffmpeg，重跑 image-setup 重烤 |
| `agent.log` 里 gdigrab `Can't find window from handle` | record-agent 没跑在会话桌面上下文 —— 确认 session 配置 `context=system` 且 PsExec 用了 `-i <SessionId> -s` |
| fleet 起不来退回 STOPPED，`FleetErrors` 空 | AppStream 实例并发配额=0，申请提额 |
| `create-image` 报 no applications / icon cannot be loaded | 先 `add-application`；图标用自画 PNG + `--absolute-icon-path` |

---

## 步骤 10：改录制逻辑（免重烤镜像）

`record-agent.ps1` 和生成后的运行时 `config.json` 走 S3。修改录制参数时编辑本地 `.env`，然后重新渲染并上传；**下个会话自动生效**：

```bash
cd agent
# 编辑 .env，例如调整 WSREC_SEGMENT_SECONDS
./upload-agent-scripts.sh
cd ..
```

`.env` 和 `config.runtime.json` 都不会提交到 Git。只有修改**烤进镜像的**部分（`session-start.ps1` / `session-stop.ps1` / 会话脚本配置 / ffmpeg / PsExec / AWS CLI），或修改 bootstrap 定位 S3 所需的 seed 参数时，才需要重烤镜像并更新 stack。

---

## 步骤 11：省钱 —— 不用时停掉

```bash
# 停 fleet（按运行实例计费）
aws appstream stop-fleet --name "${BUCKET}-fleet" --region "$AWS_REGION"

# 停 Image Builder（不删，保留以后重烤）
aws appstream stop-image-builder --name wsrec-builder --region "$AWS_REGION"
```

S3 里的录像照常保留（Lifecycle 会转 Deep Archive 降成本）。下次要用再 `start-fleet`。

---

## 步骤 12：彻底清理（可选，删除所有资源）

> ⚠️ 破坏性操作。S3 桶和 KMS CMK 在模板里是 `DeletionPolicy: Retain`，**不会被删 stack 连带删除**，需手动清。删桶会**永久删除所有录像**，务必确认。

```bash
# 删镜像 / builder
aws appstream delete-image --name "$IMAGE_NAME" --region "$AWS_REGION"
aws appstream delete-image-builder --name wsrec-builder --region "$AWS_REGION"

# 删 stack（会删 Fleet/Stack/关联/IAM 角色；S3+KMS 因 Retain 保留）
aws cloudformation delete-stack --stack-name "$STACK" --region "$AWS_REGION"
aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$AWS_REGION"

# 手动清 S3（会永久删录像！先确认桶名）
aws s3 rm "s3://$BUCKET" --recursive --region "$AWS_REGION"
aws s3api delete-bucket --bucket "$BUCKET" --region "$AWS_REGION"

# KMS CMK 只能计划删除（最短 7 天）；拿 key id 后：
# aws kms schedule-key-deletion --key-id <KEY_ID> --pending-window-in-days 7 --region "$AWS_REGION"
```

---

## 上线前必须补（合规 / 生产化，Agent 之外）

- **隐私与数据驻留**：根据部署区域、用户所在地和适用法律完成隐私、劳动与数据传输评估。
- **告知与同意**：提供清晰的登录提示，并取得适用法律要求的授权或同意。
- **留存与审计**：`EnableObjectLock=true`（WORM）、CloudTrail S3 数据事件、调阅审计 / 破玻璃流程。
- **触发机制**：当前会话期间持续录；建议改用 `WTSConnectState`（Active 录、Disconnected 停）。
- **网络生产化**：私有子网 + S3 网关端点 + KMS 接口端点 + NAT，替换公有子网 + `EnableDefaultInternetAccess=true`。
- **持久化**：当前非持久桌面；若"办公需持久"评估 WorkSpaces Personal。
- **供应链**：严格管控 `agent-scripts/` 写权限（该目录脚本会以 SYSTEM 在所有会话运行）。

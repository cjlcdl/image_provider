# 勇气大存储

这是一个纯 API 的文件存储服务，服务端基于 Python 标准库 HTTP Server 实现，客户端示例为 Flutter。项目当前已经支持：

- 临时上传与永久上传
- 流式分片上传与断点续传
- 文件列表、重命名、删除、切换临时/永久存储
- 虚拟多级文件夹、加密文件夹、文件移动到文件夹
- Windows 桌面端拖拽上传文件与文件夹
- 文件夹递归上传与服务端打包 zip 下载
- 受保护文件的临时下载直链
- 基于 `Courage-Token` 的管理鉴权
- 基于 `APP_CHANNEL`、`USER` 的审计日志记录

详细接口定义见 [API.md](API.md)。

## 项目结构

```text
image_provider/
  app.py
  config.py
  server_handler.py
  server_handlers_upload.py
  server_handlers_files.py
  server_handlers_folders.py
  server_runtime.py
  server_auth.py
  server_storage.py
  folder_index.py
  keys/
    permanent_public.pem
    permanent_private.pem
  storage/
    temporary/
    permanent/
    .folder_index.json
    .upload_sessions/
  flutter_client_app/
```

## 服务端运行要求

- Python `3.8.10` 及以上
- 如果需要永久上传、管理接口、文件夹密码令牌或下载令牌校验，需安装 `cryptography`

服务端没有单独维护 `requirements.txt`，当前核心运行依赖只有 `cryptography` 这一项第三方库。只做临时上传和公开文件访问时，即使未安装它，服务也能启动；但永久鉴权与管理能力会不可用。

安装依赖：

```powershell
python -m pip install --upgrade pip
python -m pip install cryptography
```

## 服务端配置方法

服务端推荐通过环境变量配置，而不是直接改 [config.py](config.py)。这样更适合本地调试、反向代理和多环境部署。

以下路径示例默认都以仓库根目录为当前工作目录，统一使用相对路径。

### 1. 最小可运行配置

本地测试只需要下面这几项：

```powershell
$env:IMAGE_PROVIDER_HOST = "0.0.0.0" # 替换为实际的IP地址
$env:IMAGE_PROVIDER_PORT = "8080" # 替换为实际的端口号
$env:IMAGE_PROVIDER_PUBLIC_BASE_URL = "https://your-domain.com" # 替换为实际的域名
python app.py
```

### 2. 推荐完整配置

```powershell
$env:IMAGE_PROVIDER_HOST = "0.0.0.0"
$env:IMAGE_PROVIDER_PORT = "8080"
$env:IMAGE_PROVIDER_PUBLIC_BASE_URL = "https://your-domain.com"
$env:IMAGE_PROVIDER_FILE_ROUTE_PREFIX = "/images"
$env:IMAGE_PROVIDER_STORAGE_ROOT = ".\storage"
$env:IMAGE_PROVIDER_KEYS_ROOT = ".\keys"
$env:IMAGE_PROVIDER_PUBLIC_KEY_PATH = ".\keys\permanent_public.pem"
$env:IMAGE_PROVIDER_PRIVATE_KEY_PATH = ".\keys\permanent_private.pem"
$env:IMAGE_PROVIDER_AUDIT_LOG_FILE_PATH = ".\logs\audit.log"
$env:IMAGE_PROVIDER_MAX_UPLOAD_BYTES = "4294967296"
$env:IMAGE_PROVIDER_CLEANUP_HOUR = "6"
$env:IMAGE_PROVIDER_DOWNLOAD_TOKEN_MAX_DAYS = "30"
$env:IMAGE_PROVIDER_RATE_LIMIT_WINDOW_SECONDS = "60"
$env:IMAGE_PROVIDER_RATE_LIMIT_MAX_REQUESTS = "30"
python app.py
```

### 3. 关键环境变量说明

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `IMAGE_PROVIDER_HOST` | `0.0.0.0` | 服务监听地址 |
| `IMAGE_PROVIDER_PORT` | `8080` | 服务监听端口 |
| `IMAGE_PROVIDER_PUBLIC_BASE_URL` | `https://your-domain.com` | 对外访问基址，生成下载链接和客户端展示时使用 |
| `IMAGE_PROVIDER_FILE_ROUTE_PREFIX` | `/images` | 文件访问路由前缀；兼容旧变量 `IMAGE_PROVIDER_IMAGE_ROUTE_PREFIX` |
| `IMAGE_PROVIDER_STORAGE_ROOT` | `storage/` | 文件、索引和续传会话的根目录 |
| `IMAGE_PROVIDER_AUDIT_LOG_FILE_PATH` | `logs/audit.log` | 审计日志输出文件 |
| `IMAGE_PROVIDER_FOLDER_INDEX_FILE_PATH` | `storage/.folder_index.json` | 文件夹树与下载令牌持久化文件 |
| `IMAGE_PROVIDER_UPLOAD_SESSION_ROOT` | `storage/.upload_sessions` | 断点续传会话目录 |
| `IMAGE_PROVIDER_UPLOAD_SESSION_MAX_AGE_SECONDS` | `604800` | 续传会话保留时长，默认 7 天 |
| `IMAGE_PROVIDER_RESUMABLE_UPLOAD_CHUNK_SIZE_HINT` | `4194304` | 返回给客户端的建议分片大小 |
| `IMAGE_PROVIDER_MAX_UPLOAD_BYTES` | `4294967296` | 单文件最大上传体积，默认 4GB |
| `IMAGE_PROVIDER_CLEANUP_HOUR` | `6` | 临时文件每日清理时间 |
| `IMAGE_PROVIDER_DOWNLOAD_TOKEN_MAX_DAYS` | `30` | 受保护下载链接最大有效天数 |
| `IMAGE_PROVIDER_KEYS_ROOT` | `keys/` | RSA 密钥目录 |
| `IMAGE_PROVIDER_PUBLIC_KEY_PATH` | `keys/permanent_public.pem` | RSA 公钥路径 |
| `IMAGE_PROVIDER_PRIVATE_KEY_PATH` | `keys/permanent_private.pem` | RSA 私钥路径 |
| `IMAGE_PROVIDER_RATE_LIMIT_WINDOW_SECONDS` | `60` | 上传接口限流时间窗 |
| `IMAGE_PROVIDER_RATE_LIMIT_MAX_REQUESTS` | `30` | 上传接口单窗口最大请求数 |
| `IMAGE_PROVIDER_IP_BLACKLIST` | 空 | 逗号分隔的黑名单 IP 列表 |

### 4. RSA 密钥配置

如果你需要永久上传和管理接口，必须准备一对 RSA 密钥。推荐直接放在 `keys/` 目录下：

```text
keys/
  permanent_public.pem
  permanent_private.pem
```

可用 OpenSSL 生成：

```powershell
openssl genrsa -out keys/permanent_private.pem 2048
openssl rsa -in keys/permanent_private.pem -pubout -out keys/permanent_public.pem
```

注意：

- 私钥由服务端读取，用于解密 `Courage-Token`、`Folder-Password-Token` 等令牌
- 公钥需要同步给客户端，用于加密上述令牌
- 如果 PEM 文件被编辑器加上 BOM 或破坏换行，服务端会出现 `50001 permanent token verification is unavailable`

### 5. 启动服务

```powershell
python app.py
```

启动后终端会打印监听地址，以及当前对外公开基址。

## Flutter 客户端配置方法

Flutter 示例工程位于 [flutter_client_app](flutter_client_app)。客户端当前通过 `--dart-define` 注入运行时配置。

### 1. 填写服务端公钥

Flutter 客户端现在不再把公钥直接写死在 [flutter_client_app/lib/data/global.dart](flutter_client_app/lib/data/global.dart) 中，而是通过生成文件承载。

本地生成方式：

```powershell
cd .\flutter_client_app
python generate_public_key_dart.py
```

默认情况下，脚本会优先读取环境变量 `IMAGE_PROVIDER_PUBLIC_KEY_PATH`，否则回退到 [keys/permanent_public.pem](keys/permanent_public.pem) 作为公钥来源，并生成 [flutter_client_app/lib/data/generated_public_key.dart](flutter_client_app/lib/data/generated_public_key.dart)。

如果你希望在构建完成后清空本地生成文件，可执行：

```powershell
cd .\flutter_client_app
python generate_public_key_dart.py --clear
```

### 2. 调试运行

```powershell
cd .\flutter_client_app
python generate_public_key_dart.py
flutter run --dart-define=BASE_URL=https://your-domain.com --dart-define=APP_CHANNEL=dev --dart-define=USER=Karo
```

说明：

- `BASE_URL`：客户端请求服务端的基址，当前代码里没有默认值，必须显式传入
- `APP_CHANNEL`：可选，用于写入服务端审计日志
- `USER`：可选，用于写入服务端审计日志

如果你要调试 Windows 桌面端，可直接运行：

```powershell
cd .\flutter_client_app
python generate_public_key_dart.py
flutter run -d windows --dart-define=BASE_URL=https://your-domain.com --dart-define=APP_CHANNEL=dev --dart-define=USER=Karo
```

### 3. 构建 Android APK

手动构建：

```powershell
cd .\flutter_client_app
python generate_public_key_dart.py
flutter build apk --release --dart-define=BASE_URL={http://your-domain.com} --dart-define=APP_CHANNEL={你希望添加的APP标记} --dart-define=USER={你希望添加的用户标记} --target-platform android-arm64
python generate_public_key_dart.py --clear
```

自动构建：

```powershell
cd .\flutter_client_app
python build_release.py
```

[flutter_client_app/build_release.py](flutter_client_app/build_release.py) 会在构建前自动生成 [flutter_client_app/lib/data/generated_public_key.dart](flutter_client_app/lib/data/generated_public_key.dart)，构建完成后自动恢复为空占位内容。

如果你直接启动客户端而没有先生成公钥文件，应用启动时会直接显示配置错误页，而不是等到首次发请求时才失败。

### 4. Windows 桌面端使用说明

当前 Flutter 客户端已经支持 Windows 桌面端以下交互：

- 在文件页直接把文件或文件夹拖到文件列表区域，即可触发上传。
- 拖入文件夹时会保留根文件夹和子文件夹层级；如果服务端已存在同名文件夹，会自动合并到现有目录。
- 如果拖拽或上传过程中涉及加密文件夹，客户端会在需要时提示输入对应密码。
- 多文件和文件夹批量上传时，弹窗会显示当前处理项、总进度，以及成功/失败数量；失败项详情会在完成后汇总显示。

### 5. 文件夹压缩下载使用说明

客户端文件页长按文件夹后，可选择“下载为压缩包”。

使用前请注意：

- 需要先在设置页选择固定下载目录。
- 下载的是服务端实时生成的 zip 压缩包，会递归包含该文件夹下全部子文件夹和文件。
- 如果压缩范围内包含加密文件夹，客户端会要求验证所有实际涉及到的加密文件夹密码。
- 下载过程中会显示进度条；完成后压缩包会保存到固定下载目录。

## 存储与清理行为

- 临时文件存放在 `storage/temporary/YYYYMMDD/`
- 永久文件存放在 `storage/permanent/`
- 断点续传会话存放在 `storage/.upload_sessions/`
- 文件夹索引和下载令牌信息存放在 `storage/.folder_index.json`
- 每天 `IMAGE_PROVIDER_CLEANUP_HOUR` 时自动清理临时文件、临时索引和已使用 nonce

## 审计日志

审计日志默认写入 `logs/audit.log`。当前会记录的成功操作包括：

- `list_files`
- `upload_file`
- `resumable_init`
- `resumable_status`
- `resumable_chunk`
- `resumable_cancel`
- `download_file`
- `rename_file`
- `move_file`
- `move_file_to_folder`
- `delete_file`
- `create_folder`
- `rename_folder`
- `move_folder`
- `update_folder`
- `delete_folder`

日志中会按需写入 `user`、`appChannel`、操作路径、批量标记、文件夹变更信息等字段。

## 相关文档

- 接口文档见 [API.md](API.md)
- Flutter 示例工程见 [flutter_client_app/pubspec.yaml](flutter_client_app/pubspec.yaml)

## 兼容性说明

- 服务端代码按 Python `3.8.10` 兼容写法维护
- 当前未使用 `X | None`、`Path.is_relative_to` 等高版本专属语法
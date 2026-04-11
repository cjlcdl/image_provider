# 文件服务 API 文档

## 1. 服务概述

本服务是一个纯 API 文件存储服务，支持：

- 临时上传
- 永久上传
- 流式分片上传与断点续传
- 文件访问与下载
- 文件列表查询
- 虚拟多级文件夹索引
- 加密文件夹与按会话解锁访问
- 受保护文件的临时下载直链
- 索引名重命名
- 单个/批量删除
- 临时与永久存储之间移动文件
- 文件移动到虚拟文件夹或移回根目录
- 文件夹的创建、重命名、移动、删除、加密配置更新
- 基于 `Courage-Token` 的管理鉴权
- 基于 `APP_CHANNEL`、`USER` 的审计日志记录

服务端当前使用 Python 标准库 HTTP 服务实现，文件默认存储在：

```text
storage/
  .folder_index.json
  temporary/
  permanent/
```

## 2. 基础信息

### 2.1 默认监听配置

- 默认 Host：`0.0.0.0`
- 默认 Port：`8080`
- 推荐对外访问基址：`https://your-domain.com`
- 默认文件访问前缀：`/images`

HTTPS 部署时，建议通过环境变量 `IMAGE_PROVIDER_PUBLIC_BASE_URL` 配置实际对外访问域名；文档中的 `http://127.0.0.1:8080` 示例可按需替换为你的 HTTPS 域名。

### 2.2 路由总览

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/api/health` | 健康检查 |
| `POST` | `/api/upload` | 普通上传，自动区分临时/永久 |
| `POST` | `/api/upload/resumable/init` | 创建续传会话 |
| `GET` | `/api/upload/resumable/{uploadId}` | 查询续传状态 |
| `PATCH` | `/api/upload/resumable/{uploadId}` | 上传续传分片 |
| `POST` | `/api/upload/resumable/{uploadId}/complete` | 完成续传上传 |
| `DELETE` | `/api/upload/resumable/{uploadId}` | 取消续传上传 |
| `GET` | `/api/files` | 查询文件列表 |
| `PATCH` | `/api/files` | 重命名文件索引名 |
| `DELETE` | `/api/files` | 删除单个或多个文件 |
| `POST` | `/api/files/move` | 切换临时/永久存储 |
| `POST` | `/api/files/folder` | 调整文件所属文件夹 |
| `GET` | `/api/folders` | 查询文件夹树 |
| `POST` | `/api/folders` | 创建文件夹 |
| `PATCH` | `/api/folders` | 更新文件夹 |
| `DELETE` | `/api/folders` | 删除文件夹 |
| `POST` | `/api/folders/archive` | 下载文件夹压缩包 |
| `POST` | `/api/folders/download-link` | 生成受保护下载链接 |
| `GET` | `{FILE_ROUTE_PREFIX}/...` | 访问或下载真实文件 |

### 2.3 数据格式

- 除文件本体下载接口外，所有接口都返回 JSON。
- JSON 编码统一为 `UTF-8`。

### 2.4 成功响应格式

```json
{
  "code": 0,
  "message": "ok",
  "data": {}
}
```

### 2.5 失败响应格式

```json
{
  "code": 40000,
  "message": "error message",
  "data": null
}
```

## 3. 请求头约定

### 3.1 管理鉴权头

```text
Courage-Token
```

用途：

- 永久上传鉴权
- 文件列表查询鉴权
- 文件夹列表与 CRUD 鉴权
- 文件重命名鉴权
- 文件删除鉴权
- 文件移动鉴权
- 受保护下载链接生成鉴权

### 3.2 可选审计头

```text
APP_CHANNEL
USER
```

说明：

- 这两个头均为可选。
- 不传不会影响上传、下载、查询、管理等功能。
- 如果传入，服务端会在审计日志中记录：
  - 时间
  - `USER`
  - `APP_CHANNEL`
  - 操作类型
  - 文件索引名
  - 文件路径
  - 客户端 IP

### 3.3 文件夹密码证明头

```text
Folder-Password-Token
Target-Folder-Password-Token
Folder-Passwords-Token
```

说明：

- 两个请求头都不是全局必填，仅在访问加密文件夹时需要。
- `Folder-Password-Token` 用于当前操作对象所在文件夹，例如列出加密文件夹文件、上传到加密文件夹、修改加密文件夹、为受保护文件生成下载链接。
- `Target-Folder-Password-Token` 用于目标文件夹或目标父文件夹，例如在加密父目录下创建子文件夹、把文件移动到加密文件夹、把文件夹移动到加密父目录。
- `Folder-Passwords-Token` 用于一次性验证多个加密文件夹，例如递归下载文件夹压缩包时，服务端会校验压缩范围内所有加密文件夹的密码。
- 两个 header 的值都使用与 `Courage-Token` 相同的 RSA 公钥加密 JSON 明文，再进行 Base64 编码。

明文字段：

```json
{
  "folderId": "9c9f4d7544bc45e1b6374fd8ad48b46d",
  "password": "folder-password"
}
```

`Folder-Passwords-Token` 的明文结构如下：

```json
{
  "folders": [
    {
      "folderId": "folder-a",
      "password": "password-a"
    },
    {
      "folderId": "folder-c",
      "password": "password-c"
    }
  ]
}
```

### 3.4 续传请求头

```text
Upload-Token
Upload-Offset
```

说明：

- `Upload-Token` 用于绑定一个已创建的续传会话。
- `Upload-Offset` 仅用于上传分片接口，值必须等于服务端当前已接收的字节数。
- `Upload-Offset` 不匹配时，服务端返回 `40901 upload offset mismatch`，并带回当前 `uploadedBytes`。

## 4. 健康检查接口

### 4.1 获取服务状态

- 方法：`GET`
- 路径：`/api/health`
- 鉴权：不需要

成功响应示例：

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "status": "running",
    "serverTime": "2026-04-11T05:18:09.604297+08:00",
    "cleanupHour": 6,
    "tokenHeader": "Courage-Token",
    "managementTokenReady": true,
    "downloadTokenMaxDays": 30,
    "diskTotalBytes": 536870912000,
    "diskUsedBytes": 214748364800,
    "diskFreeBytes": 322122547200
  }
}
```

字段说明：

- `status`：服务状态
- `serverTime`：服务端当前时间
- `cleanupHour`：临时文件每日清理时间点
- `tokenHeader`：永久/管理鉴权头名称
- `managementTokenReady`：服务端是否已具备管理令牌验签能力
- `downloadTokenMaxDays`：受保护下载链接允许的最大有效天数
- `diskTotalBytes` / `diskUsedBytes` / `diskFreeBytes`：当前存储盘总量、已用量、可用量

## 5. 上传接口

### 5.1 上传文件

- 方法：`POST`
- 路径：`/api/upload`
- Content-Type：`multipart/form-data`

请求字段：

| 字段 | 必填 | 类型 | 说明 |
| --- | --- | --- | --- |
| `file` | 是 | 文件 | 要上传的文件 |
| `folderId` | 否 | 字符串 | 目标虚拟文件夹 ID，传入后会把文件归档到对应文件夹 |

上传行为说明：

- 服务不做文件内容识别。
- 服务不限制任何文件后缀名。
- 服务允许无后缀文件。
- 默认单文件上传上限为 `4GB`，可通过环境变量 `IMAGE_PROVIDER_MAX_UPLOAD_BYTES` 覆盖。
- 服务会将上传文件改名后保存，不保留原始系统文件名。
- 服务会把原始上传文件名或回退文件名记录到 `indexedName`。
- 如果目标 `folderId` 对应的是加密文件夹，请同时通过 `Folder-Password-Token` 提供该文件夹密码证明。

客户端配合说明：

- Windows 桌面端可以直接把文件或文件夹拖到文件列表区域，客户端会自动展开为批量上传任务。
- 批量上传时，客户端应保留本地文件夹层级；若服务端已存在同名文件夹，应按“合并到现有目录”处理。
- 如果批量上传过程中涉及多个加密文件夹，客户端应按实际写入目标逐个索取密码，而不是对普通子目录重复索取密码。
- 客户端建议把失败项至少区分为三类：`网络失败`、`密码失败`、`服务端拒绝`。其中密码类错误通常对应 `40105`、`40107`、`40302` 或相关 folder password 提示；限流、鉴权失败、目录不存在、体积超限等可归入服务端拒绝。

### 5.2 临时上传

当请求头中未携带 `Courage-Token` 时，按临时上传处理。

规则：

- 存储目录：`storage/temporary/YYYYMMDD/`
- 返回路径格式：`/images/YYYYMMDD/{随机文件名}`
- 临时文件会在每天早上 `06:00` 自动清理

成功响应示例：

```json
{
  "code": 0,
  "message": "upload succeeded",
  "data": {
    "path": "/images/20260411/5a5bb0a68a8f46829bbd57f5fbf4e875.png",
    "url": "/images/20260411/5a5bb0a68a8f46829bbd57f5fbf4e875.png",
    "size": 2048,
    "storage": "temporary",
    "name": "5a5bb0a68a8f46829bbd57f5fbf4e875.png",
    "indexedName": "原始文件名.png",
    "mimeType": "image/png",
    "folderId": null
  }
}
```

### 5.3 永久上传

当请求头中携带有效 `Courage-Token` 时，按永久上传处理。

规则：

- 存储目录：`storage/permanent/`
- 返回路径格式：`/images/permanent/{时间戳}_{nonce}{扩展名}`
- 永久文件不会被每日清理任务删除

成功响应示例：

```json
{
  "code": 0,
  "message": "upload succeeded",
  "data": {
    "path": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk",
    "url": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk",
    "size": 4096,
    "storage": "permanent",
    "name": "1712923200_Qx7nL2bP9mZc8dRs.apk",
    "indexedName": "安装包.apk",
    "mimeType": "application/vnd.android.package-archive",
    "folderId": null
  }
}
```

### 5.4 无文件名时的处理

当上传分片没有有效文件名，或文件名仅为占位值 `upload` 时：

- 服务端会优先根据分片 `Content-Type` 推断扩展名
- 然后使用当前时间戳生成回退文件名
- 如果无法推断扩展名，则直接使用纯时间戳作为回退名

示例：

- `1775852747749.apk`
- `1775854032686`

### 5.5 流式上传与断点续传

在保持原有 `POST /api/upload` 不变的基础上，服务端新增一组续传接口：

- `POST /api/upload/resumable/init`：创建上传会话
- `GET /api/upload/resumable/{uploadId}`：查询当前上传进度
- `PATCH /api/upload/resumable/{uploadId}`：追加上传一个分片
- `POST /api/upload/resumable/{uploadId}/complete`：完成上传并生成正式文件
- `DELETE /api/upload/resumable/{uploadId}`：取消并删除上传会话

设计说明：

- 上传会话和已上传分片会持久化到磁盘
- 服务重启、进程崩溃或断电后，会话仍可继续使用
- 原有普通上传格式和下载格式完全保留，不受影响
- 永久续传上传仍通过 `Courage-Token` 决定是否进入 permanent 存储
- 后续分片请求通过 `Upload-Token` 绑定会话，不需要重复携带 `Courage-Token`

#### 5.5.1 创建上传会话

- 方法：`POST`
- 路径：`/api/upload/resumable/init`
- Content-Type：`application/json`

请求体：

```json
{
  "filename": "big-package.apk",
  "size": 10485760,
  "mimeType": "application/vnd.android.package-archive",
  "folderId": "9c9f4d7544bc45e1b6374fd8ad48b46d"
}
```

说明：

- `filename` 可选，不传时会走与普通上传相同的回退命名逻辑
- `size` 必填，表示文件总大小
- `folderId` 可选，传入后上传完成时会自动写入对应虚拟文件夹
- 如果请求头中携带有效 `Courage-Token`，会创建 permanent 上传会话；否则为 temporary 上传会话
- 如果目标文件夹是加密文件夹，同样需要携带 `Folder-Password-Token`

成功响应示例：

```json
{
  "code": 0,
  "message": "upload session created",
  "data": {
    "uploadId": "43162b0e1ba64b32a813846c82512c43",
    "uploadToken": "tEEgFYJ-sgWvJ0oN1EXrNwEbNX7CTXzzvCw2fGkHq3I",
    "storage": "permanent",
    "path": "/images/permanent/1775857399_resumeok01.bin",
    "url": "/images/permanent/1775857399_resumeok01.bin",
    "name": "1775857399_resumeok01.bin",
    "indexedName": "resume.bin",
    "mimeType": "application/octet-stream",
    "totalSize": 28,
    "uploadedBytes": 0,
    "chunkSizeHint": 4194304,
    "expiresIn": 604800
  }
}
```

#### 5.5.2 查询上传进度

- 方法：`GET`
- 路径：`/api/upload/resumable/{uploadId}`
- 请求头：`Upload-Token`

成功响应示例：

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "uploadId": "43162b0e1ba64b32a813846c82512c43",
    "storage": "permanent",
    "path": "/images/permanent/1775857399_resumeok01.bin",
    "url": "/images/permanent/1775857399_resumeok01.bin",
    "name": "1775857399_resumeok01.bin",
    "indexedName": "resume.bin",
    "mimeType": "application/octet-stream",
    "totalSize": 28,
    "uploadedBytes": 10,
    "complete": false
  }
}
```

#### 5.5.3 上传分片

- 方法：`PATCH`
- 路径：`/api/upload/resumable/{uploadId}`
- 请求头：
  - `Upload-Token`
  - `Upload-Offset`

请求体：

- 直接发送当前分片的原始二进制内容

说明：

- `Upload-Offset` 必须与服务端当前已接收字节数完全一致
- 服务端会以流式方式从请求体中分块读取并追加到会话临时文件
- 如果上传中断，客户端只需重新查询状态并从 `uploadedBytes` 继续发送

成功响应示例：

```json
{
  "code": 0,
  "message": "chunk accepted",
  "data": {
    "uploadId": "43162b0e1ba64b32a813846c82512c43",
    "uploadedBytes": 10,
    "totalSize": 28,
    "complete": false
  }
}
```

#### 5.5.4 完成上传

- 方法：`POST`
- 路径：`/api/upload/resumable/{uploadId}/complete`
- 请求头：`Upload-Token`

说明：

- 只有在 `uploadedBytes == totalSize` 时才能完成
- 完成后服务端会把会话临时文件移动到正式存储路径
- 返回格式与原有 `POST /api/upload` 成功响应一致

#### 5.5.5 取消上传会话

- 方法：`DELETE`
- 路径：`/api/upload/resumable/{uploadId}`
- 请求头：`Upload-Token`

说明：

- 会删除会话元数据和已上传的分片文件


## 6. Courage-Token 规则

### 6.1 算法与格式

- 算法：RSA
- 填充方式：PKCS#1 v1.5
- 请求头：`Courage-Token`
- 头值：RSA 密文的 Base64 编码字符串

### 6.2 明文内容

解密前明文必须是 JSON，格式如下：

```json
{
  "ts": 1712923200,
  "nonce": "Qx7nL2bP9mZc8dRs"
}
```

字段要求：

- `ts`：Unix 时间戳，单位秒
- `nonce`：8 到 64 位，只允许字母、数字、下划线、连字符

### 6.3 校验规则

- `ts` 与服务端当前时间差不能超过 300 秒
- `nonce` 只能使用一次
- 已使用的 `nonce` 保存在内存中
- 每日临时文件清理时，会一并清空内存中的已使用 `nonce`

### 6.4 处理行为

- 上传接口不带 `Courage-Token`：按临时上传处理
- 上传接口带有效 `Courage-Token`：按永久上传处理
- 管理接口必须带有效 `Courage-Token`

### 6.5 Python 生成 Token 示例

```python
import base64
import json
import time
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding

with open("keys/permanent_public.pem", "rb") as file_obj:
    public_key = serialization.load_pem_public_key(file_obj.read())

payload = {
    "ts": int(time.time()),
    "nonce": "Qx7nL2bP9mZc8dRs"
}

ciphertext = public_key.encrypt(
    json.dumps(payload, separators=(",", ":")).encode("utf-8"),
    padding.PKCS1v15(),
)

token = base64.b64encode(ciphertext).decode("ascii")
print(token)
```

## 7. 文件管理接口

以下接口都必须携带有效 `Courage-Token`。

### 7.1 查询文件列表

- 方法：`GET`
- 路径：`/api/files`

查询参数：

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `storage` | 否 | `temporary` 或 `permanent` |
| `keyword` | 否 | 按 `indexedName`、`systemName`、`path` 模糊匹配 |
| `mimeType` | 否 | 按 MIME 类型精确筛选 |
| `extension` | 否 | 按系统文件名后缀筛选，可带或不带 `.` |
| `folderId` | 否 | 文件夹 ID；传 `root` 表示仅查看未归档到任何文件夹的文件 |
| `page` | 否 | 页码，从 `1` 开始，默认 `1` |
| `pageSize` | 否 | 每页条数，默认 `50`，最大 `200` |

成功响应示例：

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "total": 2,
    "page": 1,
    "pageSize": 50,
    "returned": 2,
    "totalPages": 1,
    "filters": {
      "storage": null,
      "keyword": null,
      "mimeType": null,
      "extension": null,
      "folderId": "root"
    },
    "files": [
      {
        "indexedName": "封面图.png",
        "systemName": "cf8f75d3c20e4db78a7f41df0c7776a6.png",
        "storage": "temporary",
        "size": 12345,
        "mimeType": "image/png",
        "path": "/images/20260411/cf8f75d3c20e4db78a7f41df0c7776a6.png",
        "url": "/images/20260411/cf8f75d3c20e4db78a7f41df0c7776a6.png",
        "uploadedAt": "2026-04-11T10:00:00+08:00",
        "folderId": null
      },
      {
        "indexedName": "安装包.apk",
        "systemName": "1712923200_Qx7nL2bP9mZc8dRs.apk",
        "storage": "permanent",
        "size": 4096,
        "mimeType": "application/vnd.android.package-archive",
        "path": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk",
        "url": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk",
        "uploadedAt": "2026-04-11T10:01:00+08:00",
        "folderId": "9c9f4d7544bc45e1b6374fd8ad48b46d"
      }
    ]
  }
}
```

说明：

- 查询加密文件夹内容时，需要携带 `Folder-Password-Token`。
- `folderId=root` 只返回未归属任何虚拟文件夹的文件。

### 7.2 重命名索引文件名

- 方法：`PATCH`
- 路径：`/api/files`
- Content-Type：`application/json`

请求体：

```json
{
  "path": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk",
  "indexedName": "演示重命名.apk"
}
```

说明：

- 仅修改 `indexedName`
- 不会修改真实系统文件名

成功响应示例：

```json
{
  "code": 0,
  "message": "file renamed",
  "data": {
    "path": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk",
    "indexedName": "演示重命名.apk",
    "storage": "permanent"
  }
}
```

### 7.3 删除文件

支持单个删除和批量删除。

#### 单个删除

- 方法：`DELETE`
- 路径：`/api/files?path={文件相对路径}`

成功响应示例：

```json
{
  "code": 0,
  "message": "file deleted",
  "data": {
    "path": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk",
    "storage": "permanent",
    "indexedName": "安装包.apk"
  }
}
```

#### 批量删除

- 方法：`DELETE`
- 路径：`/api/files`
- Content-Type：`application/json`

请求体：

```json
{
  "paths": [
    "/images/20260411/file_a.png",
    "/images/permanent/file_b.apk"
  ]
}
```

成功响应示例：

```json
{
  "code": 0,
  "message": "batch delete completed",
  "data": {
    "requested": 2,
    "deletedCount": 2,
    "notFoundCount": 0,
    "deleted": [
      {
        "path": "/images/20260411/file_a.png",
        "storage": "temporary",
        "indexedName": "file_a.png"
      },
      {
        "path": "/images/permanent/file_b.apk",
        "storage": "permanent",
        "indexedName": "安装包.apk"
      }
    ],
    "notFound": []
  }
}
```

### 7.4 移动文件

- 方法：`POST`
- 路径：`/api/files/move`
- Content-Type：`application/json`

请求体：

```json
{
  "path": "/images/20260411/cf8f75d3c20e4db78a7f41df0c7776a6.png",
  "targetStorage": "permanent"
}
```

说明：

- `targetStorage` 只能为 `temporary` 或 `permanent`
- 移动后真实文件路径会变化
- `indexedName` 保持不变
- 移动时会同步更新索引记录
- 如果文件原先归属于虚拟文件夹，移动存储位置后 `folderId` 也会保留

成功响应示例：

```json
{
  "code": 0,
  "message": "file moved",
  "data": {
    "path": "/images/permanent/1712923200_0fd8aa18c69745e2.png",
    "sourceStorage": "temporary",
    "targetStorage": "permanent",
    "indexedName": "封面图.png",
    "mimeType": "image/png",
    "size": 12345
  }
}
```

### 7.5 文件夹接口

#### 查询文件夹树

- 方法：`GET`
- 路径：`/api/folders`

成功响应示例：

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "folders": [
      {
        "id": "9c9f4d7544bc45e1b6374fd8ad48b46d",
        "name": "项目资料",
        "parentId": null,
        "encrypted": true,
        "allowDirectDownload": false,
        "createdAt": "2026-04-11T10:05:00+08:00",
        "updatedAt": "2026-04-11T10:05:00+08:00",
        "path": "/项目资料",
        "depth": 1
      }
    ],
    "diskTotalBytes": 536870912000,
    "diskUsedBytes": 214748364800,
    "diskFreeBytes": 322122547200
  }
}
```

#### 创建文件夹

- 方法：`POST`
- 路径：`/api/folders`
- Content-Type：`application/json`

请求体：

```json
{
  "name": "项目资料",
  "parentId": null,
  "encrypted": true,
  "password": "folder-password",
  "allowDirectDownload": false
}
```

说明：

- `parentId` 可选，用于创建多级虚拟文件夹。
- `encrypted=true` 时必须同时提供 `password`。
- 如果目标父文件夹本身是加密的，需要额外携带 `Target-Folder-Password-Token`。

#### 修改文件夹

- 方法：`PATCH`
- 路径：`/api/folders`
- Content-Type：`application/json`

请求体示例：

```json
{
  "folderId": "9c9f4d7544bc45e1b6374fd8ad48b46d",
  "name": "项目资料-已归档",
  "parentId": null,
  "encrypted": true,
  "allowDirectDownload": false,
  "newPassword": "new-folder-password"
}
```

说明：

- 修改加密文件夹前，需要携带当前文件夹对应的 `Folder-Password-Token`。
- 如果同时把文件夹移动到另一个加密父目录下，还需要携带目标父目录的 `Target-Folder-Password-Token`。
- `newPassword` 只在加密文件夹下生效。
- 将 `encrypted` 改为 `false` 后，服务端会移除该文件夹保存的密码哈希，并自动允许直接下载。
- `parentId` 不传表示不修改父级；显式传 `null` 表示把文件夹移回根目录。

#### 删除文件夹

- 方法：`DELETE`
- 路径：`/api/folders?folderId={folderId}`

也支持 `application/json` 请求体：

```json
{
  "folderId": "9c9f4d7544bc45e1b6374fd8ad48b46d"
}
```

说明：

- 删除时会递归删除其所有子文件夹。
- 该树下已归档的真实文件也会一起删除。
- 删除加密文件夹前，需要携带对应的 `Folder-Password-Token`。

### 7.6 调整文件所属文件夹

- 方法：`POST`
- 路径：`/api/files/folder`
- Content-Type：`application/json`

请求体示例：

```json
{
  "paths": [
    "/images/permanent/a.apk",
    "/images/permanent/b.apk"
  ],
  "folderId": "9c9f4d7544bc45e1b6374fd8ad48b46d"
}
```

说明：

- 可使用 `path` 传单个文件，也可使用 `paths` 批量归档。
- `folderId` 传空或不传，表示把文件移回根目录。
- 如果目标文件夹是加密文件夹，需要携带 `Target-Folder-Password-Token`。

### 7.7 创建受保护下载链接

- 方法：`POST`
- 路径：`/api/folders/download-link`
- Content-Type：`application/json`

请求体：

```json
{
  "path": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk",
  "expiresInDays": 7
}
```

说明：

- 当文件所属文件夹为加密文件夹且 `allowDirectDownload=false` 时，该接口会生成一个带 `downloadToken` 查询参数的临时 URL。
- 请求该接口前，需要携带当前文件夹的 `Folder-Password-Token`。
- `expiresInDays` 必须大于 `0`，最终会被服务端限制在 `downloadTokenMaxDays` 以内。
- 如果文件所在文件夹允许直接下载，则会直接返回原始 URL，`passwordExempt=true`。

成功响应示例：

```json
{
  "code": 0,
  "message": "download link created",
  "data": {
    "path": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk",
    "url": "/images/permanent/1712923200_Qx7nL2bP9mZc8dRs.apk?downloadToken=...",
    "expiresAt": "2026-04-18T10:00:00+08:00",
    "expiresInDays": 7,
    "passwordExempt": false
  }
}
```

### 7.8 下载文件夹压缩包

- 方法：`POST`
- 路径：`/api/folders/archive`
- Content-Type：`application/json`

请求体：

```json
{
  "folderId": "9c9f4d7544bc45e1b6374fd8ad48b46d"
}
```

说明：

- 服务端会递归收集该文件夹及其全部子文件夹中的文件，并按目录结构生成 zip 压缩包。
- 压缩包内会保留根文件夹名称。
- 如果压缩范围内存在多个加密文件夹，需要通过 `Folder-Passwords-Token` 一次性提供所有相关密码证明。
- 返回值不是 JSON，而是 `application/zip` 文件流。

客户端配合说明：

- 客户端在发起该请求前，应先确认已设置固定下载目录，再开始接收 zip 文件流。
- 如果压缩范围包含多个加密文件夹，客户端应先汇总所有实际涉及到的加密文件夹密码，再统一生成 `Folder-Passwords-Token`。
- 下载过程中建议显示打包/下载进度条；如果用户取消下载，应保留已验证过的密码状态，但清理本地未完成的临时压缩包文件。

## 8. 文件访问接口

### 8.1 访问临时文件

```text
/images/{YYYYMMDD}/{fileName}
```

### 8.2 访问永久文件

```text
/images/permanent/{fileName}
```

### 8.3 行为说明

- 文件存在时：直接返回文件内容
- 服务端自动根据文件名推断 `Content-Type`
- 响应头会带：
  - `Content-Type`
  - `Content-Length`
  - `Content-Disposition`
  - `X-Content-Type-Options: nosniff`
- 图片、音频、视频类型会优先以 `inline` 方式返回
- 其他类型会以 `attachment` 方式返回
- 如果存在索引文件名，`Content-Disposition` 会优先使用索引文件名作为下载文件名；取不到时回退为系统文件名
- 当文件所属加密文件夹未开启直接下载豁免时，请在 URL 上追加 `downloadToken` 查询参数；否则会被拒绝

不存在时返回：

```json
{
  "code": 40401,
  "message": "file not found",
  "data": null
}
```

## 9. 审计日志

服务端会对以下成功操作写入审计日志：

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

日志默认写入 `logs/audit.log`，也可通过环境变量 `IMAGE_PROVIDER_AUDIT_LOG_FILE_PATH` 自定义路径。

日志格式为一行 JSON，例如：

```json
audit {"time": "2026-04-11T05:18:09.604297+08:00", "user": "tester_a", "appChannel": "release-preview", "actionType": "list_files", "indexedName": "", "filePath": "", "clientIp": "127.0.0.1", "resultCount": 1, "page": 1, "pageSize": 1}
```

说明：

- `APP_CHANNEL`、`USER` 不传时对应字段为空字符串
- 下载日志中的 `indexedName` 会优先读取索引名，取不到时回退为系统文件名
- 列表日志会额外记录 `resultCount`、`page`、`pageSize`
- 批量删除会为每个成功删除的文件分别记录一条日志，并附带 `batch: true`
- 通过“删除文件夹”级联删除的文件，会额外记录 `viaFolderDelete: true`
- 文件夹日志通常会附带 `resourceType: "folder"`、`folderId`、路径变更、父级变更或加密状态变更信息
- 续传上传日志会附带 `resumable: true`、分片大小或当前已上传字节数等额外字段

## 10. 自动清理机制

- 仅 `storage/temporary/` 参与每日自动清理
- 默认清理时间：每天早上 `06:00`
- `storage/permanent/` 不参与定时删除
- 如果服务在当日 6 点后启动且当日未执行过清理，会补做一次清理
- 每日清理时会同时：
  - 清空临时文件目录
  - 清空临时索引
  - 清空已使用 `nonce`

## 11. 错误码

### 11.1 通用错误码

| HTTP | 业务码 | 说明 |
| --- | --- | --- |
| `400` | `40000` | 请求不是 `multipart/form-data` |
| `400` | `40001` | 缺少 `Content-Length` |
| `400` | `40002` | 文件字段格式无效 |
| `400` | `40003` | 缺少 `file` 字段 |
| `400` | `40005` | `Content-Length` 非法 |
| `400` | `40006` | 不支持 `Transfer-Encoding` |
| `400` | `40007` | `multipart boundary` 非法 |
| `400` | `40008` | `multipart` 请求体格式错误 |
| `400` | `40009` | 存在未允许的表单字段 |
| `400` | `40010` | 一次请求仅允许一个 `file` 字段 |
| `400` | `40012` | 上传文件为空 |
| `400` | `40014` | 管理接口请求不是 `application/json` |
| `400` | `40015` | 管理接口 JSON 体过大 |
| `400` | `40016` | 管理接口 JSON 体非法 |
| `400` | `40017` | 缺少文件路径 |
| `400` | `40018` | 缺少索引文件名 |
| `400` | `40019` | 索引文件名非法 |
| `400` | `40020` | `storage` 过滤条件非法 |
| `400` | `40021` | `page` 非法 |
| `400` | `40022` | `pageSize` 非法 |
| `400` | `40023` | `targetStorage` 非法 |
| `400` | `40024` | 续传上传总大小非法 |
| `400` | `40026` | 续传上传 ID 非法 |
| `400` | `40027` | 缺少 `Upload-Token` |
| `400` | `40028` | 缺少或非法的 `Upload-Offset` |
| `400` | `40029` | 文件夹名称非法 |
| `400` | `40030` | 缺少文件夹密码 |
| `400` | `40031` | 缺少或非法的文件夹 ID |
| `400` | `40032` | 目标父文件夹非法 |
| `400` | `40033` | 文件夹当前不是加密状态 |
| `400` | `40034` | 下载链接有效天数非法 |
| `403` | `40301` | 请求 IP 在黑名单中 |
| `403` | `40302` | 文件夹密码错误 |
| `404` | `40400` | 资源不存在 |
| `404` | `40401` | 文件不存在或路径非法 |
| `404` | `40402` | 续传会话不存在或已过期 |
| `404` | `40403` | 文件夹不存在 |
| `405` | `40500` | 请求方法不被允许 |
| `409` | `40901` | 上传偏移不匹配 |
| `409` | `40902` | 续传上传尚未完成 |
| `413` | `41300` | 请求体过大 |
| `413` | `41301` | 文件大小超过限制 |
| `429` | `42900` | 上传请求过于频繁 |
| `500` | `50000` | 服务内部异常 |

### 11.2 Token 相关错误码

| HTTP | 业务码 | 说明 |
| --- | --- | --- |
| `401` | `40100` | Token 非法、格式错误或无法解密 |
| `401` | `40101` | Token 已过期 |
| `401` | `40102` | Token 命中重放保护 |
| `401` | `40103` | 管理接口缺少鉴权 Token |
| `401` | `40104` | `Upload-Token` 无效 |
| `401` | `40105` | 文件夹密码令牌非法 |
| `401` | `40106` | 下载令牌无效或已过期 |
| `500` | `50001` | 服务端永久 Token 验签能力不可用 |

## 12. 调用示例

### 12.1 临时上传示例

```bash
curl -X POST "http://127.0.0.1:8080/api/upload" \
  -F "file=@./demo.bin"
```

### 12.2 永久上传示例

```bash
curl -X POST "http://127.0.0.1:8080/api/upload" \
  -H "Courage-Token: 这里填写 RSA 加密后的 Base64 字符串" \
  -H "APP_CHANNEL: release" \
  -H "USER: alice" \
  -F "file=@./package.apk"
```

### 12.3 查询文件列表示例

```bash
curl "http://127.0.0.1:8080/api/files?page=1&pageSize=20&storage=permanent" \
  -H "Courage-Token: 这里填写 RSA 加密后的 Base64 字符串" \
  -H "APP_CHANNEL: release" \
  -H "USER: alice"
```

### 12.4 重命名示例

```bash
curl -X PATCH "http://127.0.0.1:8080/api/files" \
  -H "Content-Type: application/json" \
  -H "Courage-Token: 这里填写 RSA 加密后的 Base64 字符串" \
  -d '{"path":"/images/permanent/demo.apk","indexedName":"新名字.apk"}'
```

### 12.5 单文件删除示例

```bash
curl -X DELETE "http://127.0.0.1:8080/api/files?path=/images/permanent/demo.apk" \
  -H "Courage-Token: 这里填写 RSA 加密后的 Base64 字符串"
```

### 12.6 批量删除示例

```bash
curl -X DELETE "http://127.0.0.1:8080/api/files" \
  -H "Content-Type: application/json" \
  -H "Courage-Token: 这里填写 RSA 加密后的 Base64 字符串" \
  -d '{"paths":["/images/a.bin","/images/permanent/b.apk"]}'
```

### 12.7 移动文件示例

```bash
curl -X POST "http://127.0.0.1:8080/api/files/move" \
  -H "Content-Type: application/json" \
  -H "Courage-Token: 这里填写 RSA 加密后的 Base64 字符串" \
  -d '{"path":"/images/20260411/demo.png","targetStorage":"permanent"}'
```
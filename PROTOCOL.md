# ColorLink 通信协议 v1

手机是服务端，Mac 是客户端。数据全部走局域网 HTTP，蓝牙只用来让手机知道“Mac 在旁边”。

## 发现

| 方式 | 内容 |
|---|---|
| mDNS（Bonjour） | 服务类型 `_colorlink._tcp`，TXT：`id=<设备 ID>`、`name=<机型>` |
| 兜底 | Mac 记住上一次成功连接的 `IP:端口`，找不到 mDNS 时直接连 |
| 蓝牙唤醒 | Mac 持续广播服务 UUID `7A1C3F0E-5B2D-4E8A-9C61-3D4F2B8E9A10`，手机让系统代为扫描，扫到就唤醒 App |

| 敲门 | 手机醒来、换网络、蓝牙再次发现 Mac 时，发 UDP 包到 Mac 的 `8766` 端口（见下） |

默认端口 `8765`，被占用时随机端口，以 mDNS 广播的为准。

### 敲门（手机 → Mac，UDP 8766）

ColorOS 锁屏后，Wi-Fi 芯片会过滤组播包，手机收不到 Mac 发来的 mDNS 查询。所以由手机主动通知 Mac。

```json
{"v":1,"id":"<设备 ID>","port":8765,"ts":1729500000,"sig":"<hex>"}
```

- `sig = HMAC-SHA256(key = 配对令牌, msg = "id|port|ts")`，用小写十六进制表示
- 发送目标：上次连过来的 Mac 的 IP（单播），以及手机**所有局域网网卡**的广播地址（Wi‑Fi 和热点）
- 发送时机：服务启动、换网络、开关热点、蓝牙再次发现 Mac 时；立即、3 秒、10 秒各发一次；已有 Mac 连着就不发（换网络后的第一下除外）；30 秒内最多发一轮
- Mac 显示“已连接”时却收到敲门，说明那条连接其实已断（手机突然断网时 TCP 收不到关闭通知），立即断开重连
- Mac 只接受签名正确、时间差在 5 分钟以内的包；连接地址取 UDP 包的**来源 IP**，不信任包里的内容

## 认证

- 首次配对：`GET /api/pair?code=<手机上显示的 6 位码>&client=<电脑名>`
  - 成功 `200 {"token","deviceId","name"}`，手机随即更换配对码
  - 失败 `403`；连续错 5 次手机会换码
- 之后每个请求带 `Authorization: Bearer <token>`，或者查询参数 `?t=<token>`（给播放器这类没法加请求头的场景用）
- 没带或带错返回 `401`
- 唯一不需要令牌的是 `GET /api/id` → `{"deviceId","name"}`。Mac 去“上次的地址”或网关找手机时，先用它核对设备 ID，对上了才发令牌，避免把令牌发给同一 IP 上的别的设备

## 接口

| 接口 | 说明 |
|---|---|
| `GET /api/logs` | 手机端日志文件（纯文本），导出诊断日志用 |
| `GET /api/info` | `{"deviceId","name","model","android","battery","charging"}` |
| `GET /api/media?kind=image\|video\|audio&offset=0&limit=200` | 按加入时间倒序分页：`{"total","items":[MediaItem]}` |
| `GET /api/thumb?kind=&id=&v=<modified>&size=256` | JPEG 缩略图。手机端提前生成并缓存在磁盘上，`v` 变了就重新生成 |
| `GET /api/file?kind=&id=` | 原文件，支持 `Range`（视频可以边下边播、随意拖动） |
| `GET /api/events?name=<电脑名>` | Server-Sent Events 长连接，见下。`name` 显示在手机的流体云里 |
| `POST /api/upload?name=<文件名>&mime=<类型>&batch=<批次>&index=<序号>&count=<总数>` | Mac 发文件到手机，请求体是文件内容（需带 `Content-Length`）。图片存进 `Pictures/ColorLink`，视频 `Movies/ColorLink`，音频 `Music/ColorLink`，其他 `Download/ColorLink`。一次拖过来的多个文件共用一个 `batch`，`index` 从 0 数起，手机收完最后一个才提示「已收到 N 个文件」（不带这三个参数当作单个文件）；返回保存后的 `MediaItem` |
| `GET /api/shared?id=<id>` | 取分享菜单发来的文件（见 `shared` 事件） |
| `POST /api/trash` | 请求体 `{"items":[{"kind":"image","id":123}]}`，移到手机的「最近删除」。返回 `{"trashed":已移走数量,"pending":是否要在手机上点通知确认}`（手机给了「媒体管理」权限就不用确认） |

`MediaItem`：

```json
{"id":123,"kind":"image","name":"IMG_001.jpg","mime":"image/jpeg","size":2345678,
 "modified":1729500000,"added":1729500000,"width":4000,"height":3000,"duration":null,"path":"DCIM/Camera/"}
```

## 事件流（SSE）

每个事件一行 `event:` 加一行 `data:`（单行 JSON）。手机每 20 秒发一个 `: ping` 注释行保活；但手机深睡时这个计时不走，ping 会停很久。Mac 超过 3 分钟没收到任何数据时请求一次 `/api/info`，手机收到后立刻往所有事件流写一行 `: ping`；请求失败、或之后 30 秒内流里仍没有数据，Mac 才断开重连。

| 事件 | data |
|---|---|
| `hello` | 同 `/api/info` |
| `screenshot` | `MediaItem`。手机刚截了一张图，Mac 下载后放进剪贴板 |
| `media` | `MediaItem`。手机多了一张普通照片（拍照、保存、Mac 发来的图），Mac 刷新「最近照片」 |
| `notification` | `{"key","pkg","app","title","text","time"}`。只转发短信 App 的通知（默认短信 App 加常见短信包名），同一条 2 分钟内去重；验证码由 Mac 端识别 |
| `clipboard` | `{"text"}`，在手机上用分享菜单「发送到 Mac」时发出 |
| `shared` | `{"items":[{"id","name","mime","size"}]}`，在手机上用分享菜单把图片 / 文件「发送到 Mac」时发出；Mac 用 `GET /api/shared?id=` 取文件（手机保留一小时） |

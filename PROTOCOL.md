# ColorLink 通信协议 v1

手机是服务端，Mac 是客户端。数据全部走局域网 HTTPS（见「加密」），蓝牙只用来让手机知道“Mac 在旁边”。

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
- 之后每个请求带 `Authorization: Bearer <token>`
- 没带或带错返回 `401`
- 唯一不需要令牌的是 `GET /api/id` → `{"deviceId","name"}`。Mac 去“上次的地址”或网关找手机时，先用它核对设备 ID，对上了才发令牌，避免把令牌发给同一 IP 上的别的设备

## 加密

- 手机只提供 HTTPS（TLS 1.2 / 1.3），不再接受明文 HTTP
- 证书是手机自己签的：Android 密钥库里的 EC P-256 密钥，私钥不能导出。重装 App 后会换新的
- Mac 不校验证书链和主机名，只比对证书（DER）的 SHA-256 指纹：
  - 配对时接受任何证书，把这次握手看到的指纹和令牌一起存下（首次信任）
  - 之后只接受这一张；对不上就在握手阶段断开，令牌不会发出去，Mac 提示重新配对
  - 升级前配的对没有指纹，第一次用 HTTPS 连上时补记
- `/api/id` 也走固定的证书核对
- AVPlayer 没法自定义证书校验，Mac 在 `127.0.0.1` 随机端口开一个转发：每个视频一个随机路径，Range 原样转给手机。只监听本机回环地址
- 敲门包本身不加密，只带 HMAC 签名，内容只有设备 ID、端口和时间

## 接口

| 接口 | 说明 |
|---|---|
| `GET /api/logs` | 手机端日志文件（纯文本），导出诊断日志用 |
| `GET /api/info` | `{"deviceId","name","model","android","battery","charging","dnd"}`（`dnd` 为 null 表示没开通知使用权） |
| `GET /api/media?kind=image\|video\|audio&offset=0&limit=200` | 按加入时间倒序分页：`{"total","items":[MediaItem]}` |
| `GET /api/thumb?kind=&id=&v=<modified>&size=256` | JPEG 缩略图。手机端提前生成并缓存在磁盘上，`v` 变了就重新生成 |
| `GET /api/file?kind=&id=` | 原文件，支持 `Range`（视频可以边下边播、随意拖动） |
| `GET /api/events?name=<电脑名>` | Server-Sent Events 长连接，见下。可以好几台电脑同时连：手机按 `name` 区分电脑（同名的连接算一台），显示在首页、流体云和通知里；收文件、删照片时按来源 IP 认出是哪台。每台电脑要用不同的名字 |
| `POST /api/upload?name=<文件名>&mime=<类型>&batch=<批次>&index=<序号>&count=<总数>` | Mac 发文件到手机，请求体是文件内容（需带 `Content-Length`）。图片存进 `Pictures/ColorLink`，视频 `Movies/ColorLink`，音频 `Music/ColorLink`，其他 `Download/ColorLink`。一次拖过来的多个文件共用一个 `batch`，`index` 从 0 数起，手机收完最后一个才提示「已收到 N 个文件」（不带这三个参数当作单个文件）；返回保存后的 `MediaItem` |
| `GET /api/shared?id=<id>` | 取分享菜单发来的文件（见 `shared` 事件） |
| `GET /api/dnd` | 当前免打扰档位 `{"mode"}`；手机没开通知使用权时 `503` |
| `POST /api/dnd?mode=all\|priority\|alarms\|none` | 改免打扰档位：开关手机上一条名为 ColorLink 的勿扰规则（只关得掉这条，手机上手动开的勿扰关不掉）。最多等 2 秒，返回实际档位 `{"mode"}`，可能和请求的不同。通知监听服务自带这个权限，不用另外申请「勿扰权限」 |
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
| `notification` | `{"key","pkg","app","sms","title","text","time"}`。转发手机上会响的通知（静默通道、常驻、分组摘要不发），微信和系统通知除外；同一条 2 分钟内去重。`sms` 标记来自短信 App（默认短信 App 加常见短信包名），Mac 只在短信里识别验证码 |
| `dnd` | `{"mode":"all"\|"priority"\|"alarms"\|"none"}`，免打扰档位变了（手机上手动改的，或 Mac 改完系统回调）。四档对应安卓的中断过滤：全部 / 仅优先 / 仅闹钟 / 完全静音 |
| `clipboard` | `{"text"}`，在手机上用分享菜单「发送到电脑」时发出 |
| `shared` | `{"items":[{"id","name","mime","size"}]}`，在手机上用分享菜单把图片 / 文件「发送到电脑」时发出；电脑用 `GET /api/shared?id=` 取文件（手机保留一小时）。连着好几台电脑时，手机会先问发给哪台，`clipboard` 和 `shared` 只发给选中的那台（也可以选全部） |
| `power` | `{"charging":true,"battery":85}`，插上 / 拔掉电源时发出。Mac 只在手机充电时在后台补缩略图，靠它开始和停下，不定时请求 `/api/info` |

## 省电约定

- 手机只在**传输类**请求（`/api/media`、`/api/thumb`、`/api/file`、`/api/upload`、`/api/shared`）期间持有 Wi-Fi 锁和唤醒锁，响应写完 3 秒后释放；`/api/info`、`/api/id`、`/api/events` 不持锁
- Mac 不定时询问手机：电量、充电状态靠 `hello` 和 `power` 事件；只有打开状态栏面板时问一次 `/api/info`，以及事件流安静超过 3 分钟时的探活
- Mac 锁屏或睡眠时主动关闭事件流并停掉蓝牙广播，解锁 / 醒来后再连。手机在事件流上盯着对端关闭，关闭即断开，不等下一次 ping

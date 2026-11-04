# Live Map（Map-Reloc -Serve）——交互规格与踩坑实录

`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Map-Reloc.ps1 -Serve -Root C:\ -Port 8734 -Rules <rules.json>`
启动本地服务并自动打开浏览器（Ctrl+C 停止）。静态导出用 `-Out map.html`。

## 交互规格

- **流式渲染**：SSE 推送（`/events?paths=…`，版本号门控 + 800ms 节流 + 冗余子路径去重）；
  worker 增量 flush 16MB/400 项/250ms 触发版本 +1；断流自动降级回 600ms 轮询。
  方块随扫描实时生长（增量 flush 使其连续长大而非跳变）。
- **单击 = 原地展开/收起**：顶部 16px 标签条保留不被遮挡，子项 treemap 拼凑渲染、
  兄弟块保持可见便于对比。两道防细条：面积 <180px² 不单独成块；布局后形状检测
  （最小边 <5px 或长宽比 >7）并入底部灰色"剩余N项（极小/未扫完）"聚合条
  （高度按占比 18px~40%，随进度自动增减）——实测最大长宽比 ≤3.1、最小边 ≥8px。
- **双击 = 进入**（整屏切到该目录）；`⬅ 返回` / Backspace 返回；Esc 收起全部展开；面包屑跳转。
- **排序迟滞**：超相邻块 12% 才交换位置，方块平滑生长不来回跳。
- **右键菜单**（客户端风格）：📂 资源管理器打开（文件定位所在文件夹并选中，走本地 `/open`
  端点仅 127.0.0.1 可达）/ 📋 复制完整路径 / ↯ 进入此目录 / ⊞ 展开/收起；
  点外部（mousedown 捕获）或 Esc 关闭。
- **语义配色**：目录多彩、文件统一灰、聚合块深灰；counting 块流动斜纹 + 琥珀色标签。
- 多层展开时每层标签条深色底 + 金色下划线 + 每层 12px 递进缩进。
- 小方块展开后放不下子块属正常（面积比例限制），用双击进入看。

## 已知限制

- 客户端展开/进入会为该子树创建独立重扫任务，与根 DFS 并行抢 IO，两个都会变慢——架构特性非故障。
- 静态导出（`-Out`）无交互菜单/流式，仅布局 + 悬停。

## 踩坑实录（改 viewer / 排障必读）

- **ZCode 沙箱**：后台任务（run_in_background）对 C:\ 等盘的目录枚举返回空（不报错），
  永远扫不出数据。必须 `Start-Process powershell -ArgumentList ... -WindowStyle Hidden`
  脱离沙箱启动，或在用户自己的终端里运行。
- **多实例撞端口**：后台日志无限刷 `[serve] request error: Not listening`。
  `Get-NetTCPConnection -LocalPort 8734 -State Listen` 拿 OwningProcess，比对
  `Get-CimInstance Win32_Process` 的 CommandLine 找出多余实例杀掉。脚本已在端口被占时
  明确报错退出。
- **浏览器代理截 localhost**（国内代理用户高频事故）：页面请求被代理吞掉 → 永远转圈。
  viewer 内置 4s 超时 + 失败横幅提示把 127.0.0.1/localhost 加入直连列表。验证服务本身用
  `curl --noproxy '*' http://127.0.0.1:<port>/debug`。
- **HTML 模板占位符必须带引号**：`var ROOT='__ROOT__'` 不能写成裸值——替换后
  `var ROOT=C:\` → 整段脚本语法错误 → 页面黑屏零提示，极易误判成网络/代理问题。
- **treemap 布局前必须归一化**：拿原始字节数当像素算，一个大目录会算出千万像素格吃掉画布。
  `k=W*H/总字节`，每项 `s×k` 后再进 squarify，标签/提示仍用原始字节。
- **服务端验证 ≠ 页面验证**：改 viewer JS 后必须用真实浏览器打开看一眼（或
  `new Function(script文本)` 验语法），curl 只能证明服务端活着。
- **viewer 交互一律 `addEventListener`，禁用处理器属性**（`el.onclick=` 等）：
  ①agent 内置浏览器会在主世界剥离交互类处理器属性（防注入）——表现为点击/右键/按键全哑
  但脚本源码完整、零报错；监听器不受影响。
  ②循环里 `var d` + 闭包读循环变量是经典陷阱（点 A 进 B）；listener 内用
  `ev.currentTarget.__n` 取当前元素数据，同时保证每次 render 刷新的是活数据。
- **相关项目**：DiskLens（github.com/AriesYB/disklens）是本 live map 的产品化独立客户端
  （Rust 扫描核心 + Tauri v2 四端），无 PowerShell 依赖；本 live map 保持零依赖随 skill 分发。

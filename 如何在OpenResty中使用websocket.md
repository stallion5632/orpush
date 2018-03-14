
http://hambut.com/2016/10/13/how-to-use-websocket-in-openresty/


# 如何在 OpenResty 中使用 websocket

###前言 

作为一个游戏从业者不可能不使用推方案，以前一直使用 [nginx-push-stream-module](https://github.com/wandenberg/nginx-push-stream-module) 这个模块的 `Forever Iframe` 模式来实现推方案。

最近决定研究下 [lua-resty-websocket](https://github.com/openresty/lua-resty-websocket) 来实现一个更加高效好用推方案

###不推荐使用的场景

由于 `OpenResty` 目前还不能做到跨 `worker` 通信，所以想到实现指定推送需要中转一次，效率上可能不如其他语言如 `golang` 等

*   过于复杂的业务逻辑
*   频繁的指定推送（单对单、组、Tag等）
*   广播过多
<a id="more"></a>

###一起工作的好基友们 

想要推的优雅以下几个基友的帮忙是不可或缺的

####ngx-semaphore
(https://github.com/openresty/lua-resty-core/blob/master/lib/ngx/semaphore.md)

它可以让你在想要发消息的地方优雅的进入到发送阶段，也可以让你来优雅的控制一个链接超时的关闭。

####ngx-shared
[ngx.shared](https://github.com/openresty/lua-nginx-module#ngxshareddict)

由于目前我们无法做到跨 `worker` 的通信，所以必须借助共享内存来中转不属于当前 `worker` 的消息。

####lua-resty-websocket
[lua-resty-websocket](https://github.com/openresty/lua-resty-websocket)

由于贪图方便还是直接使用了现成的库，喜欢折腾的小伙伴请移步
[stream-lua-nginx-module](https://github.com/openresty/stream-lua-nginx-module)

###大概的思路

由于不能跨 `worker` 通信所以我给每个 `worker` 申请了一个 `shared` 共享内存来保存消息。
理论上 `shared` 的数量等于 `worker` 的数量最佳。

然后每个 `worker` 启动一个 `timer` 来判断当前 `worker` 的 `message id` 和 `shared` 中的 `message id` 是否有变化。
这里为什么不用 `shared` 的有序列表来做，容我先卖个关子。

当发生变化时，判断消息的目标是否在自己的 `session hash` 中，如果在则发之。

###开始准备工作

####修改配置文件

首先修改 `nginx.conf` 配置，增加以下设置 

```lua
lua_shared_dict message_1 10m;
lua_shared_dict message_2 10m;
lua_shared_dict message_n 10m;

init_worker_by_lua_file scripts/init_worker_by_lua.lua;
```

####init-worker-by-lua
```
local ngx = ngx
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_timer_at = ngx.timer.at
local require = require

local socketMgr = require("socketMgr")

local delay = 1
local loopMessage

loopMessage = function(premature)
    if premature then
        ngx_log(ngx_ERR, "timer was shut: ", err)
        return
    end

    socketMgr:loopMessages()

    local ok, err = ngx_timer_at(delay, loopMessage)

    if not ok then
        ngx_log(ngx_ERR, "failed to create the timer: ", err)
        return
    end
end

loopMessage()
```

####loopMessages 

判断 `local message id` 和 `shared message id`是否不等。
随后每次 `local message id` + 1 从 `shared` 拉取数据，进行消息推送逻辑。

###建立连接 

不做过多说明，自行查看 [lua-resty-websocket](https://github.com/openresty/lua-resty-websocket) 的 `wiki`

当连接监听好之后，要进行一系列的管理。如：

*   `session id` 和 `user id` 的双向映射
*   `session id` 和 `group name` 的双向映射

后面再详细说明

###生成-session-id
生成 `session id`

我是用 (`worker id` + 1) * 100000 + `worker's local incr id` 来生成唯一 `session id` 比较简陋，但是够用。

这么做的原因是，通过对 `session id` 进行取余可以很方便的得知 `worker id`，可以方便的给 `shared` 写消息。

```
local ngx_worker_id = ngx.worker.id()
local _incr_id = 0

local _gen_session_id = function()
	_incr_id = _incr_id + 1
	return (ngx_worker_id + 1) * 100000 + _incr_id
end
```

###设置消息映射

这个可以用于收到当前 `worker` 所属的 `shared message` 判断是否在当前进程。

```
_messages[session_id] = {}
_semaphores[session_id] = semaphore.new(0)
```

###接收消息&发送消息
接收消息&;发送消息

代码和 [官方例子](https://github.com/openresty/lua-resty-websocket#synopsis) 类同不做过多说明，只说我改了什么。

在接收消息中管理了一个变量即 `close_flag` 用于管理 `send message` 轻线程的退出。

以下是一段伪代码，含义的话请联系上下文。

```
local session_id = sessionMgr:gen_session_id()
local send_semaphore = sessionMgr:get_semaphore(session_id)
local close_flag = false

local function _push_thread_function()
    while close_flag == false do
        local ok, err = send_semaphore:wait(300)

        if ok then
            local messages = socketMgr:getMessages(session_id)

            while messages and #messages > 0 do
                local message = messages[1]
                table_remove(messages, 1)
                --- your send message function handler
            end
        end

        if close_flag then
            socketMgr:destory(session_id)
            break
        end
    end
end

local push_thread = ngx_thread_spawn(_push_thread_function)

while true do
    local data, typ, err = wbsocket:recv_frame()

    while err == "again" do
        local cut_data
        cut_data, _, err = wbsocket:recv_frame()
        data = data .. cut_data
    end

    if not data then
        close_flag = true
        send_semaphore:post(1)
        break
    elseif typ == 'close' then
        close_flag = true
        send_semaphore:post(1)
        break
    elseif typ == 'ping' then
        local bytes, err = wbsocket:send_pong(data)
        if not bytes then
            close_flag = true
            send_semaphore:post(1)
            break
        end
    elseif typ == 'pong' then
    elseif typ == 'text' then
	-- your receive function handler
    elseif typ == 'continuation' then
    elseif typ == 'binary' then
    end
end

ngx_thread_wait(push_thread)
wbsocket:send_close()
```
###消息推送

现在说说为什么不用 `shared` 的有序列表来存储消息，我是使用了 `shared` 的 `set` 方法中的 `flag` 属性来存放 `session id`。
这样在获得一个消息的时候，能很方便的知道消息是发给哪个 `session id`的。

继续一段伪代码。

```
local ngx_shared = ngx.shared

local _shared_dicts = {
	ngx_shared.message_1,
	ngx_shared.message_2,
	ngx_shared.message_n,
}

local current_shared = _shared_dicts[ngx_worker_id + 1]
local current_message_id = 1

--- 如果在当前进程
if _messages[session_id] then
	table.insert(_messages[session_id], "message data")
	_semaphores[session_id]:post(1)

	--- 会进入到，上述 _push_thread_function 方法中，进行发送逻辑
else
	local shared_id = session_id % 100000
	local message_shared = _shared_dicts[shared_id]
	local message_id = message_shared:incr("id", 1, 0)
	message_shared:set("message." .. message_id, "message data", 60, session_id)
end
```

###其他 

[https://github.com/chenxiaofa/p](https://github.com/chenxiaofa/p)

借鉴了这位同学的设计思路，实现了额外逻辑。如：

*   加入、退出、销毁组
*   各 `worker` 之间的 `cmd` 内部命令执行
*   热更新的特殊处理等

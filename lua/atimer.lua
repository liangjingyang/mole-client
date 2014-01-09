
require "alarm"

local atimer = {}

atimer.list = {}
atimer.count = 1
atimer.isRunning = nil

function atimer:start(callback, interval, runCount, data)
    local item = {interval = interval, lastTick = 0}
    item.id = atimer.count
    atimer.count = atimer.count + 1
    item.onTick = function()
        item.lastTick = item.lastTick + 1
        if item.lastTick == item.interval then
            callback(data, item.id)
            item.lastTick = 0
            if runCount ~= nil then
                runCount = runCount - 1;
                if runCount <= 0 then -- 达到指定运行次数,杀掉
                    self:kill(item.id)
                end
            end
        end
    end
    atimer.list[tostring(item.id)] = item
end

function atimer:kill(id)
    atimer.list[tostring(id)] = nil
end

local function atimerCallBack()
    for k, v in pairs(atimer.list) do
        v.onTick()
    end
    alarm(1)
end

if not atimer.isRunning then
    alarm(1, atimerCallBack)
    print("timer start")
    atimer.isRuning = true
end

--atimer:start(function() print(os.time()) end, 2, 10)

return atimer

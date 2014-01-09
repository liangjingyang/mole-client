-- author simple.continue@gmail.xom


local mole = {}

local timer = require "atimer"
local socket = require("socket")

local SERVER_REQ = '1'
local SERVER_RES = '2'
local WAN_CONN = '3'
local LAN_CONN = '4'
local BCAST_CONN = '5'
local HEART_BEAT = '6'


local function get_local_192()
    local cmd = "echo `ifconfig |grep \"inet addr:\" | awk -F:  '{print $2}'|awk '{print $1}'|grep '^192\\.168'` > localip"
    os.execute(cmd)
    local file = io.open("localip", "r")
    local c = file:read()
    file:close()
    if string.len(c) > 6 then
        return c 
    end
    return nil
end

local function get_local_172()
    local cmd = "echo `ifconfig |grep \"inet addr:\" | awk -F:  '{print $2}'|awk '{print $1}'|grep '^172\\.16'` > localip"
    os.execute(cmd)
    local file = io.open("localip", "r")
    local c = file:read()
    file:close()
    if string.len(c) > 6 then
        return c 
    end
    return nil
end

local function get_local_10()
    local cmd = "echo `ifconfig |grep \"inet addr:\" | awk -F:  '{print $2}'|awk '{print $1}'|grep '^10\\.'` > localip"
    os.execute(cmd)
    local file = io.open("localip", "r")
    local c = file:read()
    file:close()
    if string.len(c) > 6 then
        return c 
    end
    return nil
end

local function get_lan_ip()
    local ip = {}
    table.insert(ip, get_local_10())
    table.insert(ip, get_local_172())
    table.insert(ip, get_local_192())
    return ip
end

local function lan_to_str(t)
    local str = ""
    for i = 1, #t.ips do
        str = str .. t.ips[i] .. 'i'
    end
    str = string.sub(str, 1, string.len(str) - 1) .. "p" .. t.port
    return str
end

local function str_to_lan(str)
    local ips = {}
    for k in string.gmatch(str, "(%d+.%d+.%d+.%d+)") do
        table.insert(ip, 1, k)
    end
    local port = string.match(str, "p(%d+)")
    return {ips = ips, port = port}
end


local function key_to_128(key)
    local size = string.len(key)
    if size > 16 then
        key = string.sub(key, 1, 16)
    elseif size < 16 then
        for i = 1, (16 - size) do
            key = key .. "$"
        end
    end
    return key
end

local function handler(self, func)
    return function() func(self) end
end

function mole:new(my_key, his_key, port, s_ip, s_port)
    local my_lan = {}
    my_lan.port = port or 6666
    my_lan.ip = get_lan_ip()
    my_key = key_to_128(my_key)
    his_key = key_to_128(his_key)
    local lan_str = lan_to_str({ips = my_lan.ip, port = my_lan.port})
    my_packet = SERVER_REQ .. my_key .. his_key .. lan_str 
    print("mole new: sip:" .. s_ip .. "sport:" .. s_port .. "lan:" .. lan_str, "port:" .. port)
    local o = {
        my_key = my_key,
        his_key = his_key,
        s_ip = s_ip or "127.0.0.1",
        s_port = s_port or 6666,
        my_port = port or 6666,
        my_lan = my_lan,
        my_packet = my_packet,
        his_net = nil,
        conn = nil,
        conn_type = nil,
    }
    self.__index = self
    setmetatable(o, self)
    return o
end

function mole:start()
    local udp = assert(socket.udp())
    assert(udp:setsockname("0.0.0.0", self.s_port))
    assert(udp:settimeout(0))

    self.socket = udp

    timer:start(handler(self, self.serverReq), 3) 
    timer:start(handler(self, self.bcastConn), 1)
    while true do
        self:recv()
    end
end

function mole:serverReq(data, timerId)
    print("send server request")
    if self.his_net or self.conn_type then
        timer:kill(timerId)
        return
    end
    self.socket:sendto(self.my_packet, self.s_ip, self.s_port)
end

function mole:bcastConn(data, timerId)
    print("send bcast conn")
    if self.conn_type then
        timer:kill(timerId)
        return
    end
    datagram = BCAST_CONN .. self.my_key .. self.his_key
    self.socket:sendto(datagram, "255.255.255.255", self.my_port)
end

function mole:recv()
    local datagram, ip, port = self.socket:receivefrom()
    if datagram then
        print("datagram:", datagram)
        self:router(datagram, ip, port)
    end
end

function mole:router(datagram, ip, port)
    local proto = string.sub(datagram, 1, 1)
    if proto == SERVER_RES then
        self:recvServerRes(datagram, ip, port)
    elseif proto == BCAST_CONN then
        self:recvBcastConn(datagram, ip, port)
    elseif proto == LAN_CONN then
        self:recvLanConn(datagram, ip, port)
    elseif proto == WAN_CONN then
        self:recvWanConn(datagram, ip, port)
    elseif proto == HEART_BEAT then
        print("heart beat")
    else
        print("proto error:", datagram)
    end
end

function mole:recvWanConn(datagram, ip, port)
    if not self.conn_type then
        print("recv wan conn", ip, port)
        self.conn = {ip = ip, port = port}
        self.conn_type = WAN_CONN
        self.socket:sendto(WAN_CONN, ip, port)
        timer:start(handler(self, self.heartBeat), 5)
    end
end

function mole:recvLanConn(datagram, ip, port)
    if not self.conn_type then
        print("recv lan conn", ip, port)
        self.conn = {ip = ip, port = port}
        self.conn_type = LAN_CONN
        self.socket:sendto(LAN_CONN, ip, port)
        timer:start(handler(self, self.heartBeat), 5)
    elseif self.conn_type == WAN_CONN then
        print("recv lan conn", ip, port)
        self.conn = {ip = ip, port = port}
        self.conn_type = LAN_CONN
        self.socket:sendto(LAN_CONN, ip, port)
    end
end

function mole:recvBcastConn(datagram, ip, port)
    local hisKey = string.sub(datagram, 2, 17)
    local myKey = string.sub(datagram, 18, 33)
    if myKey == self.my_key and hisKey == self.his_key then
        if not self.conn_type then
            print("recv bcast conn", ip, port)
            self.conn = {ip = ip, port = port}
            self.conn_type = BCAST_CONN
            datagram = BCAST_CONN .. self.my_key .. self.his_key
            self.socket:sendto(datagram, ip, port)
            timer:start(handler(self, self.heartBeat), 5)
        elseif self.conn_type == WAN_CONN then
            print("recv bcast conn", ip, port)
            self.conn = {ip = ip, port = port}
            self.conn_type = BCAST_CONN
            datagram = BCAST_CONN .. self.my_key .. self.his_key
            self.socket:sendto(datagram, ip, port)
        end
    end
end

function mole:recvServerRes(datagram, ip, port)
    print("recv server response", ip, port)
    self.his_key = string.sub(datagram, 2, 17)
    local ipstr = string.sub(datagram, 18, 32)
    local portstr = string.sub(datagram, 33, 37)
    local lanstr = string.sub(datagram, 38, string.len(datagram))

    local wanip = ""
    for i = 0, 3 do
        wanip = wanip .. tonumber(string.sub(ipstr, i*4 + 1, i*4 + 3)) .. "."
    end
    wanip = string.sub(wanip, 1, string.len(wanip) - 1)
    local wanport = tonumber(portstr) 
    local lantab = str_to_lan(lanstr)

    local p2pargs = {wanip = wanip, wanport = wanport, lantab = lantab}
    self:p2pConn(p2pargs)
    timer:start(handler(self, self.p2pConn), 3, nil, p2pargs) 
end

function mole:p2pConn(args, timerId)
    if self.conn_type then
        timer:kill(timerId)
        return
    end
    self.socket:sendto(WAN_CONN, args.wanip, args.wanport)
    local ips = args.lantab.ips
    local port = args.lantab.port
    for i = 1, #ips do
        self.socket:sendto(LAN_CONN, ips[i], port)
    end
end

function mole:heartBeat(data, timerId)
    if self.conn then
        self.socket:sendto(HEART_BEAT, self.conn.ip, self.conn.port)
    else 
        timer:kill(timerId)
    end
end

mole.get_lan_ip = get_lan_ip
mole.get_local_10 = get_local_10
mole.get_local_172 = get_local_172
mole.get_local_192 = get_local_192
return mole

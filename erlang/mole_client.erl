-module(mole_client).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([start/5,
        get_lan_ip/0
    ]).

-behaviour(gen_server).

-record(state, {socket, s_ip, s_port, conn, conn_type, my_lan, my_port, my_packet, my_key, his_key, his_net}).

-define(SERVER_REQ, <<"1">>).
-define(SERVER_RES, <<"2">>).
-define(WAN_CONN, <<"3">>).
-define(LAN_CONN, <<"4">>).
-define(BCAST_CONN, <<"5">>).
-define(HEART_BEAT, <<"6">>).

start(MyKey, HisKey, Port, ServerIp, ServerPort) ->
    gen_server:start({local, ?MODULE}, ?MODULE, [MyKey, HisKey, Port, ServerIp, ServerPort], []).

init([MyKey, HisKey, Port, ServerIp, ServerPort]) ->
    {ok, Socket} = gen_udp:open(Port, [{broadcast, true}, binary]),
    IpList = get_lan_ip(),
    LanBin = term_to_binary({IpList, Port}),
    MyKey128 = key_to_128(MyKey),
    HisKey128 = key_to_128(HisKey),
    MyPacket = <<?SERVER_REQ/binary, MyKey128/binary, HisKey128/binary, LanBin/binary>>,
    start_conn(),
    {ok, #state{socket = Socket, s_ip = ServerIp, 
            s_port = ServerPort, my_lan = {IpList, Port}, 
            my_port = Port, my_packet = MyPacket,
            my_key = MyKey128, his_key = HisKey128}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.


%% lan
handle_info({udp, _Socket, Ip, Port, <<?LAN_CONN>>}, State) ->
    case State#state.his_net of
        undefined ->
            State2 = State;
        _His ->
            case State#state.conn_type of 
                undefined ->
                    State2 = State#state{conn = {Ip, Port}, conn_type = ?LAN_CONN},
                    gen_tcp:send(State#state.socket, Ip, Port, <<?LAN_CONN/binary>>),
                    io:format("recv connect from lan, ~w~n", [{Ip, Port}]), 
                    erlang:send_after(3 * 1000, self(), heartbeat);
                ?WAN_CONN ->
                    State2 = State#state{conn = {Ip, Port}, conn_type = ?LAN_CONN},
                    gen_tcp:send(State#state.socket, Ip, Port, <<?LAN_CONN/binary>>),
                    io:format("recv connect from lan, ~w~n", [{Ip, Port}]);
                _ ->
                    State2 = State 
            end
    end,
    {noreply, State2};

%% wan
handle_info({udp, _Socket, Ip, Port, <<?WAN_CONN>>}, State) ->
    case State#state.his_net of
        undefined ->
            State2 = State;
        _His ->
            case State#state.conn_type of 
                undefined ->
                    State2 = State#state{conn = {Ip, Port}, conn_type = ?WAN_CONN},
                    gen_tcp:send(State#state.socket, Ip, Port, <<?WAN_CONN/binary>>),
                    io:format("recv connect from wan, ~w~n", [{Ip, Port}]), 
                    erlang:send_after(3 * 1000, self(), heartbeat);
                _ ->
                    State2 = State 
            end
    end,
    {noreply, State2};

%% server response
handle_info({udp, _Socket, _Ip, _Port, 
        <<?SERVER_RES, HisKey:128/bitstring, Ip:32/bitstring, WanPort:16, Packet/binary>>}, State) ->
    <<I1:8, I2:8, I3:8, I4:8>> = Ip,
    WanIp = {I1, I2, I3, I4},
    LanArgs = binary_to_term(Packet),
    io:format("begin to make hole with ~w~n", [HisKey]),
    p2p_conn(State#state.socket, {WanIp, WanPort, LanArgs}),
    erlang:send_after(2 * 1000, self(), p2p_conn),
    {noreply, State#state{his_net = {WanIp, WanPort, LanArgs}, his_key = HisKey}};


%% p2p data
handle_info({udp, _Socket, Ip, Port, <<?HEART_BEAT, Packet/binary>>}, State) ->
    io:format("recv p2p data from ip:~p port:~p packet: ~p~n", [Ip, Port, Packet]),
    {noreply, State};

%% recv bcast conn
handle_info({udp, Socket, Ip, Port, <<?BCAST_CONN, HisKey:128/bitstring, MyKey:128/bitstring>>}, State) ->
    case State#state.my_key =:= HisKey of
        true ->
            %io:format("recv bcast conn from myself~n", []),
            State2 = State;
        false ->
            %io:format("recv bcast conn from him ~w ~w ~w~n", [State#state.my_key, MyKey, HisKey]),
            case State#state.my_key =:= MyKey of
                true ->
                    case State#state.conn_type of
                        undefined ->
                            State2 = State#state{conn = {Ip, Port}, conn_type = ?BCAST_CONN},
                            gen_udp:send(Socket, Ip, Port, <<?BCAST_CONN/binary, MyKey/binary, HisKey/binary>>),
                            io:format("recv connect from bcast, ~w~n", [{Ip, Port}]), 
                            erlang:send_after(3 * 1000, self(), heartbeat);
                        ?WAN_CONN ->
                            State2 = State#state{conn = {Ip, Port}, conn_type = ?BCAST_CONN},
                            gen_udp:send(Socket, Ip, Port, <<?BCAST_CONN/binary, MyKey/binary, HisKey/binary>>),
                            io:format("recv connect from bcast, ~w~n", [{Ip, Port}]);
                        _ ->
                            State2 = State
                    end;
                false ->
                    State2 = State
            end
    end,
    {noreply, State2};

%% send bcast conn
handle_info(bcast_conn, State) ->
    case State#state.conn_type of
        undefined ->
            erlang:send_after(1000, self(), bcast_conn),
            BcastBin = <<?BCAST_CONN/binary, (State#state.my_key)/binary, (State#state.his_key)/binary>>,
            %io:format("send bcast conn ~w~n", [BcastBin]),
            gen_udp:send(State#state.socket, {255, 255, 255, 255}, State#state.my_port, BcastBin);
        _ ->
            ignore
    end,
    {noreply, State};

%% server request
handle_info(server_req, State) ->
    case State#state.his_net of
        undefined ->
            case State#state.conn_type of
                undefined ->
                    erlang:send_after(3000, self(), server_req),
                    gen_udp:send(State#state.socket, State#state.s_ip, State#state.s_port, State#state.my_packet);
                _ ->
                    ignore
            end;
        _ ->
            ignore
    end,
    {noreply, State};

%% p2p_conn
handle_info(p2p_conn, State) ->
    case State#state.conn_type of
        undefined ->
            erlang:send_after(2 * 1000, self(), p2p_conn),
            p2p_conn(State#state.socket, State#state.his_net);
        _ ->
            ignore
    end,
    {noreply, State};

%% heartbeat 
handle_info(heartbeat, State) ->
    erlang:send_after(3 * 1000, self(), heartbeat),
    {Ip, Port} = State#state.conn,
    gen_udp:send(State#state.socket, Ip, Port, <<?HEART_BEAT/binary>>),
    {noreply, State};

handle_info(Info, State) ->
    io:format("recv other info : ~w~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


get_lan_ip() ->
    Ip192 = get_local_192(),
    Ip172 = get_local_172(),
    Ip10 = get_local_10(),
    Ip192 ++ Ip172 ++ Ip10.

get_local_192() ->
    Cmd = "ifconfig |grep \"inet addr:\" | awk -F:  '{print $2}'|awk '{print $1}'|grep '^192\\.168'",
    get_ip_from_os(Cmd).

get_local_172() ->
    Cmd = "ifconfig |grep \"inet addr:\" | awk -F:  '{print $2}'|awk '{print $1}'|grep '^172\\.16'",
    get_ip_from_os(Cmd).

get_local_10() ->
    Cmd = "ifconfig |grep \"inet addr:\" | awk -F:  '{print $2}'|awk '{print $1}'|grep '^10\\.'",
    get_ip_from_os(Cmd).

get_ip_from_os(Cmd) ->
    Ip = os:cmd(Cmd),
    IpList = string:tokens(Ip, "\n"),
    lists:map(fun(IpStr) ->
                IpStr2 = string:tokens(IpStr, "."),
                IpStr3 = lists:map(fun(X) ->list_to_integer(X) end, IpStr2),
                list_to_tuple(IpStr3)
        end, IpList).

p2p_conn(Socket, {WanIp, WanPort, {LanIpList, LanPort}}) ->
    gen_udp:send(Socket, WanIp, WanPort, <<?WAN_CONN/binary>>),
    %io:format("send p2p_conn wan, wanip:~w, wanport:~w~n", [WanIp, WanPort]),
    lists:foreach(fun(LIp) ->
                %io:format("send p2p_conn lan, lanip:~w, lanport:~w~n", [LIp, LanPort]),
                gen_udp:send(Socket, LIp, LanPort, <<?LAN_CONN/binary>>)
        end, LanIpList).

key_to_128(Key) ->
    Size = byte_size(Key),
    case Size < 128 of
        true ->
            B = lists:foldl(fun(_, Acc) ->
                        <<$$:8, Acc/binary>>
                end, <<>>, lists:seq(1, ((128 div 8) - Size))),
            <<Key/binary, B/binary>>;
        false ->
            <<Key2:128, _/binary>> = Key,
            Key2
    end.

start_conn() ->
    erlang:send_after(3 * 1000, self(), server_req),
    erlang:send_after(1 * 1000, self(), bcast_conn),
    ok.
            

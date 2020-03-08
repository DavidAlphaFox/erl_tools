-module(gdbstub_hub).
-export([start_link/1,
         send/1, call/1,
         dev/1, devs/0,
         %% Some high level calls
         info/1,
         find_uid/1, uids/0, uids/1,
         ping/1,
         call/3,
         parse_syslog_ttyACM/1,

         %% Internal, for reloads
         ignore/2, print_etf/2,
         dev_start/1, dev_handle/2,
         hub_handle/2,
         default_handle_packet/2,
         encode_packet/3,
         decode_packet/3,
         decode_info/2,

         test/1
]).

-include("slip.hrl").

%% This module is a hub for uc_tools gdbstub-based devices.  See also
%% gdbstub.erl for GDB RSP protocol code.

%% Singal flow:
%% - gdbstub_hub board gets enumerated on some host
%% - hosts's udev config connects to exo_notify
%% - gdbstub_hub hub gets an 'add_tty' message
%% - dev_start/1 will start a process for this device
%% - this process starts a GDB server process for GDBRSP over TCP
%% - the server supports multiple connections

%% See /etc/net/udev/notify-tty.sh which currently delegates to
%% zoe:/etc/net/udev/tty/zoe_usb_9-2.sh

%% The script sends a line to the exo_notify daemon:
%% bluepill add zoe /dev/ttyACM1 /devices/pci0000:00/0000:00:16.0/usb9/9-2/9-2.4/9-2.4:1.0/tty/ttyACM1

%% The host name + devpath is enough to uniquely identify the location
%% of the device.

start_link(Config) ->
    HubHandle = maps:get(hub_handle, Config, fun gdbstub_hub:hub_handle/2),
    {ok,
     serv:start(
       {handler,
        fun() -> process_flag(trap_exit, true), Config end,
        HubHandle})}.

%% Udev events will eventuall propagate to here.

%% Add a TTY device, most likely USB.  DevPath is used to uniquely
%% identify the device, based on the physical USB port location.  It
%% is assumed the device is still in gdbstub mode (app not running).
hub_handle({add_tty,BHost,TTYDev,DevPath}, State) ->
    hub_handle({add_tty,BHost,TTYDev,DevPath,false}, State);

hub_handle({add_tty,BHost,TTYDev,DevPath,AppRunning}=_Msg, State)
  when is_binary(BHost) and
       is_binary(TTYDev) and
       is_binary(DevPath) ->
    Host = binary_to_atom(BHost, utf8),
    log:info("~p~n", [_Msg]),

    SpawnPort = maps:get(spawn_port, State),

    {ID,Info0} = 
        case linux:devpath_usb_port(DevPath) of
            {ok, UsbPort} -> {{Host,UsbPort}, #{ usbport => UsbPort }};
            _ -> {{Host,{tty,TTYDev}}, #{}}
        end,
    case maps:find(ID, State) of
        {ok, Pid} ->
            log:info("already have ~p~n", [{ID,Pid}]),
            State;
        _ ->
            %% Easier to decouple GDB communication if there is a
            %% dedicated process per device.

            %% FIXME: Use listen errors to determine next port.
            Hub = self(),
            <<Offset:14,_:2,_/binary>> = crypto:hash(sha, [BHost,DevPath]),
            TcpPort = 10000 + Offset,

            Pid = ?MODULE:dev_start(
                     maps:merge(
                       Info0,
                       #{ hub => Hub,
                          spawn_port => SpawnPort,
                          log => fun gdbstub_hub:ignore/2,
                          %% log => fun(Msg,S) -> log:info("~p~n",[Msg]),S end,
                          host => Host,
                          tty => TTYDev,
                          devpath => DevPath,
                          tcp_port => TcpPort,
                          app => AppRunning,
                          line_buf => <<>>,
                          id => ID })),
            _Ref = erlang:monitor(process, Pid),
            log:info("adding ~p~n", [{ID,Pid}]),
            maps:put({dev,ID}, Pid, State)
    end;

hub_handle({up, Pid}, State) when is_pid(Pid) ->
    %% Ignore here.  Useful for Handle override.
    State;

hub_handle({'DOWN',_,_,Pid,_}=_Msg, State) ->
    log:info("~p~n", [_Msg]),
    hub_remove_pid(Pid, State);

hub_handle({'EXIT',_Pid,__Reason}=_Msg,State) ->
    %% Monitor handles children.
    %% log:info("~p~n", [_Msg]),
    %% hub_remove_pid(Pid, State);
    State;


hub_handle({Pid, {dev_pid, ID}}, State) ->
    obj:reply(Pid, maps:find(ID, State)),
    State;
                          
hub_handle(Msg, State) ->
    obj:handle(Msg, State).

hub_remove_pid(Pid, State) ->
    IState = tools:maps_inverse(State),
    case maps:find(Pid, IState) of
        {ok, ID} ->
            maps:remove(ID, State);
        _ ->
            log:info("Warning: ~p not registered~n", [Pid]),
            State
    end.


%% Start a process as a companion to the device, communicating over
%% serial port.  If app is not running, the wire protcol is RSP.  If
%% app is running it can have its own protocol.  The common case is
%% SLIP supporting wrapped RSP.
dev_start(#{ tty        := Dev,
             id         := {Host, _},
             hub        := Hub,
             spawn_port := SpawnPort,
             app        := AppRunning } = Init0) ->
    %% When app is running we need to make an assumption about the
    %% application's serial port framing protocol.  SLIP is a good
    %% standard.  It is also assumed that the packet level supports
    %% the 2-byte tags.
    Init =
        case AppRunning of
            false ->
                Init0;
            true  ->
                maps:merge(
                  Init0,
                  #{ decode => decoder(slip),
                     encode => encoder(slip)
                   })
        end,
    serv:start(
      {handler,
       fun() ->
               log:set_info_name({Host,Dev}),
               log:info("connecting...~n"),

               %% The tools:spawn_port/1 API is used to allow starting
               %% of remote binary code in an abstract manner.
               Port = tools:apply(
                        SpawnPort,
                        [#{ host => Host,
                            cmd  => "gdbstub_connect",
                            args => [Dev],
                            opts => [use_stdio, binary, exit_status] }]),
               log:info("connected ~p~n",[Port]),
               Gdb = gdb_start(maps:merge(Init, #{ pid => self() })),
               Pid = self(),
               spawn(
                 fun() ->
                         log:info("getting meta info~n"),
                         %% This needs to be a separate process
                         %% because it interacts with the device's
                         %% main process before finalizing some
                         %% information.
                         try
                             obj:call(Pid, {set_meta, 
                                            gdbstub:uid(Pid),
                                            gdbstub:protocol(Pid),
                                            gdbstub:protocol2(Pid)},
                                      6001)
                         catch
                             C:E ->
                                 log:info("error getting meta info~n~p~n", [{C,E}])
                         end,
                         log:info("got meta info~n"),
                         Hub ! {up, Pid}
                 end),

               maps:merge(
                 Init,
                 #{ gdb => Gdb,
                    port => Port })
       end,
       fun gdbstub_hub:dev_handle/2}).

dev_handle(Msg,State) ->
    %% Tap point
    log:info("~p~",[{Msg,State}]),
    dev_handle_(Msg,State).
dev_handle_(Msg={_,dump},State) ->
    obj:handle(Msg, State);
dev_handle_({Pid,{set_meta, UID, Proto, Proto2_}}, State) ->
    obj:reply(Pid, ok),
    Proto2 = case Proto2_ of unknown -> Proto; P2 -> P2 end,
    %% Pick a decoder for Proto2
    maps:merge(
      State,
      #{ uid => UID,
         decode => decoder(Proto2),
         encode => encoder(Proto),
         proto => Proto,
         proto2 => Proto2 });
dev_handle_({set_peer, Peer}, State) ->
    link(Peer),
    maps:put(peer, Peer, State);

dev_handle_({set_forward, Handle}, State) ->
    maps:put(forward, Handle, State);

dev_handle_({set_name, Name}, State) ->
    maps:put(name, Name, State);


%% This only works in boot loader mode.  Once app is started, a
%% different mechanism is needed.
dev_handle_({Pid, {rsp_call, Request}}, 
            #{ port := Port, app := false } = State) ->
    %% log:info("rsp_call: ~p~n", [Request]),
    true = port_command(Port, Request),
    obj:reply(
      Pid,
      case Request of
          "+" -> "";
          _   -> rsp:recv_port(Port, 6004)
      end),
    State;

%% For now, assume TAG_GDB 0xFFFD tagging.
dev_handle_({CallerPid, {rsp_call, Request}}, 
            #{ app := true } = State) ->
    %% Spawn a process for each request.  That's going to be a lot
    %% simpler than trying to manage state machines here.  FIXME: this
    %% no longer handles mutual exclusion.  It will just fail.
    case maps:find(rsp_call_waiting, State) of
        {ok, PrevRspCall} ->
            exit({already_have_rsp_call_waiting, PrevRspCall});
        _ ->
            BinReq = iolist_to_binary(Request),
            MainPid = self(),
            WaiterPid = 
                spawn(
                  fun() ->
                          %% log:info("to_gdbstub: ~p~n", [BinReq]),
                          MainPid ! {send_packet, <<?TAG_GDB:16, BinReq/binary>>},
                          Reply = 
                              case Request of
                                  "+" -> "";
                                  _   -> rsp:recv_data(6005)
                              end,
                          MainPid ! {rsp_call_reply, Reply}
                  end),
            maps:put(rsp_call_waiting, {WaiterPid, CallerPid}, State)
    end;
dev_handle_({rsp_call_reply, Reply},
            #{ rsp_call_waiting := {_,CallerPid} } = State) ->
    obj:reply(CallerPid, Reply),
    maps:remove(rsp_call_waiting, State);

%% Initially, ports speak GDB RSP.  Once we send something else, the
%% gdbstub connects the application.
dev_handle_({send, RawData},
            #{ port := Port } = State) ->
    true = port_command(Port, RawData),
    maps:put(app, true, State);

dev_handle_({send_packet, Packet},
            #{ encode := {EncodePacket,Type} } = State)
  when is_binary(Packet) ->
    Encoded = EncodePacket(Type,Packet,[]),
    %% log:info("~nPacket=~p,~nEncoded=~p,~nEncodePacket=~p,~nType=~p~n",[Packet,Encoded,EncodePacket,Type]),
    dev_handle({send, Encoded}, State);

dev_handle_({send_packet, IOList}, State) ->
    dev_handle_({send_packet, iolist_to_binary(IOList)}, State);

dev_handle_({send_term, Term},
            #{ port := Port } = State) ->
    %% sm_etf uses {packet,4} wrapping
    Bin = term_to_binary(Term),
    Size = size(Bin),
    true = port_command(Port, [<<Size:32>>,Bin]),
    State;


%% Generic RPC call.   See ?TAG_REPLY case below.
dev_handle_({Pid, {call, Packet}}, State) ->
    {Wait, State1} = wait(Pid, State),
    %% log:info("wait: ~p~n",[{Wait,Pid}]),
    Ack = term_to_binary(Wait),
    dev_handle_({send_packet, [Packet,size(Ack),Ack]}, State1);


%% For GDB RSP, all {data,_} messages should arrive in the
%% {rsp_call,_} handler.

%% If the application sends something back, it is assumed to be a
%% protocol understood by erlang:decode_packet.
dev_handle_({Port, Msg}, #{ port := Port} = State) ->
    %% log:info("Msg=~p~n", [Msg]),
    case Msg of
        {data, Bin} ->
            decode_and_handle_packet(Bin, State);
        _ ->
            log:info("ERROR: ~p~n",[Msg]),
            exit(Msg)
    end;

%% Other ports have ad-hoc routing.
dev_handle_({Port, _}=Msg, State) when is_port(Port) ->
    Handle = maps:get({handle,Port}, State),
    Handle(Msg, State);


%% Any other message gets passed to the "driver", which originally
%% only handled incoming binary messages, but can just as well be
%% repurposed to also handle messages sent to the proxy process.  This
%% isn't pretty as we're mixing two protocols, but it is terribly
%% convenient.
dev_handle_(Msg, #{ forward := Forward } = State) ->
    Forward(Msg, State).

ignore(_Msg, State) ->
    State.

%% Because port is in raw mode, we don't have proper segmentation.  Do
%% that here.  DecodePacket use the API of erlang:decode_packet/3.
decode_and_handle_packet(NewBin, State = #{ decode := {DecodePacket, Type} }) ->
    PrevBin = maps:get(rest, State, <<>>),
    Bin = iolist_to_binary([PrevBin, NewBin]),
    case DecodePacket(Type,Bin,[]) of
        {more, _} ->
            maps:put(rest, Bin, State);
        {ok, Msg, RestBin} ->
            State1 = handle_packet(Msg, State),
            decode_and_handle_packet(<<>>, maps:put(rest, RestBin, State1));
        {error,_}=E ->
            log:info("~p~n",[{E,Bin}]),
            maps:put(rest, <<>>, State)
    end.

%% Empty messages are side effects of the transport encoding, and do
%% not have any in-band meaning.
handle_packet(<<>>, State) ->
    State;

%% After frameing, the first option is to send the packets to some
%% specified destination.
handle_packet(Msg, State) ->
    %% log:info("handle_packet: ~p~n", [Msg]),
    case {maps:find(peer, State),
          maps:find(forward, State)} of
        {_,{ok, Forward}} ->
            %% log:info("forward: ~p ~p~n", [Forward, Msg]),
            Forward(Msg, State);
        {{ok, Pid}, _} ->
            %% log:info("to peer: ~p: ~p~n", [Pid, Msg]),
            %% Size = size(Msg),
            %% Pid ! {send, <<Size:32, Msg/binary>>},
            Pid ! {send, Msg},
            State;
        %% Nowhere to go.  Use default, which is mostly just a
        %% print-to-console endpoint.
        _ ->
            default_handle_packet(Msg, State)
    end.

%% To print, assume first that the message supports the 2-byte type
%% tags which are used to transport generic system-level messages.
default_handle_packet(<<?TAG_GDB:16, Msg/binary>>, State) ->
    case maps:find(rsp_call_waiting, State) of
        {ok, {WaiterPid,_}} ->
            %% There is a waiting RSP call.  Pass all the chunks
            %% there.  The waiter will finish once a complete message
            %% has arrived.
            WaiterPid ! {data, binary_to_list(Msg)};
        _ ->
            %% No actual RSP call waiting.
            log:info("from_gdbstub: ~p~n", [Msg]),
            ok
    end,
    State;
default_handle_packet(<<?TAG_INFO:16, Msg/binary>>, State) ->
    decode_info(Msg, State);

%% See {call,_} case in dev_handle_/2
default_handle_packet(<<?TAG_REPLY:16,L,Ack/binary>>=Msg, State) ->
    %% log:info("ack: ~p~n",[Ack]),
    try
        Wait = binary_to_term(Ack, [safe]),
        %% log:info("wait: ~p~n",[Wait]),
        {Pid, State1} = unwait(Wait, State),
        Rpl = binary:part(Ack, L, size(Ack)-L),
        %% log:info("reply: ~p~n",[Rpl]),
        obj:reply(Pid, Rpl),
        State1
    catch _:_ ->
            %% This case is for acks that are generated outside of
            %% the {call,Packet} mechanism above.
            log:info("bad ack in TAG_REPLY message: ~p~n",[Msg]),
            State
    end;


%% For anything else, we're just guessing.
default_handle_packet(<<Tag,_/binary>>=Msg, State) ->
    case Tag of
        131 -> print_etf(Msg, State);
        _   -> print_packet(Msg, State)
    end.

print_packet(Msg, State) -> 
    log:info("packet: ~p~n", [Msg]),
    State.
print_etf(Msg, State) -> 
    try
        Term = binary_to_term(Msg),
        %% Assume this is from uc_lib/gdb/sm_etf.c
        case Term of
            [{123,LogData}] ->
                log:info("term: ~s", [LogData]);
            _ ->
                log:info("term decode failed: ~p~n", [Term])
        end
    catch _C:_E -> 
            log:info("~p~n",[{_C,_E}])
            %% print(Msg, State)
    end,
    State.

decode_info(Msg, State = #{ line_buf := Buf }) ->
    Msg1 = iolist_to_binary([Buf,Msg]),
    case erlang:decode_packet(line, Msg1, []) of
        {ok, Line, Buf1} ->
            log:info("info: ~s", [Line]),
            decode_info(<<>>, maps:put(line_buf, Buf1, State));
        {more, _} ->
            maps:put(line_buf, Msg1, State)
    end.
    


%% GDB RSP server.

gdb_start(#{ tty := Dev, id := {Host, _}, tcp_port := TCPPort } = Init) ->
    serv:start(
      {handler,
       fun() ->
               log:set_info_name({gdb_serv,{Dev,Host}}),
               log:info("GDB remote access on TCP port ~p~n",[TCPPort]),
               serv_tcp:init(
                 [TCPPort], 
                 %% loop/2 uses blocking code (rsp:recv/1)
                 {body, 
                  fun(Sock, _) -> 
                          log:set_info_name({gdb_conn,{Dev,Host}}),
                          log:info("connection from ~999p~n", [inet:peername(Sock)]),
                          %% log:info("new connection~n"),
                          gdb_loop(maps:put(sock, Sock, Init))
                  end})
       end,
       fun serv_tcp:handle/2}).

%% GDB session is coupled to name, not to device instance.  This allows
%% device restarts while keeping gdb conn open.
gdb_loop(State = #{ sock := Sock, log := Log }) ->
    Request = rsp:recv(Sock),
    _ = Log({request,Request}, State),
    case gdb_dispatch(State, Request) of
        "" -> ignore;
        Reply ->
            _ = Log({reply, Reply}, State),
            ok = rsp:send(Sock, Reply)
    end,
    gdb_loop(State).

gdb_dispatch(#{ pid := Pid}, Request) ->
    obj:call(Pid, {rsp_call, Request}, 6002).


%% It might be convenient. But maybe best not expose a naked Erlang
%% console on a TCP port without any form of authentication.

%% gdb_dispatch(#{ pid := Pid}, Request) ->
%%     %% By default, Send the the GDB command to the device.
%%     Forward = fun() -> obj:call(Pid, {rsp_call, Request}) end,

%%     %% Except when it is a monitor command...
%%     case rsp:qRcmd(Request) of
%%         false -> Forward();
%%         "" -> Forward();
%%         Cmd ->
%%             case lists:last(Cmd) of
%%                 46 ->
%%                     %% ... and it ends with a dot.  Then interpret it
%%                     %% as an erlang command where 'Dev' variable is bound.
%%                     Env = [{'Dev',Pid}],
%%                     Reply = tools:read_eval_print(Cmd, Env),
%%                     rsp:wrap(tools:hex(lists:flatten(Reply)));
%%                 _ ->
%%                     Forward()
%%             end
%%     end.


%% FIXME: Resolution isn't done very well.
send(Msg) -> gdbstub_hub ! Msg.
call(Msg) -> obj:call(gdbstub_hub, Msg, 6003).

dev(Pid) when is_pid(Pid) -> Pid;
dev(ID) -> {ok, Pid} = call({dev_pid, ID}), Pid.


info(ID) ->
    case call({dev_pid,ID}) of
        {ok, Pid} -> obj:dump(Pid);
        E -> E
    end.

find_uid(UID) ->
    maps:find(UID, uids()).
uids() ->
    uids(gdbstub_hub).
devs(Hub) ->
    [Pid || {{dev,_Dev},Pid} <- maps:to_list(obj:dump(Hub))].
devs() ->
    devs(gdbstub_hub).
    
uids(Hub) ->
    lists:foldl(
      fun(Pid, Map) ->
              case obj:dump(Pid) of
                  #{ uid := UID} ->
                      maps:put(UID,Pid,Map);
                  _ ->
                      Map
              end
      end,
      #{},
      devs(Hub)).



%% PROTOCOLS

%% The protocol that runs over the virtual serial port can be
%% anything.  What we need is a way for the board to specify how it
%% wants to be hooked up.  Note that input and output prococols can be
%% different.
%%
%% - raw
%% - {packet,N}
%% - {etf,N}         ETF wrapped in {packet,N}
%% - eterm           Printed Erlang terms
%% - sexp            s-expressions
%% - {driver,M,P}    Packet protocol P with some driver module M

decoder({packet,N})   -> {fun erlang:decode_packet/3, N};
decoder(raw)          -> {fun erlang:decode_packet/3, raw};
decoder(slip)         -> {fun ?MODULE:decode_packet/3, slip};
decoder({driver,_,P}) -> decoder(P);
decoder(_Dec) -> 
    log:info("WARNING: unknown decoder=~p~n", [_Dec]),
    decoder(raw).

decode_packet(slip,Bin,[]) when is_binary(Bin) ->
    slip_decode(Bin).


%% There doesn't seem to be a corresponding erlang:encode_packet, so
%% just implement some here.
encoder({packet,N})   -> {fun ?MODULE:encode_packet/3, N};
encoder(slip)         -> {fun ?MODULE:encode_packet/3, slip};
encoder(raw)          -> {fun ?MODULE:encode_packet/3, raw};
encoder({driver,_,P}) -> encoder(P);
encoder(_Enc) -> 
    log:info("WARNING: unknown encoder ~p~n", [_Enc]),
    encoder(raw).

encode_packet(slip,Bin,[]) when is_binary(Bin) ->
    slip_encode(Bin);
encode_packet(Type,Bin,[]) when is_binary(Bin) ->
    Size = size(Bin),
    case Type of
        4   -> [<<Size:32>>, Bin];
        raw -> Bin
    end.

%%as_binary(Bin) when is_binary(Bin) ->
%%    Bin;
%%as_binary(IOList) ->
%%    iolist_to_binary(IOList).


%% Simple registry for pending requests.
wait(Term, State) ->
    wait(Term, State, 0).
wait(Term, State, N) ->
    case maps:find({wait, N}, State) of
        {ok,_} -> wait(Term, State, N+1);
        _ -> {N, maps:put({wait, N}, Term, State)}
    end.
unwait(N, State) ->
    {maps:get({wait, N}, State),
     maps:remove({wait, N}, State)}.



%% Export encode/decode as well.

slip_encode(IOList) ->
    Bin = iolist_to_binary(IOList),     %% log:info("Bin ~p~n",[Bin]),
    Lst = binary_to_list(Bin),          %% log:info("List ~p~n",[Lst]),
    IOList1 = [192,slip_body(Lst),192], %% log:info("IOList1 ~p~n",[IOList1]),
    Bin1 = iolist_to_binary(IOList1),   %% log:info("Bin1 ~p~n",[Bin1]),
    Bin1.

slip_body([]) -> [];
slip_body([192|Tail])  -> [219,220|slip_body(Tail)];
slip_body([219|Tail])  -> [219,221|slip_body(Tail)];
slip_body([Head|Tail]) -> [Head|slip_body(Tail)].
    
                
slip_decode(Bin) when is_binary(Bin) ->
    slip_decode(binary_to_list(Bin),[]).
slip_decode([192|Rest],    Stack) ->
    {ok, list_to_binary(lists:reverse(Stack)), list_to_binary(Rest)};
slip_decode([219,220|Rest],Stack) -> slip_decode(Rest, [192|Stack]);
slip_decode([219,221|Rest],Stack) -> slip_decode(Rest, [219|Stack]);
slip_decode([219,_|_],_)          -> error(slip_decode);
slip_decode([219],         _)     -> {more, undefined};
slip_decode([],            _)     -> {more, undefined};
slip_decode([Char|Rest],   Stack) -> slip_decode(Rest, [Char|Stack]).



%% High level calls
ping(Pid) -> 
    <<>> = call(Pid, <<?TAG_PING:16>>, 6006).
        
call(Pid, Msg, Timeout) ->
    obj:call(Pid, {call,Msg}, Timeout).


%% If udev is not available, do something like this:
%% ssh root@$IP tail -n0 -f /tmp/messages
%% And watch the output
parse_syslog_ttyACM(Line) ->
    Rv = re:run(Line, "cdc_acm (.*): (ttyACM\\d+): USB ACM device",[{capture,all,binary}]),
    case Rv of
        {match,[_,UsbAddr,Dev]} -> {ok, {UsbAddr, Dev}};
        _ -> error
    end.    

test(messages) ->
    Line = <<"Oct  6 15:28:44 buildroot kern.info kernel: "
             "cdc_acm 2-1:1.0: ttyACM0: USB ACM device">>,
    test({messages,Line});
test({messages,Line}) ->
    parse_syslog_ttyACM(Line);
test(board) ->
    run:bash(
      ".", "ssh root@10.1.3.123 cat /tmp/messages",
      fun({line,Line}) -> 
              case test({messages,Line}) of
                  error -> ok;
                  {ok, Dev} -> log:info("~p~n", [Dev])
              end
      end),
    ok.

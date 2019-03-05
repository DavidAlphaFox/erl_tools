%% Simple socks5 proxy.

-module(socks_proxy).
-export([start_serv/1, on_accept/1, handle/2,
         connect/5]).
start_serv(#{ port := _ } = Spec) ->
    serv_tcp:start_link(
      maps:merge(
        Spec,
        #{ opts      => [binary,
                         {send_timeout,3000},
                         {packet, raw},
                         {active, false},
                         {reuseaddr, true}],
           on_accept => fun ?MODULE:on_accept/1,
           handle    => fun ?MODULE:handle/2 })).

io(Sock) ->
    Send =
        fun(D) ->
                %% log:info("S: ~p~n",[D]),
                gen_tcp:send(Sock, D)
        end,
    Recv =
        fun(N) ->
                case gen_tcp:recv(Sock, N, 3000) of
                    {error, _}=E -> exit(E);
                    {ok, D} -> 
                        %% log:info("R: ~p~n",[D]),
                        D
                end
        end,
    {Send,Recv}.
    

on_accept(#{ sock := Sock} = State) ->
    {ok, {From,_}} = inet:peername(Sock),
    log:set_info_name({?MODULE,From}),
    {Send,Recv} = io(Sock),

    %% Handshake
    %% https://en.wikipedia.org/wiki/SOCKS
    %% Not checking _Auths.  Assume no auth is ok.    
    <<5, NbAuths>> = Recv(2),
    _Auths = Recv(NbAuths),
    Send(<<5, 0>>),
    <<5,1,0,Kind>> = Recv(4),
    {Host,Port} =
        case Kind of
            1 ->
                <<A,B,C,D,P:16>> = Recv(6),
                {{A,B,C,D},P};
            3 ->
                <<DomainLen>> = Recv(1),
                Domain = Recv(DomainLen),
                <<P:16>> = Recv(2),
                {binary_to_list(Domain),P}
        end,
    log:info("~p~n", [{Host,Port}]),

    %% Allow override, e.g. to do source/dest based proxy chaining.
    Connect =
        maps:get(
          connect,
          State,
          fun(_,Hst,Prt,Opts) -> gen_tcp:connect(Hst,Prt,Opts,3000) end
          %% fun(_,Hst,Prt,Opts) -> connect("localhost",1081,Hst,Prt,Opts) end
         ),
    {ok, DstSock} = 
        Connect(
          From, Host, Port,
          [{active,true},{packet,raw},binary,{send_timeout,3000}]),
    Send(<<5,0,0,1, 
           %% Does this matter?  This is what SSH sends
           0,0,0,0,0,0
           %% 127,0,0,1,100,0
         >>),
    inet:setopts(Sock, [{active, true}]),
    maps:merge(
      State,
      #{ dst => {Host,Port},
         dst_sock => DstSock }).

%% Note: Something is blocking..  Not sure what.
handle({tcp,Sock,Data},
       #{ sock := Src, dst_sock := Dst } = State) ->
    case Sock of
        Src -> gen_tcp:send(Dst, Data);
        Dst -> gen_tcp:send(Src, Data)
    end,
    State;

handle({tcp_closed, Sock}=E,
       #{ sock := Src, dst_sock := Dst } = _State) ->
    case Sock of
        Src ->
            log:info("src closed~n"),
            gen_tcp:close(Dst),
            ok;
        Dst ->
            log:info("dst closed~n"),
            gen_tcp:close(Src),
            ok
    end,
    exit(E);


handle(Msg,State) ->
    %% log:info("~p~n",[{Msg,State}]),
    Rv = obj:handle(Msg,State),
    %% log:info("~p~n",[Rv]),
    Rv.
    
%% curl --socks5 10.1.3.29:1080 http://google.com



connect(ProxyHost,ProxyPort,
        Host,Port,Opts) ->
    {ok, Sock} = 
        gen_tcp:connect(
          ProxyHost, ProxyPort,
          [binary,
           {send_timeout,3000},
           {packet, raw},
           {active, false},
           {reuseaddr, true}]),

    {Send,Recv} = io(Sock),

    Send(<<5,1,0>>),
    <<5,0>> = Recv(2),
    case Host of
        {A,B,C,D} ->
            Send([<<5,1,0,1,A,B,C,D,Port:16>>]);
        _ ->
            Send([<<5,1,0,3>>,length(Host),Host,<<Port:16>>])
    end,
    <<5,0,0,1,_:32,_:16>> = Recv(10),
    
    inet:setopts(Sock, Opts),
    {ok, Sock}.




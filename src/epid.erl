-module(epid).
-export(
   [send/2,
    connect/2, disconnect/2,
    connect_bidir/2, disconnect_bidir/2,
    map/2,
    transfer/2,
    call/3, reply/3,

    %% Machinery for implementing an aggregating proxy.
    subscribe/3, unsubscribe/3, unsubscribe_all/2, down/2,
    subscribers/2, dispatch/3]).
-export_type(
   [epid/0, epid_map/1]).

%% TL;DR: Routable names for proxied objects.

%% 1. INTRODUCTION

%% An external pid, is an Erlang (proxy) process identifier paired
%% with an arbitrary extra identifier

-type epid() :: {'epid', pid() | atom() | {atom(), atom()}, any()}.


%% Epids are useful when Erlang processes are used to provide access
%% to a collection of external resources.

%% There are two core ideas here:
%%
%% 1) It is not always possible or convenient to map individual
%% external resources to Erlang processes (abstract objects /
%% processes / channels),
%%
%% 2) nor is it always ideal to route data over the Erlang network
%% (abstract connections).

%% The finer granularity starts to resemble the idea of typed
%% channels, where instead of having a single ad-hoc sum type
%% associated to the maibox of an Erlang process, there are several
%% (typed) channels per process, each having a simpler message type.

%% This factorization opens up a couple of avenues.  See the bottom of
%% this file for more information.


%% One example: If a channel only transports the message type T, it
%% starts to make sense to embed message transformations T->T.  This
%% can be expressed directly on the process identifier as ...
-type epid_map(T) :: {'epid_map', fun((T) -> T), epid_map(T) | epid()}.

%% ... with the associated operation:
map(Fn, Node) -> {epid_map, Fn, Node}.





%% 2. BASE PROTOCOL
%%
%% Erlang messages can be sent to an epid, just like a normal Erlang
%% process.  The ProxyProcess will implement delivery to SinkId.
send({epid, ProxyProcess, ChannelId}=_Dst, Msg) ->
    %% log:info("epid:send ~p~n",[{_Dst,Msg}]),
    ProxyProcess ! {epid_send, ChannelId, Msg};

%% The functor extension is handled in send/2, since destination epids
%% are usually opaque to the sender.
send({epid_map, Fn, Epid}, Msg) ->
    send(Epid, Fn(Msg)).



%% 3. UNI-DIRECTIONAL CONNECTIONS

%% The main driver for this abstraction was to find a standardized way
%% to connect (uni-directional) event sources and sinks on edge
%% devices that are proxied into an Erlang backbone.
%%
%% In this context it is very convenient to get rid of the need to
%% talk to the proxy process directly, so we define the connection
%% request protocol in terms of epids only.  Any concrete hub will
%% need to implement the other end of this.
connect({epid,_,_}=Src, Sink) ->
    send(Src, {epid_subscribe, Sink}),
    ok;

%% connect/2 also supports {epid_map,_,_} functor extension, but to
%% simplify other operations the mapping functions are are moved to
%% the sink before sending the epid_subscribe message to the source.
connect({epid_map, Fn, Src}, Sink) ->
    connect(Src, {epid_map, Fn, Sink}).

%% Disconnect is analogous.
disconnect({epid,_,_}=Src, Sink) ->    
    send(Src, {epid_unsubscribe, Sink}),
    ok;
disconnect({epid_map, Fn, Src}, Sink) ->
    disconnect(Src, {epid_map, Fn, Sink}).


%% 4. BI-DIRECTIONAL CONNECTIONS

%% Generalization to bi-directional connections.
%%
%% These are eventually symmetric, but require some careful setup
%% sequencing.  One end sends epid_subscribe to the other end upon
%% reception of epid_subscribe_bidir.  See implementation in ecat.erl,
%% which abstracts bi-directional socat-like channels.

%% Bi-directional connections do not support epid_map.

connect_bidir({epid_map, _, _}, _) -> throw(no_bidir_map);
connect_bidir(_, {epid_map, _, _}) -> throw(no_bidir_map);
connect_bidir(Src, Dst) ->
    send(Src, {epid_subscribe_bidir, Dst}).
disconnect_bidir(Src, Dst) ->
    send(Src, {epid_unsubscribe_bidir, Dst}).


%% 5. RPC / TRANSACTIONS
%%
%% Send a request to an epid and wait for a reply, blocking the callin
%% Erlang process.
call(Dst = {epid, Pid, _}, Request, Timeout) ->
    Ref = erlang:monitor(process, Pid),
    send(Dst, {call, self(), Ref, Request}),
    Rv = 
        receive 
            {'DOWN',Ref,process,Pid,Reason} ->
                {error, Reason};
            {Ref, Reply} ->
                Reply
        after Timeout ->
                {error, timeout}
        end,
    erlang:demonitor(Ref),
    Rv.
reply(Src, Ref, Reply) ->
    send(Src, {reply, Ref, Reply}).


%% 6. DATA TRANSFERS

%% The epid mechanism can be used to set up external connections or
%% transfers, sometimes called "data plane operations".
%%
%% This is a genuine leaky abstraction: Ideally, you would encapsulate
%% a transaction in a single message.  When messages or transaction
%% times get large, this becomes impractical.  An abstract method is
%% provided such that proxies can establish a better data channel,
%% e.g. a dedicated TCP pipe (e.g. SSH).
transfer(Src, Dst) ->
    call(Dst, {epid_transfer, Src}, infinity).

%% This trick can be applied to connect/2 as well: It is left to the
%% object to interpret epid_subscribe messages such that connections
%% could be implemented locally, i.e. without going over the Erlang
%% network.  An example would be a MIDI connection inside jackd, in
%% case of a MIDI controller and a jacd process connected to the same
%% instance.





%% 7. PUB/SUB

%% A typical setup consists of an Erlang process proxying an an
%% external event source that is in itself not aware of the existance
%% of the Erlang side.  In this case there the Erlang process behaves
%% as "aggregator" for all the external events coming in.  It is then
%% this aggregator proxy process that can implement epid subscription
%% behavior, effecitively emulating virtual external processes.  These
%% are some library routines that can be used to implement this.  See
%% midi_raw.erl

%% - dispatch:           send event to registered epids
%% - subscribe:          set up local state for dispatch (idempotent)
%% - unsubscribe, down:  remove dispatch state

%% The datastructure is optimzed for dispatch.
dispatch(EventId, Msg, State) ->
    lists:foreach(
      fun(Epid) -> send(Epid, Msg) end,
      subscribers(EventId, State)).

subscribers(EventId, State) ->
    maps:get({epid_dispatch,EventId}, State, []).

%% Set up the data structure necessary for dispatch.  Processes are
%% monitored, so we can tear down connections if proxy process fails.
subscribe(EventId, DstEpid, State) ->

    {epid,DstPid,_} = final_epid(DstEpid),

    case DstPid of
        Name when is_atom(Name) -> ok;
        {Name, Node} when is_atom(Name) and is_atom(Node) -> ok;


        _ -> _Ref = erlang:monitor(process, DstPid), ok
    end,
    DList0 = maps:get({epid_dispatch, EventId}, State, []),
    DList = case lists:member(DstEpid, DList0) of
                true -> DList0;
                false -> [DstEpid | DList0]
            end,
    maps:merge(
      State,
      #{ {epid_dispatch, EventId} => DList }).

%% Strip all functor processing.
final_epid({epid_map,_,E}) -> final_epid(E);
final_epid(E) -> E.
     

%% There are two "entries" to disconnect:
%% - The target proxy pid disappearing
%% - A specific disconnect event (pid might still have other connections)

%% These two mechanisms are simple to implement if we use a generic
%% connection filter.  Since they are rare, it's ok for this to be
%% O(N).
filter_connections(Filter, State) ->
    State1 =
        maps:map(
        fun({epid_dispatch, EventId}, DList) ->
                lists:foldr(
                  fun(Epid, Stack) ->
                          case Filter(EventId, Epid) of
                              true -> [Epid|Stack];
                              false -> Stack
                          end
                  end,
                  [], lists:reverse(DList));
           (_Key, Val) -> 
                Val
        end,
          State),
    %% Removes empties to avoid leaks.
    maps:filter(
      fun({epid_dispatch,_}, []) -> false; (_,_) -> true end, State1).

unsubscribe(EventId, Epid, State) ->
    NEpid = final_epid(Epid),
    filter_connections(
      fun(Src, Dst) -> not ((Src == EventId) and (final_epid(Dst) == NEpid)) end,
      State).

unsubscribe_all(EventId, State) ->
    filter_connections(
      fun(Src, _Dst) -> not (Src == EventId) end,
      State).
    

down({'DOWN', _Ref, process, Pid, _Reason}=_Msg, State) ->
    filter_connections(
      fun(_Src0, {epid, Pid0, _}) -> Pid /= Pid0 end,
      State).

    





%% 8. MISC NOTES

%% External/Extended Process IDentifier: process-like resources
%% implemented through Erlang proxy processes.
%%
%% This model works well for event sources and event sinks that have
%% very fine granularity, but cannot be represented as actual Erlang
%% processes for some practical reason, e.g. generic sensors and
%% actuators, test equipment ports, midi controller knobs and sliders,
%% audio input/output channels on a multi-channel card, effect
%% processor knobs etc..  Any configurable dataflow setup with a
%% granularity finer that the Erlang driver/proxy process.
%%
%% Such extended/external processes are represented by {epid, Proxy,
%% Id}, where Proxy is the Erlang process responsible for bridging the
%% Erlang world and the external event/process world, and Id is an
%% identifier for the external resource that behaves as a process, but
%% does not or cannot use Erlang's native PID format.
%%
%% The main benefit of this approach is that it allows abstraction of
%% the proxy processes, allowing global name resolution to happen at
%% the fine granularity.  This sounds trivial, but has a substantial
%% practical impact.


%% Contrasts this to:

%% - Pub/Sub: similar in effect, but using a different interface.
%%
%% - Erlang C nodes: avoids multi-component identifiers by mapping
%%   internal process resources to actual Erlang pids.
%%
%% - Typed channels vs. mailboxes.  While messages remain dynamically
%%   typed, the types can usually be much simpler.
%%
%% - Allows lazy instantiation for large or infinite collections.




%%
%% The general idea is that Erlang is a great model, but I found its
%% process granularity still too cource in many practical situations.
%% I set out to be able to do the following:
%%
%% - Send a message to a knob on a Midi controller to "connect" it to
%%   a parameter in a soft synth, such that subsequent knob events are
%%   sent directly to that parameter slot.  This allows to create an
%%   archive of connections separate from the source and sink object
%%   code.
%%
%% - Erlang processes are too heavy-weight for this, so we use the
%%   same conceptual model, but reduce the granularity.  This requires
%%   two kinds of problems to be solved:
%%
%%   - Sinks are addressed relative to a proxy Pid, e.g. {epid, Pid,
%%     Id} will arrive at the proxy Pid first, and will then be
%%     propagated to a non-Erlang entity.
%%
%%   - Events typically go through a pub/sub aggregators when they
%%     enter the Erlang world.  E.g. event sources typically have no
%%     object identity: there are just events coming from _somewhere_.
%%     However, the aggregator can restore the object model by using
%%     event tags as object identifiers.
%%
%% - This also leaves room for optimization: When the source and sink
%%   proxy Pids are the same, often an internal connection mechanism
%%   is more appropriate.  This intelligence can be implemented
%%   locally ( e.g. jack midi/audio client connections, C callbacks
%%   inside a uC ).
%%
%% - This mechanism of routable process identifiers can be combined
%%   with a name resolution step that is performed only once.
%%   Typically name resolution would need to be combined with Erlang
%%   style monitors to allow re-resolving when a subsystem is
%%   restarted or physically moved.
%%
%% - The tradeoff to creating C nodes is not well understood.
%%   Currently going by the assumption that 2-step routing is much
%%   simpler to implement, and also easier to debug.
%%
%% - Essentially, this can be used to create typed channels by
%%   removing as many tags as possible from the data and moving them
%%   to the name of the channel.
%%
%% - Transformation functions can easily be added for unidirectional
%%   connections.
%%
%% - Aside from pure transformation functions, generic stateful
%%   processing could be added as well, but would require more
%%   infrastructure overhead.  In contrast, pure functions can just be
%%   buried tagged onto the process identifier.



%% Examples: connect a midi input to a uC pin.
%% (Sorry, internal example only.  Ask Tom.)

%% Note that this is very straightforward.  The real trick is in
%% identifying the difference between names and routable addresses.
%% Name resolution is an essential part!

%% - uC pin:
%%   - Pid  = {relay_devrack,'exo@10.1.3.29'}
%%   - Sink = {relay, $B}
%%   This requires adding a case in relay_board.erl to translate the event.
%%   relay_solderstation ! {forward, {relay, $B}, 1}.
%%   epid:send({epid, {relay_solderstation,'exo@10.1.3.29'}, {relay,$B}}, 1).

%% - knob on the midi hub.  in midi_raw.erl it required handling
%%   epid_connect, to store the sink -> epid mapping, and then when
%%   device events come in, convert them to sink form and retreive
%%   epid.
%%   - Pid = {midi_raw,'exo@10.1.3.19'}
%%   - Src = {{zora,1},{cc,0,14}}
%%   to test:
%%   epid:connect({epid, {midi_raw,'exo@10.1.3.19'}, {{zora,1},{cc,0,14}}}, {epid, {relay_solderstation, 'exo@10.1.3.29'}, {relay, $B}}).
%%   epid:connect({epid, exo:pid(midi_raw), {{roza,1},{cc,0,14}}}, {epid, {relay_solderstation, 'exo@10.1.3.29'}, {relay, $B}}).
%%   epid:connect({epid, exo:pid(midi_raw), {{zora,1},{cc,0,14}}}, {epid, {exo_handle, element(2,emacs:distel_node())}, message}).

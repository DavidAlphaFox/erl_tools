-module(cowboy_wrap).
-export([
         http_request/3,
         http_reply/3,

         resp_xhtml/1,
         resp_body/2,
         resp_text/1,
         resp_term/1,
         resp_svg/1,
         html_body/2

         ]).

-include("web.hrl").

%% Convert Cowboy format for query formats to internal format:
-spec atom_map([{binary(),binary()}]) -> #{ atom() => binary() }.
atom_map(PropList) ->
    maps:from_list(
      [{binary_to_atom(Key,utf8),Val} || {Key,Val} <- PropList]).

http_reply(Req, State, Reply) ->
    case Reply of
        %% How to set size?  Likely Content-Length in Headers.
        {fold, Headers, Fold} ->
            %% Generator exposed as a fold taking a foldee with early
            %% abort protocol.  This is necessary to handle remote
            %% connection close.
            {ok, Req2} =  cowboy_req:chunked_reply(200, Headers, Req),
            Fold(fun(Data, _) -> 
                         case cowboy_req:chunk(Data, Req2) of
                             ok -> {next, ok};
                             Error -> 
                                 log:info("cowboy_req:chunk: ~p~n",[Error]),
                                 {stop, Error}
                         end
                 end, ok),
            {ok, Req2, State};
        {data, Headers, Data} ->
            %% Plain I/O list
            {ok, Req2} = cowboy_req:reply(200, Headers, Data, Req),
            {ok, Req2, State};
        {data, Code, Headers, Data} ->
            %% Plain I/O list
            {ok, Req2} = cowboy_req:reply(Code, Headers, Data, Req),
            {ok, Req2, State};
        {redirect, URL} ->
            {ok, Req2} =
                cowboy_req:reply(
                  302,
                  [{<<"Location">>, URL}],
                  <<"Redirecting...">>,
                  Req),
            {ok, Req2, State}
    end.


%% Wrappers to simplify Cowboy API to what is used in web.erl
http_request(Req, Get, Post) ->
    {BinPath,_} = cowboy_req:path_info(Req),
    {Method,_} = cowboy_req:method(Req),
    case Method of
        <<"POST">> ->
            %% {ok, PostData, _} = cowboy_req:body_qs(Req),
            %% Post(BinPath, atom_map(PostData));
            {ok, PostData, _} = cowboy_req:body(Req),
            Post(BinPath, PostData);
        <<"GET">> ->
            {QueryVals, _} = cowboy_req:qs_vals(Req),
            {Cookies, _} = cowboy_req:cookies(Req),
            {Referer, _} = cowboy_req:header(<<"referer">>, Req),
            {Peer, _} = cowboy_req:peer(Req),
            %% FIXME: Implementation has changed here. QVs are now
            %% kept separate.  The old implementation was just too
            %% messy.
            Env = #{
              wrap    => cowboy_wrap,
              referer => Referer,
              peer => Peer,
              cookies => atom_map(Cookies),
              query   => atom_map(QueryVals) 
             },
            %% log:info("qv: ~p~n", [QvMap]),
            Get(BinPath, Env)
    end.




%% Use XML/XHTML embedded in erlang.  see exml.erl
-spec resp_xhtml(exml:exml_el()) -> _.
resp_xhtml(Ehtml) ->
    {data, [?XHTML], exml:to_binary([Ehtml])}.

resp_text(Text) ->
    {data, [?PLAIN], Text}.

-spec resp_body(iolist(), [exml:exml_node()]) -> _.
resp_body(Title, Ehtml) ->
    resp_xhtml(html_body(Title, Ehtml)).

resp_term(Term) ->
    {data, [?PLAIN], io_lib:format("~120p",[Term])}.

-spec resp_svg(exml:exml_el()) -> _.
resp_svg(Exml) ->
    {data, [{<<"content-type">>,<<"image/svg+xml">>}], exml:to_binary([Exml])}.

-spec html_body(exml:exml_node(), [exml:exml_node()]) -> _.
html_body(Title, Ehtml) ->
    {html, [?XMLNS],
     [{head,[],
       [{meta,[?CHARSET],[]},
        {title,[],[Title]}]},
      {body,[],Ehtml}]}.

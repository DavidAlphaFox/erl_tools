-module(type_base).
-export([
         %% Convert values between binary and terms.
         encode/1, decode/1,

         %% Convert type tags between binary and terms.
         encode_type/1, decode_type/1,

         %% In case of human input, error handling is application
         %% level responsibility.
         decode_try/1,

         %% Perform encode->decode roundtrip and compare.
         valid/1,

         %% Type specification , mostly useful for finite types.
         type_spec/1, finite/1,
         encoder/1, decoder/1,
         
         %% Miasc low elvel tools
         atom/1, int/1,

         test/0
         
        ]).

%% FIXME: How to enable dialyzer to infer this?  Currently it just
%% infers atom() instead of the sum of specific atoms.
-type name() ::
        chanrep | edge | binary | device | int | atom | pterm | term | 
        boolean | pc_serial | hex | mac | ip | ip_nm |
        {int,integer(),integer()} | 
        %% {abstract,fun(( finite_values | encode | decoder ) -> any())} |
        finite().

-type finite() :: {finite, [{binary(), any()}]}.

-type encoder() :: fun((_) -> binary()).
-type decoder() :: fun((binary()) -> any()).


%% Types can be extended.  User should create a module with
%% encode/decode and type_encode/type_decode functions calling into
%% this module, providing impl().
-type impl() :: {impl, name(), {finite,_}|{_,_}}.
-spec encoder(name() | impl()) -> encoder().

encoder({impl, TypeSpec, {finite, Alist}}) ->
    InvAlist = [{B,A} || {A,B} <- Alist],
    convert_finite(TypeSpec, InvAlist);
encoder({impl, _, {Encode, _}}) ->
    Encode;
%% No implementation provided, use base types from this module.
encoder(TypeSpec) ->
    encoder({impl, TypeSpec, type_spec(TypeSpec)}).
    


-spec decoder(name() | impl()) -> decoder().
decoder({impl, TypeSpec, {finite, Alist}}) ->
    convert_finite(TypeSpec, Alist);
decoder({impl, _, {_, Decode}}) ->
    Decode;
decoder(TypeSpec) ->
    decoder({impl, TypeSpec, type_spec(TypeSpec)}).
    




test() -> encode({foo,<<"asdf">>}).
    


%% Some design notes:
%%
%% - Parse failures are handled with exceptions.  A decode_try
%%   function is provided to convert to ok/error format.
%%
%% - Decoders can assume binary input for simplicity.  IOLists are
%%   converted to binary at the top.
%%
%% - Encoders can produce IOLists.  Output is converted to binary at
%%   the top.



 

-spec decode_try({name(),iolist()}) -> {ok,_} | {error,_}.
decode_try(Arg) ->
    try decode(Arg) of
        Rv -> {ok, Rv}
    catch
        error:{case_clause,Type} -> 
            {error, {{bad_type, Type}, fb("bad type: ~p",[Type])}};
        {type, Info} ->
            {error, Info}
    end.

    
-spec encode({name(),_}) -> binary().
encode({Type, Val}) -> iolist_to_binary((encoder(Type))(Val)).

-spec decode({name(),binary()}) -> _.
decode({Type, Bin}) when is_binary(Bin) -> (decoder(Type))(Bin).

%% decode({Type, IOList}) -> decode({Type,iolist_to_binary(IOList)}). %% convenient

-spec valid({name(),_}) -> _.            
valid({Type,Val}=TV) ->    
    {ok,Val} == decode({Type, encode(TV)}).

-spec stop(name(),_,_) -> _.
stop(Type, Val, {Fmt, List}) ->
    throw({type,{Type, Val, fb(Fmt,List)}});
stop(Type, Val, Msg) ->
    throw({type,{Type, Val, iolist_to_binary(Msg)}}).


    
%% Reusable encode/decode primitives.
fb(Fmt,List) when is_list(List) -> tools:format_binary(Fmt,List).
%%fb_w(Obj) -> fb("~w",[Obj]).
fb_p(Obj) -> fb("~p",[Obj]).

id(X) -> X.
    
enc_atom(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom,utf8).
    
atom(Bin) ->
    try binary_to_atom(Bin, utf8)
    catch _:_ -> stop(atom, Bin, <<"Bad Atom">>) end.
            
int(Bin) ->
    try binary_to_integer(Bin)
    catch _:_ -> stop(int, Bin, <<"Bad Integer">>) end.
             
term(Bin) ->    
    try binary_to_term(Bin)
    catch _:_ -> stop(term, Bin, <<"Bad Term">>) end.

%% Note that not all terms are serializable through ~p printing.
%% pterm encoder checks if decode(encode(Term)) == Term.
pterm(Bin) ->
    try
        Str = binary_to_list(Bin),
        {ok, Tokens, _} = erl_scan:string(Str ++ "."),
        {ok, Term} = erl_parse:parse_term(Tokens),
        Term
    catch _:_ -> stop(pterm, Bin, <<"Syntax Error">>) end.
            

-spec enc_pterm(_) -> _.
enc_pterm(Term) ->
    try
        Bin = fb_p(Term),
        %% Check if it is reversible.
        Term = decode({pterm,Bin}),
        Bin
    catch
        _:_ -> stop(pterm, Term, <<"Can't represent">>)
    end.
    

                  


              
%% -spec type_spec(name()) -> finite() | {encoder(), decoder()}.
type_spec(Type) ->
    case Type of
        %% {abstract,Obj} ->
        %%     case Obj(finite_values) of
        %%         {ok, Alist} -> {finite, Alist};
        %%         error -> {Obj(encoder), Obj(decoder)}
        %%     end;
        {finite, _} = Spec -> Spec;
        binary  -> {fun id/1,   fun id/1};
        button  -> {fun id/1,   fun id/1}; %% see web.erl input/1 button type
        int     -> {fun fb_p/1, fun int/1};
        atom    -> {fun enc_atom/1, fun atom/1};
        pterm   -> {fun enc_pterm/1, fun pterm/1};
        term    -> {fun term_to_binary/1, fun term/1};
        boolean ->
            {fun fb_p/1,
             fun(Val) ->
                     case atom(Val) of
                         true -> true;
                         false -> false;
                         _ -> stop(boolean, Val, "Bad boolean")
                     end
             end};
        {int,Min,Max} ->
            {fun fb_p/1,
             fun(Val) ->
                     Int = decode({int, Val}),
                     case (Int >= Min) and (Int =< Max) of
                         true -> Int;
                         false -> stop({int,Min,Max}, Int, {"Outside of range: [~p,~p]",[Min,Max]})
                     end
             end};
        hex ->
            {fun fb_p/1, %% FIXME: wrong!
             fun(Bin) ->
                     try [V] = tools:unhex(binary_to_list(Bin)), V
                     catch _:_ -> stop(hex, Bin, "Bad HEX value")
                     end
             end};
        mac ->
            {fun({A,B,C,D,E,F}) ->
                     H = fun(V) -> tools:hex8(V) end,
                     type_meta:fb("~s:~s:~s:~s:~s:~s",
                        [H(V) || V <- [A,B,C,D,E,F]])
             end,
             fun(Val) ->
                     X=fun(Bin) -> decode({hex,Bin}) end,
                     case re:split(Val,":") of
                         [A,B,C,D,E,F] -> {X(A),X(B),X(C),X(D),X(E),X(F)};
                         _ -> type_meta:stop(mac, Val, "Bad MAC")
                     end
             end};
        ip ->
            {fun({A,B,C,D}) ->
                     type_meta:fb("~p.~p.~p.~p", [A,B,C,D])
             end,
             fun(Val) ->
                     X=fun(Bin) -> decode({{int,0,255},Bin}) end,
                     case re:split(Val,"\\.") of
                         [A,B,C,D] -> {X(A),X(B),X(C),X(D)};
                         _ -> type_meta:stop(ip, Val, "Bad IP")
                     end
             end};
        ip_nm ->
            {fun({IP,NM}) ->
                     type_meta:fb("~s/~p", [encode({ip,IP}),NM])
             end,
             fun(Val) ->
                     case re:split(Val,"/") of
                         [IP,NM] ->
                             {decode({ip,IP}),
                              decode({{int,0,24},NM})};
                         _ ->
                             type_meta:stop(ip_nm, Val, "Bad IP/NM pair")
                     end
             end}
    end.



%% Types constructed at run time are all finite types.  Provide a
%% shortcut. 
%%abstract_finite(BinToValList) ->
%%     {abstract, fun(finite_values) -> {ok, BinToValList} end}.

finite(BinToValList) -> {finite, BinToValList}.
    

convert_finite(Type, PL) ->    
    fun(Val) ->
            case proplists:get_value(Val,PL) of
                undefined ->
                    Vals = [s(K) || {K,_} <- PL],
                    Allowed = [hd(Vals), [[",",V] || V <- tl(Vals)]],
                    stop(Type, Val, {"Bad ~p, options are: ~s", [Type,Allowed]});
                El -> El
            end
    end.
  
%% For non-quoted printing of binaries and other objects.
s(Bin) when is_binary(Bin) -> Bin;
s(P) -> io_lib:format("~p",[P]).


%% Type specs need to be printable Erlang terms.
encode_type(Term) -> encode({pterm,Term}).
decode_type(Bin)  -> decode({pterm,Bin}).
    

%% A type is:

%% - validator from representation (text) to internal data type that
%%   has guaranteed constraints.
%%   {ok, Value} or {error,{Atom,HumanError}}
%%
%% - converter from internal representation to text that converts back
%%   to the original form.

%% Additional context:
%%
%% - Database (sqlite) contains text representation
%% - Configuration database has annotation var -> type





-module(sqlite3_kvstore).
-export([
         %% Implementation of kvstore on top of sqlite3.erl
         table_op/2,
         table/1, existing_table/1,
         table_init/2, table_delete/2

         ]).


-spec sql(sqlite3:db_spec(),
          binary(),
          [{'blob',binary()} | 
           {'text',binary()}]) -> [[binary()]].

sql(DB,Q,Bs) -> [Rows] = sqlite3:sql(DB,[{Q,Bs}]), Rows.
sql_transaction(DB,Qs) -> sqlite3:sql_transaction(DB,Qs).
    
    

%% Expose operations directly to allow lambda lifting, reducing stored
%% closure size on client side.  As a penalty, query strings are
%% recomputed, but it is still possible to cache them by storing the
%% result of the function lookup.

-type table_spec() :: {table, atom(), sqlite3:db(), atom()}.
-spec table_op(table_spec(), _) -> _.

%% Extension: get the table.
table_op({table,_TypeMod,DB,Table}, db_table) ->
    {ok, {DB,Table}};
table_op({table,TypeMod,DB,Table}, find) ->
    QRead = tools:format_binary(
              "select type,val from '~s' where var = ?", [table_name(Table)]),
    fun(Key) ->
            BinKey = type_base:encode_key(Key),
            case sql(DB, QRead, [{text,BinKey}]) of
                [[_,_] = BinTV] ->
                    {ok, type_base:decode_tv(TypeMod, BinTV)};
                [] ->
                    {error, {not_found, Key}}
            end
    end;

table_op({table,_,_,Table}, qload) ->
    tools:format_binary(
      "select var,type,val from '~s'", [table_name(Table)]);

table_op({table,TypeMod,DB,_}=Spec, to_list) ->
    QLoad = table_op(Spec, qload),
    fun() ->
            [type_base:decode_ktv(TypeMod, BinKTV)
             || BinKTV <- sql(DB, QLoad, [])]
    end;

table_op(Spec, to_map) ->
    ToList = table_op(Spec, to_list),
    table_op(Spec, to_map, ToList);

table_op({table,_TypeMod,DB,Table}, keys) ->
    QKeys = tools:format_binary(
              "select var from '~s'", [table_name(Table)]),
    fun() ->
            [type_base:decode_key(BinKey)
             || [BinKey] <- sql(DB, QKeys, [])]
    end;

table_op({table,TypeMod,_,Table}, qput) ->
    QPut = tools:format_binary(
               "insert or replace into '~s' (var,type,val) values (?,?,?)", [table_name(Table)]),
    fun(K,TV) ->
            BinKTV = type_base:encode_ktv(TypeMod, {K,TV}),
            {QPut, BinKTV}
    end;

table_op({table,_,DB,_}=Spec, put) ->
    fun(K,TV) ->
            MakeQPut = table_op(Spec, qput),
            {QPut, BinKTV} = MakeQPut(K, TV),
            [] = sql(DB, QPut, BinKTV),
            TV %% For chaining
    end;

table_op(Spec, put_list) ->
    MakeQPut = table_op(Spec, qput),
    table_op(Spec, put_list, MakeQPut);

table_op(Spec, put_list_cond) ->
    MakeQPut = table_op(Spec, qput),
    QLoad = table_op(Spec, qload),
    table_op(Spec, put_list_cond, {MakeQPut, QLoad});

table_op(Spec, put_map) ->
    PutList = table_op(Spec, put_list),
    table_op(Spec, put_map, PutList);

table_op(Spec, put_map_cond) ->
    PutListCond = table_op(Spec, put_list_cond),
    table_op(Spec, put_map_cond, PutListCond);


table_op({table,_,DB,Table}, clear) ->
    QClear = tools:format_binary("delete from '~s'", [table_name(Table)]),
    fun() -> [] = sql(DB, QClear, []), ok end;

table_op({table,_,DB,Table}, remove) ->
    QRemove = tools:format_binary("delete from '~s' where var = ?", [table_name(Table)]),
    fun(Key) ->
            BinKey = type_base:encode_key(Key),
            [] = sql(DB, QRemove, [{'text',BinKey}]), ok
    end.


%% Sharing

table_op({table,_,_,_}, to_map, ToList) ->
    fun() ->
            maps:from_list(ToList())
    end;
table_op({table,_,DB,_}, put_list, MakeQPut) ->
    fun(List) ->
            Queries =
                lists:map(
                  fun({K,V}) -> MakeQPut(K,V) end,
                  List),
            case sql_transaction(DB, Queries) of
                {ok, _} -> ok;
                {error, Error} -> throw({put_list,Error})
            end
    end;
table_op({table,TypeMod,DB,_}, put_list_cond, {MakeQPut,QLoad}) ->
    fun(List,Check) ->
            Queries =
                lists:map(
                  fun({K,V}) -> MakeQPut(K,V) end,
                  List) ++ 
                [QLoad,
                 {check,
                  fun([NewList|_]) ->
                          Check([type_base:decode_ktv(TypeMod, BinKTV)
                                 || BinKTV <- NewList])
                  end}],
            case sql_transaction(DB, Queries) of
                {ok, _} -> ok;
                {error, Error} -> throw({put_list_cond,Error})
            end
    end;
table_op({table,_,_,_}, put_map, PutList) ->
    fun(Map) -> PutList(maps:to_list(Map)) end;
table_op({table,_,_,_}, put_map_cond, PutMapCond) ->
    fun(Map,Check) ->
            ListCheck = fun(L) -> Check(maps:from_list(L)) end,
            PutMapCond(maps:to_list(Map), ListCheck)
    end.


    
                   
%% Implementation based on database table and type_base.erl type conversion.
table({table,TypeMod,DB,Table}=Args) when is_atom(TypeMod) ->
    %% Make sure it exists.
    table_init(DB,Table),
    existing_table(Args).

%% This form has more sharing and caching but creates large closures,
%% which is really noticable in hmac encoding.  See db.erl in hatd web
%% app for lambda-lifted form.
existing_table(Spec) ->
    Find      = table_op(Spec, find),
    ToList    = table_op(Spec, to_list),
    ToMap     = table_op(Spec, to_map, ToList),
    Keys      = table_op(Spec, keys),
    Put       = table_op(Spec, put),
    MakeQPut  = table_op(Spec, qput),
    PutList   = table_op(Spec, put_list, MakeQPut),
    PutMap    = table_op(Spec, put_map, PutList),
    Clear     = table_op(Spec, clear),
    Remove    = table_op(Spec, remove),
    
    {kvstore, 
     fun
         (find)       -> Find;
         (to_list)    -> ToList;
         (to_map)     -> ToMap;
         (keys)       -> Keys;
         (put)        -> Put;
         (put_list)   -> PutList;
         (put_map)    -> PutMap;
         (clear)      -> Clear;
         (remove)     -> Remove
     end}.
                   
%% Ad-hoc key value stores.
table_init(DB,Table) ->
    [] = sql(DB,
             tools:format_binary(
               "create table if not exists '~s' (var, type, val, primary key (var))",
               [table_name(Table)]),
             []).

table_delete(DB, Table) ->
    sql(DB,
        tools:format_binary(
          "drop table if exists '~s'",
          [table_name(Table)]),

        []).

table_name(Table) when is_atom(Table) ->
    atom_to_list(Table);
table_name({Table,Nb}) when is_atom(Table) and is_integer(Nb) ->
    io_lib:format("{~p,~p}",[Table,Nb]).

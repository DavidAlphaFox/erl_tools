-module(expect).
-export([load_form/1, update_form/3, update_form/2, save_form/2,
         print_diff/2, diff_form/3, run_form/2]).

%% Inspired by: https://blog.janestreet.com/testing-with-expectations/
%% Main idea:
%% - Make it trivial to add a test
%% - Diff of the expect file indicates change of meaning / error
%% - A committed diff indicates accepted change of meaning

%% See readme_expect.expect and readme_expect.erl for an example.


%% Syntax: single thunk, containing a single clause, containing a
%% single Term which is an assoc list from expressions to terms.
load_form(FileName) ->
    case file:read_file(FileName) of
        {ok, Bin} ->
            Str = tools:format("~s",[Bin]),
            {ok, Toks, _} = erl_scan:string(Str),
            {ok, Form} = erl_parse:parse_form(Toks),
            unpack(Form);
        Error ->
            throw({expect_load_form, FileName, Error})
    end.

%% Some ad-hoc formatting.  Can't figure out how to have
%% erl_prettypr:format display strings and binaries in a readable way.
save_form(FileName, {FunName, Triplets}) ->
    ok = file:write_file(
           FileName,
           ["%% -*- erlang -*-\n",
            atom_to_list(FunName),"() ->\n[\n",
            join(",\n", [format_test(T) || T <- Triplets]),
            "].\n"]).

format_test({Form,OldVal,NewVal}) ->
    Inner = 
        case OldVal == NewVal of
            true ->
                [", %% =>\n", format_val(NewVal)];
            false ->
                [", %% expected =>\n", format_val(OldVal), "\n",
                 ", %% found =>\n",    format_val(NewVal)]
        end,
    ["{ ",
     ["%" || _ <- lists:seq(1,78)],
     "\n",
     erl_prettypr:format(Form),
     "\n",
     Inner,
     "\n}\n"].
    


%% Compat with older version.
%% join(Lists,Sep) -> lists:join(Lists,Sep).
join(_, []) -> [];
join(Sep, [First | Els]) -> [First, [[Sep,El] || El <- Els]]. 
    
    

%% Value needs to be parsable, e.g. Can't have #Fun<...>.
%% See type_base.erl for similar code.
format_val(Val) ->
    ValFmt = tools:format_binary("~70p",[Val]),
    try
        Val = type_base:decode({pterm, ValFmt}),
        ValFmt
    catch 
        _:_ -> 
            [[["%% ", Line, "\n"] || Line <- re:split(ValFmt,"\n")],
             "not_printable"]
    end.



%% save_form(FileName, Form) ->
%%     Str = erl_prettypr:format(pack(Form)),
%%     ok = file:write_file(
%%            FileName,
%%            ["%% -*- erlang -*-\n", Str]).
      
%% Full file.    
unpack(
  {function,_,FunName,0,
   [{clause,_,[],[],
     [Term]}]}) ->
    {FunName, unpack_list(Term)}.
%% Unpack the assoc list, parsing the second element in the pair but
%% leaving the first intact.  Third and subsequent tuple elements are
%% ignored.  The third element is used to store error messages in case
%% a test fails.
unpack_list({nil,_}) -> [];
unpack_list({cons,_,{tuple,_,[Expr,Term|_]},Tail}) ->
    [{Expr,erl_parse:normalise(Term)} | unpack_list(Tail)].

%% pack({FunName,List}) ->
%%     {function,0,FunName,0,
%%      [{clause,0,[],[],
%%        [pack_list(List)]}]}.
%% pack_list([]) -> {nil,0};
%% pack_list([{Expr,Term}|Tail]) -> 
%%     {cons,0,{tuple,0,[Expr,erl_parse:abstract(Term)]},
%%      pack_list(Tail)}.
                 
                 
    
%% Check an evaluated form with the previous values, and write it
%% back.
update_form(FileIn,
            FileOut,
            TestPairsOrTriplets) ->
    {Name, Old} = load_form(FileIn),
    {Forms, OldVals} = lists:unzip(Old),
    Thunks = 
        lists:map(
          fun({Thunk,_,_}) -> Thunk;
             ({Thunk,_}) -> Thunk end,
          TestPairsOrTriplets),
    NewVals = [catch Thunk() || Thunk <- Thunks],
    New = lists:zip3(Forms, OldVals, NewVals),
    save_form(FileOut, {Name, New}),
    {Forms,NewVals,OldVals}.


run_form(FileName, TestThunk) ->
    {Forms,NewVals,OldVals} = update_form(FileName, TestThunk()),
    Diff = expect:diff_form(Forms, OldVals, NewVals),
    expect:print_diff(FileName, Diff),
    case Diff of
        [] -> ok;
        _ -> throw({expect_failed,
                    filename:basename(FileName)})
    end.
    
    

diff_form(Forms, OldVals, NewVals) ->
    %% Return diff.
    lists:append(
      lists:map(
        fun({_,{OldVal,NewVal}}=Test) ->
                case NewVal of
                    OldVal -> [];
                    _ -> [Test]
                end
        end,
        lists:zip(Forms, lists:zip(OldVals, NewVals)))).

print_diff(FileName, Diff) ->
    lists:foreach(
      fun({Form,{Old,New}}) ->
              io:format(
                "~s:~p: ~s~n- ~p~n+ ~p~n",
                [FileName,
                 erl_syntax:get_pos(Form),
                 erl_prettypr:format(Form),
                 Old,
                 New])
      end,
      Diff).

update_form(FileIn, TestResults) ->
    update_form(FileIn, FileIn ++ ".new", TestResults).


%% expect:check_form("/home/tom/src/scope_display:expect_tests().

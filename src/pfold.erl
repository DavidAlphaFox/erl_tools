%% Sequences as Partial Folds
%% --------------------------

%% http://okmij.org/ftp/papers/LL3-collections-enumerators.txt
%% Extension to fold.erl

%% The early stop protocol expects these return values from the foldee:
%%   {next,  State}       Proceed normally
%%   {stop, FinalState}  Stop iteration, return value
%%


%% FIXME: making the folds lazy will add an additional layer of
%% indirection, e.g. making append simpler.

-module(pfold).
-export([range/1,
         append/2, append/1,
         to_list/1, to_rlist/1,
         to_list/2, to_rlist/2,
         take/2,
         next/1,
         with_stop_exit/1,
         nchunks/3,
         map/2
        ]).
         
-export_type([update/1, chunk/0, sink/0, control/1, seq/0]).
-type control(State) :: {next, State} | {stop, State}.
-type update(State) :: fun((any(), State) -> control(State)).
-type chunk() :: {data, any()} | eof.
-type sink() :: fun((chunk()) -> any()).
-type seq() :: fun((update(State), State) -> State).

%% Wrap an ordinary foldee so it can be used with a folder that
%% expects the early stop protocol, by not stoping.
next(F) -> fun(E,S) -> {next, F(E,S)} end.
    

range(F,State,N,I) ->
    case I < N of
        true ->
            case F(I,State) of
                {next, NextState} -> range(F,NextState,N,I+1);
                {stop, FinalState} -> FinalState
            end;
        false ->
            State
    end.
range(N) -> fun(F,S) -> range(F,S,N,0) end.



%% Perform fold, and annotate return value with finished/stopped.
%% Used to support append.
tag_stop(S,F,I) ->
    S(fun(El, {Tag, State}) ->
              case F(El, State) of
                  {stop, FinalState} -> {stop, {stopped, FinalState}};
                  {next, NextState}  -> {next, {Tag, NextState}}
              end
      end, {finished, I}).

append(S1, S2)  ->
    fun(F, I1) -> 
            case tag_stop(S1, F, I1) of 
                {finished, I2} -> 
                    S2(F, I2);
                {stopped, F2} ->
                    %% S2 might contain cleanup code so we do need to
                    %% run it.  (Folds are one-shot, not lazy).  Can
                    %% there be side-effects?
                    S2(fun(_, _) -> {stop, none} end, none),
                    F2
            end
    end.
append([]) ->
    fold:empty();
append([S1|S2]) ->
    append(S1, append(S2)).

all(_) -> next.
    

to_rlist(SF,NextOrStop) -> SF(fun(E,S)->{NextOrStop(E), [E|S]} end, []).
to_rlist(SF) -> to_rlist(SF, fun all/1).

to_list(SF,NextOrStop) -> lists:reverse(to_rlist(SF,NextOrStop)).
to_list(SF) -> to_list(SF, fun all/1).

    

take(SF, MaxNb) ->
    fun(F, I) ->
            {_, FinalState} =
                SF(fun(El, {Count, State} = CS) ->
                           case Count >= MaxNb of 
                               true  -> {stop, CS};
                               false -> {Tag, NextState} = F(El, State),
                                        {Tag, {Count + 1, NextState}}
                           end
                   end,
                   {0, I}),
            FinalState
    end.
    
%% pfold:to_list(pfold:take(pfold:append(pfold:range(10), pfold:range(10)), 4)).

%% Take a fold.erl fold, and wrap it as a pfold.erl fold which raises
%% an error on exit.
with_stop_exit(Fold) ->
    fun(F,I) ->
            Fold(
              fun(E,S) ->
                      case F(E,S) of
                          {next, S} -> S;
                          {stop, S} -> exit({stop, S})
                      end
              end,
              I)
    end.


%% pfold version of tools:nchunks/3
nchunks(Offset, Endx, Max) ->
    fun(F,S) -> nchunks(Offset, Endx, Max, F, S) end.
nchunks(Offset, Endx, Max, Fun, State) ->
    case Offset of
        Endx -> State;
        _ ->
            Left = Endx - Offset,
            ChunkSize = case Left > Max of true  -> Max; false -> Left end,
            case Fun({Offset, ChunkSize}, State) of
                {stop, LastState} ->
                    LastState;
                {next, NextState} ->
                    nchunks(Offset + ChunkSize, Endx, Max, Fun, NextState)
            end
    end.
            
%% The function to be mapped is pure.  It doesn't seem to make sense
%% to have this also return next/stop.
map(MapFun, Fold) ->
    fun(FoldFun, Init) -> map(MapFun, Fold, FoldFun, Init) end.
map(MapFun, Fold, FoldFun, Init) ->
    Fold(
      fun(Element, State) ->
              FoldFun(
                MapFun(Element),
                State)
      end, Init).
                 

                 

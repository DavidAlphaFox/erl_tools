-module(recorder).
-export([start_link/1, handle/2,
         num_to_filename/2, dir_chunks/1
         ]).

%% Generic circular message stream recorder.

%% Remarks
%% - Rate limiter is best done at source
%% - Also write index file.  But this can be re-generated by reader.
%% - keep file chunks reasonable.  at least <4GB to allow for 32-bit memmap
%% - implement circular buffer at file chunk level
%% - Always create new files on startup.  This avoids any issues that
%%   might pop up due to inconsistencies related to crashes.
%% - Data is ETF, pre- and postfixed using 32-bit BE size, so it can
%%   can be streamed forwards and backwards.


open(FileName) ->
    file:open(FileName, [raw,append,delayed_write]).

start_link(Init) ->
    {ok,
     serv:start(
       {handler,
        fun() -> handle(newfile, Init) end,
        fun recorder:handle/2})}.

handle(newfile, #{ dir := Dir, nb_chunks := NbChunks }=State) ->
    {New, Old} = new_chunk(Dir),

    %% Prune circular buffer
    case length(Old) > NbChunks of
        false -> ok;
        true ->
            lists:foreach(
              fun(N) ->
                      lists:foreach(
                        fun(Tag) ->
                                FN = Dir ++ num_to_filename(Tag, N),
                                log:info("recorder: del: ~s~n", [FN]),
                                file:delete(FN)
                        end,
                        [index, data])
              end,
              lists:nthtail(NbChunks, Old))
    end,
    
    %% TotalSize = 
    %%     lists:foldl(
    %%       fun(N,Acc) ->
    %%               Size = filelib:file_size(Dir ++ num_to_filename(N)),
    %%               Acc + Size
    %%       end,
    %%       0, Old),
    %% log:info("recorder: current size: ~p~n", [TotalSize]),


    try
        TaggedFiles =
            lists:map(
              fun(Tag) ->
                      FileName = Dir ++ num_to_filename(Tag, New),
                      log:info("recorder: new: ~s~n", [FileName]),
                      case open(FileName) of
                          {ok, File} ->
                              {Tag, File};
                          Error ->
                              throw({open_error, {Tag, FileName, Error}})
                      end
              end,
              [index, data]),
        
        maps:merge(
          State,
          maps:from_list(TaggedFiles))
    catch
        {open_error,_}=Error ->
            log:info("WARNING: recorder: ~999p~n", [Error]),
            %% Something is wrong with the file system.  This will
            %% need operator intervention.
            timer:sleep(5000),
            handle(newfile, State)
    end;

%% For debug
handle({_,dump}=Msg, State) ->
    obj:handle(Msg, State);

%% Any other message gets logged.
handle(Msg, #{ data := DataFile, 
               index := IndexFile,
               chunk_size := SizeMax } = State) ->

    Term = {erlang:timestamp(), Msg},
    Bin = term_to_binary(Term),
    Size = size(Bin),
    Packet = [<<Size:32>>,Bin,<<Size:32>>],
    {ok, Pos} = file:position(DataFile, cur),
    
    case Pos+8+Size > SizeMax of
        false ->
            ok = file:write(DataFile, Packet),
            ok = file:write(IndexFile, <<Pos: 32/little>>),
            State;
        true ->
            _ = file:close(DataFile),
            _ = file:close(IndexFile),
            #{ data  := NewDataFile,
               index := NewIndexFile} 
                = State1 = handle(newfile, State),
            ok = file:write(NewDataFile, Packet),
            ok = file:write(NewIndexFile, <<0: 32/little>>),
            State1
    end.

num_to_filename(Tag, N) when is_atom(Tag) and is_number(N) -> 
    tools:format("~p.~p",[Tag, N]).

filename_to_num(Filename) ->
    case re:split(Filename,"\\.") of
        [<<"data">>,Index] ->
            try {ok, binary_to_integer(Index)}
            catch C:E -> {error,{Index,{C,E}}}
            end;
        Other ->
            {error, Other}
    end.

dir_chunks(Dir) ->
    {ok, AllFiles} = file:list_dir(Dir),
    lists:sort(
      [N || {ok, N} <- 
                lists:map(
                  fun filename_to_num/1,
                  AllFiles)]).
    

new_chunk(Dir) ->
    Datas = lists:reverse(dir_chunks(Dir)),
    {case Datas of
           []    -> 0;
           [N|_] -> N+1
     end,
     Datas}.


%% calendar:now_to_universal_time(erlang:timestamp()).
%% calendar:now_to_local_time(erlang:timestamp()).
%% {{2019,2,10},{20,6,22}}









-module(zip_stream).
-export([test/1,init/1,cmd/2,cmds/2
        %% ,read_file_info/1, read_all_file_info/1
         
        ]).

%% Bare-bones streaming zip file creation.
%% - Only supports STORE (no compression)
%% - Uses data descriptors to support unknown file sizes

%% Caveats:
%% - Empty files are not supported.


%% Some information about the zip file format
%% https://users.cs.jmu.edu/buchhofp/forensics/formats/pkzip.html#datadescriptor
%% https://en.wikipedia.org/wiki/Zip_(file_format)

%% Note that sink return values are asserted to be 'ok'.  If this
%% fails, the entire zip file creation fails, so it needs to be
%% handled in the code that calls cmd/2.

%% STATE MACHINE

%% Push data into the output stream.
cmd({data, Bytes},
    #{ out    := Out,
       offset := Offset } = State) when
      is_binary(Bytes) ->
    Out1 =
        case Out of
            {iolist, IOL} -> 
                %% For testing.  Typically {sink,_} is used for
                %% production code.
                {iolist, [IOL,Bytes]};
            {sink, Sink} ->
                %% See sink.erl for protocol and conversions.
                ok = Sink({data, Bytes}),
                Out
        end,
    maps:merge(
      State,
      #{ out    => Out1,
         offset => Offset + size(Bytes) });

%% Append will keep track of size and incrementally compute CRC32.
cmd({append, #{ name := Name, data := Data }}, State0) ->
    Files0 = maps:get(files, State0),
    Info0  = #{ crc32 := CRC32, size := Size } = maps:get(Name, Files0),
    Info1 =
        maps:merge(
          Info0,
          #{ crc32 => erlang:crc32(CRC32, Data),
             size  => Size + size(Data) }),
    State1 =
        maps:put(files,
                 maps:put(Name, Info1, Files0),
                 State0),
    cmd({data, Data}, 
        %% Ref is no longer needed in state.
        maps:remove(data, State1));

%% Also support fold, pfold over binary chunks.
cmd({append, #{ name := Name, fold := Fold }}, State0) ->
    Fold(
      fun(Bin, State) ->
              Info = #{ name => Name, data => Bin },
              cmd({append, Info}, State)
      end, State0);
cmd({append, #{ name := Name, pfold := Fold }}, State0) ->
    Fold(
      fun(Bin, State) ->
              Info = #{ name => Name, data => Bin },
              {next, cmd({append, Info}, State)}
      end, State0);

cmd({local_file_header, 
     #{ name   := Name } = FileInfo},
    #{ offset := Offset,
       files  := Files } = State) when
      is_binary(Name) ->
    Files1 =
      maps:put(
        Name,
        #{ crc32 => 0,
           size => 0,
           offset => Offset },
        Files),
    Header = local_file_header(FileInfo),
    State1 = 
        maps:merge(
          State,
          #{ files => Files1 }),
    cmd({data, Header}, State1);

%% FIXME: Empty files seem to generate corrupt ZIP files.  How to
%% handle?  Maybe just rewrite the header without data descriptor bit?
cmd({data_descriptor, #{ name   := Name }},
    #{ files  := Files } = State) ->
    Info = maps:get(Name, Files),
    Header = data_descriptor(Info),
    cmd({data, Header}, State);

cmd(central_directory,
    #{ out := Out, files := Files, offset := CDROffset} = State) ->
    FilesL = maps:to_list(Files),
    State1 = #{ offset := CDREndx } =
        lists:foldl(
          fun({File, #{ size   := Size,
                        crc32  := CRC32,
                        offset := FileOffset }}, S) ->
                  CDR = 
                      central_directory_record(
                        #{ name => File,
                           crc32 => CRC32,
                           size => Size,
                           offset => FileOffset }),
                  cmd({data, CDR}, S)
          end,
          State,
          FilesL),
    EOCD = end_of_central_directory(
          #{ nb_entries => length(FilesL),
             offset => CDROffset, 
             size => CDREndx - CDROffset }),
    State2 = cmd({data, EOCD}, State1),
    case Out of
        {sink, Sink} -> ok = Sink(eof);
        _ -> ok
    end,
    State2;

%% Composite command.
cmd({file, Info}, State) ->
    cmds([{local_file_header, Info},
          {append, Info},
          {data_descriptor, Info}],
         State).

cmds(List, State) ->
    lists:foldl(fun cmd/2, State, List).


init(iolist) -> init({iolist,[]});
init(Out) -> #{ offset => 0, files => #{}, out => Out }.


%% RECORDS


end_of_central_directory(
  #{ nb_entries := TotalEntries,
     offset := CentralDirOffset, 
     size := CentralDirSize }) ->
    <<16#504b0506: 32, %% Sig
      0: 16/little, %% Disk
      0: 16/little, %% DiskCD
      TotalEntries: 16/little, %% DiskEntries
      TotalEntries: 16/little, %% TotalEntries
      CentralDirSize: 32/little,
      CentralDirOffset: 32/little,
      0: 16/little>>. %% CommentLen

central_directory_record(
  #{ name   := FileName,
     size   := Size,
     crc32  := CRC32,
     offset := LocalHeaderOffset 
   } = Info) ->
    ModTime = maps:get(mod_time, Info, 0),
    ModDate = maps:get(mod_date, Info, 0),
    FileNameLen = size(FileName),
    <<16#504b0102: 32, %% Sig
      20: 16/little, %% Ver
      20: 16/little, %% VerNeed
      8: 16/little, %% Flags: data descriptor
      0: 16/little, %% Comp
      ModTime: 16/little,
      ModDate: 16/little,
      CRC32: 32/little,
      Size: 32/little, %% USize
      Size: 32/little, %% CSize
      FileNameLen: 16/little,
      0: 16/little, %% ExtraFieldLen
      0: 16/little, %% FileCommLen
      0: 16/little, %% DiskStart
      0: 16/little, %% InternalAttr
      0: 32/little, %% ExternalAttr
      LocalHeaderOffset: 32/little,
      FileName/binary>>.

local_file_header(
  #{ name := FileName } = Info) when 
      is_binary(FileName) ->
    Size = 0,
    CRC32 = 0,
    %% CRC32 = maps:get(crc32, Info, 0),
    ModTime = maps:get(mod_time, Info, 0),
    ModDate = maps:get(mod_date, Info, 0),
    FileNameLen = size(FileName),
    <<16#504b0304:32, %% Sig
      20:16/little, %% Ver
      8:16/little, %% Flags: data descriptor
      0:16/little, %% Compression
      ModTime:16/little,
      ModDate:16/little,
      CRC32:32/little, %% CRC32
      Size:32/little, %% CSize
      Size:32/little, %% USize
      FileNameLen:16/little,
      0:16/little, %% ExtraFieldLen
      FileName/binary>>.

data_descriptor(
  #{ crc32 := CRC32,
     size  := Size }) ->
    <<16#504b0708:32, %% Sig  (optional)
      CRC32:32/little,
      Size:32/little,   %% CSize
      Size:32/little>>. %% USize




%% TESTS
      
%% zip_stream:test({simple,"/tmp/test.zip"}).      
test({simple,Zip}) ->
    Bin = <<"This is a DOS text file\r\n">>,
    # { out := {iolist, IOL} }
        = cmds(
            [{file, #{ name => <<"test1.txt">>, data => Bin }}
            ,{file, #{ name => <<"test2.txt">>, data => Bin }}
            ,central_directory],
            init(iolist)
           ),
    file:write_file(Zip, IOL);
test({appends,Zip}) ->
    Name = <<"test1.txt">>,
    Bin = <<"This is a DOS text file\r\n">>,
    # { out := {iolist, IOL} }
        = cmds(
            [{local_file_header, #{ name => Name }},
             {append, #{ name => Name, data => Bin}},
             {append, #{ name => Name, data => Bin}},
             {append, #{ name => Name, data => Bin}},
             {data_descriptor, #{ name => Name }},
             central_directory],
            init(iolist)),
    file:write_file(Zip, IOL);
test({write,Zip}) ->
    _ = file:delete(Zip),
    Bin = <<"This is a DOS text file\r\n">>,
    {ok, F} = file:open(Zip, [append]),
    _ =  cmds(
           [{file, #{ name => <<"test1.txt">>, data => Bin }}
           ,{file, #{ name => <<"test2.txt">>, data => Bin }}
           ,central_directory],
           init({sink,
                 fun({data,Data}) ->
                         %% log:info("write: ~p~n", [Data]),
                         file:write(F, Data);
                    (eof) ->
                         file:close(F)
                 end})),
    ok. 


%% The ZIP format is actually quite useful as a mmap store for large
%% files, e.g. a sound sample bank.  Some hacks:
%%
%% - ignore the central directory internally.  just leave it in for
%%   external tools to recover the file store.
%%
%% - the central directory can be re-generated by scanning the file.
%%
%% - the only important record is the local file header, which is 28
%%   bytes + file name + data.  data can be kept aligned by padding
%%   the file name.


%% FIXME: This doesn't work because the file sizes are not known.
%% Central directory is needed.  Also, this needs a 64 bit zip file to
%% be useful.

%% read_file_info(F) ->
%%     {ok, Pos} = file:position(F, cur),
%%     {ok, LocalFileHeader} = file:read(F, 28),
%%     case LocalFileHeader of

%%         <<16#504b0304:32,     %% Sig
%%           20:16/little,       %% Ver
%%           8:16/little,        %% Flags: data descriptor (8)
%%           0:16/little,        %% No Compression
%%           _ModTime:16/little,
%%           _ModDate:16/little,
%%           0:32/little,        %% CRC32
%%           Size:32/little,     %% CSize
%%           Size:32/little,     %% USize
%%           FileNameLen:16/little>> ->

%%             {ok, FileName} = file:read(F, FileNameLen),
%%             {ok, _} = file:position(F, {cur, Size}),
%%             {ok, DataDescriptor} = file:read(F, 16),

%%             <<16#504b0708:32,   %% Sig
%%               _CRC32:32/little,
%%               Size:32/little,   %% CSize
%%               Size:32/little>>  %% USize
%%                 = DataDescriptor,

%%             {ok, {Pos, FileName, Size}};

%%         _ ->
%%             %% No more local file headers
%%             {ok, _} = file:position(F, Pos),
%%             {error, Pos}
%%     end.
%% read_all_file_info(F) ->
%%     read_all_file_info(F,[]).
%% read_all_file_info(F,Acc) ->
%%     case read_file_info(F) of
%%         {error, Pos} -> {Pos, Acc};
%%         {ok, Info} -> read_all_file_info(F, [Info|Acc])
%%     end.
             


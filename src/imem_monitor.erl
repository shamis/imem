-module(imem_monitor).

-include("imem.hrl").
-include("imem_meta.hrl").

%% HARD CODED CONFIGURATIONS

-define(MONITOR_TABLE_OPTS,[{record_name,ddMonitor}
                           ,{type,ordered_set}
                           ,{purge_delay,430000}        %% 430000 = 5 Days - 2000 sec
                           ]).  

%% DEFAULT CONFIGURATIONS ( overridden in table ddConfig)

-define(BIN(__Code), <<??__Code>>).
-define(GET_MONITOR_CYCLE_WAIT,?GET_CONFIG(monitorCycleWait,[],10000,"Wait time between monitor cycles in msec")).
-define(GET_MONITOR_EXTRA,?GET_CONFIG(monitorExtra,[],true,"Does monitor call an Extra function to augment the monitored status data?")).
-define(GET_MONITOR_EXTRA_FUN,
    ?GET_CONFIG(monitorExtraFun, [], ?BIN(
        fun(Row) ->
            {_, FreeMemory, TotalMemory} = imem:get_os_memory(),
            MemFreePerCent = 1.0e-2 * erlang:round(10000 * FreeMemory / TotalMemory),
            {_, VOutMem} = imem:get_vm_memory(),
            #{free_virtual_memory := FreeVirtualMemory,
                total_virtual_memory := TotalVirtualMemory} = imem:get_virtual_memory(),
            VInMem = element(4, Row),
            [{mem_diff, VOutMem - VInMem},
            {mem_free_pct, MemFreePerCent},
            {vm_process_mem, VOutMem},
            {data_nodes, length(imem_meta:data_nodes())},
            {free_virtual_memory, FreeVirtualMemory},
            {total_virtual_memory, TotalVirtualMemory}]
        end), "Function which can be called in every monitor cycle to augment the monitor data.")).
-define(GET_MONITOR_DUMP,?GET_CONFIG(monitorDump,[],true,"Should the monitor status be written to a file on disk?")).
-define(GET_MONITOR_DUMP_FUN,?GET_CONFIG(monitorDumpFun,[],<<"">>,"Function used to dump the monitor data to disk.")).


-behavior(gen_server).

-record(state, { extraFun = undefined       :: any()
               , extraHash = undefined      :: any()
               , dumpFun = undefined        :: any()
               , dumpHash = undefined       :: any()
               }
       ).

-export([ start_link/1
        ]).

% gen_server interface (monitoring calling processes)

% gen_server behavior callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        , format_status/2
        ]).

-export([ write_monitor/0
        , write_monitor/2
        , write_dump_log/3
        ]).

-safe(write_dump_log/3).

start_link(Params) ->
    ?Info("~p starting...~n", [?MODULE]),
    case gen_server:start_link({local, ?MODULE}, ?MODULE, Params, [{spawn_opt, [{fullsweep_after, 0}]}]) of
        {ok, _} = Success ->
            ?Info("~p started!~n", [?MODULE]),
            Success;
        Error ->
            ?Error("~p failed to start ~p~n", [?MODULE, Error]),
            Error
    end.

init(_Args) ->
    try
        catch imem_meta:create_check_table(?MONITOR_TABLE, {record_info(fields, ddMonitor),?ddMonitor, #ddMonitor{}}, ?MONITOR_TABLE_OPTS, system),    
        erlang:send_after(2000, self(), imem_monitor_loop),

        process_flag(trap_exit, true),
        {ok,#state{}}
    catch
        _Class:Reason -> {stop, {Reason,erlang:get_stacktrace()}} 
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%     {stop,{shutdown,Reason},State};
% handle_cast({stop, Reason}, State) ->
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(imem_monitor_loop, #state{extraFun=ExtraFun, extraHash=ExtraHash,
                                      dumpFun=DumpFun, dumpHash=DumpHash} = State) ->
    % save one imem_monitor record and trigger the next one
    % ?Debug("imem_monitor_loop start~n",[]),
    case ?GET_MONITOR_CYCLE_WAIT of
        MCW when (is_integer(MCW) andalso (MCW >= 100)) ->
            {EHash, EFun} = get_mon_fun(extra, ExtraFun, ExtraHash),
            {DHash, DFun} = get_mon_fun(dump, DumpFun, DumpHash),
            write_monitor(EFun,DFun),
            erlang:send_after(MCW, self(), imem_monitor_loop),
            {noreply, State#state{extraFun=EFun,extraHash=EHash,dumpFun=DFun,dumpHash=DHash}};
        _ ->
            ?Warn("running idle monitor with default timer ~p", [2000]),
            erlang:send_after(2000, self(), imem_monitor_loop),
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(normal, _State) -> ?Info("~p normal stop~n", [?MODULE]);
terminate(shutdown, _State) -> ?Info("~p shutdown~n", [?MODULE]);
terminate({shutdown, _Term}, _State) -> ?Info("~p shutdown : ~p~n", [?MODULE, _Term]);
terminate(Reason, _State) -> ?Error("~p stopping unexpectedly : ~p~n", [?MODULE, Reason]).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

format_status(_Opt, [_PDict, _State]) -> ok.


%% ------ MONITOR implementation -------------------------------------------------------

get_mon_fun(extra, Fun, Hash) ->
    get_mon_fun({extra, ?GET_MONITOR_EXTRA}, Fun, Hash);
get_mon_fun({extra, true}, Fun, Hash) ->
    get_mon_fun(?GET_MONITOR_EXTRA_FUN, Fun, Hash);
get_mon_fun(dump, Fun, Hash) ->
    get_mon_fun({dump, ?GET_MONITOR_DUMP}, Fun, Hash);
get_mon_fun({dump, true}, Fun, Hash) ->
    get_mon_fun(?GET_MONITOR_DUMP_FUN, Fun, Hash);
get_mon_fun({_, false}, _, _) -> {undefined, undefined};
get_mon_fun(<<>>, _, _) -> {undefined, undefined};
get_mon_fun(FunStr, Fun, Hash) ->
    case erlang:phash2(FunStr) of
        Hash ->     {Hash, Fun};
        NewHash ->  {NewHash, imem_compiler:compile(FunStr)}
    end.

write_monitor() -> write_monitor(undefined,undefined).

write_monitor(ExtraFun,DumpFun) ->
    try  
        {{input,Input},{output,Output}} = erlang:statistics(io),
        Moni0 = #ddMonitor{ time=?TIME_UID
                          , node=node()
                          , memory=erlang:memory(total)
                          , process_count=erlang:system_info(process_count)          
                          , port_count=erlang:system_info(port_count)
                          , run_queue=erlang:statistics(run_queue)
                          , wall_clock=element(1,erlang:statistics(wall_clock))
                          , reductions=element(1,erlang:statistics(reductions))
                          , input_io=Input
                          , output_io=Output
                          },
        Moni1 = case ExtraFun of
            undefined -> 
                Moni0;
            ExtraFun -> 
                try
                    Moni0#ddMonitor{extra=ExtraFun(Moni0)}
                catch 
                    _:ExtraError ->
                        ?Error("cannot monitor ~p : ~p", [ExtraError, erlang:get_stacktrace()]),
                        Moni0
                end
        end,
        imem_meta:dirty_write(?MONITOR_TABLE, Moni1),
        case DumpFun of
            undefined -> 
                ok;
            DumpFun ->
                try 
                    DumpFun(Moni1)
                catch
                    _ : DumpError -> ?Error("cannot dump monitor ~p", [DumpError])
                end
        end
    catch
        _:Err ->
            ?Error("cannot monitor ~p: ~p", [Err, erlang:get_stacktrace()]),
            {error,{"cannot monitor",Err}}
    end.

write_dump_log(File, Format, Args) ->
    case application:get_env(lager, crash_log) of
        undefined -> ?ClientError("Unable to determine log folder path");
        {ok, CrashLogFile} ->
            LogPathParts = filename:split(CrashLogFile),
            LogPath = filename:join(lists:sublist(LogPathParts,
                                                  length(LogPathParts) - 1)),
            file:write_file(
              filename:join(LogPath, File),
              list_to_binary(lists:flatten(io_lib:format(Format, Args))))
    end.

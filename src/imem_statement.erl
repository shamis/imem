-module(imem_statement).

-define(VALID_FETCH_OPTS, [fetch_mode, tail_mode, params]).

-include("imem_seco.hrl").
-include("imem_sql.hrl").

%% gen_server
-behaviour(gen_server).
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-export([ update_prepare/5          %% stateless creation of update plan from change list
        , update_cursor_prepare/4   %% stateful creation of update plan (stored in state)
        , update_cursor_execute/4   %% stateful execution of update plan (fetch aborted first)
        , filter_and_sort/5         %% apply FilterSpec and SortSpec and return new SQL and SortFun
        , filter_and_sort/6         %% apply FilterSpec and SortSpec and return new SQL and SortFun
        , fetch_recs/5              %% simulation of synchronous fetch
        , fetch_recs_sort/5         %% simulation of synchronous fetch followed by a lists:sort
        , fetch_recs_async/4        %% async streaming fetch
        , fetch_recs_async/5        %% async streaming fetch with options ({tail_mode,)
        , fetch_close/3
        , close/2
        ]).

-export([ create_stmt/3
        , receive_raw/0
        , receive_raw/1
        , receive_recs/2
        , receive_recs/3
        , recs_sort/2
        , result_tuples/2
        ]).


-record(fetchCtx,               %% state for fetch process
                    { pid       ::pid()
                    , monref    ::any()             %% fetch monitor ref
                    , status    ::atom()            %% undefined | waiting | fetching | done | tailing | aborted
                    , metarec   ::tuple()
                    , blockSize=100 ::integer()     %% could be adaptive
                    , rownum    ::undefined|integer %% next rownum to be used, if any, element(1,MetaRec)
                    , remaining=0   ::integer()     %% rows remaining to be fetched. initialized to Limit and decremented
                    , opts = [] ::list()            %% fetch options like {tail_mode,true}
                    , tailSpec  ::any()             %% compiled matchspec for master table condition (bound with MetaRec) 
                    , filter    ::any()             %% filter specification {Guard,Binds}
                    , recName   ::atom()
                    }).

-record(state,                  %% state for statment process, including fetch subprocess
                    { statement
                    , isSec =false          :: boolean()
                    , seco=none             :: integer()
                    , fetchCtx=#fetchCtx{}         
                    , reply                                 %% reply destination TCP socket or Pid
                    , updPlan = []          :: list()       %% bulk execution plan (table updates/inserts/deletes)
                    }).

%% gen_server -----------------------------------------------------

create_stmt(Statement, SKey, IsSec) ->
    case IsSec of
        false -> 
            gen_server:start(?MODULE, [Statement], [{spawn_opt, [{fullsweep_after, 0}]}]);
        true ->
            {ok, Pid} = gen_server:start(?MODULE, [Statement], []),            
            NewSKey = imem_sec:clone_seco(SKey, Pid),
            ok = gen_server:call(Pid, {set_seco, NewSKey}),
            {ok, Pid}
    end.

fetch_recs(SKey, Pid, Sock, Timeout, IsSec) ->
    fetch_recs(SKey, Pid, Sock, Timeout, [], IsSec).


fetch_recs(SKey, #stmtResult{stmtRef=Pid}, Sock, Timeout, Opts, IsSec) ->
    fetch_recs(SKey, Pid, Sock, Timeout, Opts, IsSec);
fetch_recs(SKey, Pid, Sock, Timeout, Opts, IsSec) when is_pid(Pid) ->
    gen_server:cast(Pid, {fetch_recs_async, IsSec, SKey, Sock, Opts}),
    Result = try
        case receive 
            R ->    R
        after Timeout ->
            ?Debug("fetch_recs timeout ~p~n", [Timeout]),
            gen_server:call(Pid, {fetch_close, IsSec, SKey}), 
            ?ClientError({"Fetch timeout, increase timeout and retry",Timeout})
        end of
            {_, {Pid,{List, true}}} ->   List;
            {_, {Pid,{List, false}}} ->  
                ?Debug("fetch_recs too much data~n", []),
                gen_server:call(Pid, {fetch_close, IsSec, SKey}), 
                ?ClientError({"Too much data, increase block size or receive in streaming mode",length(List)});
            {_, {Pid,{error, {'SystemException', Reason}}}} ->
                ?Debug("fetch_recs exception ~p ~p~n", ['SystemException', Reason]),
                gen_server:call(Pid, {fetch_close, IsSec, SKey}),                
                ?SystemException(Reason);            
            {_, {Pid,{error, {'ClientError', Reason}}}} ->
                ?Debug("fetch_recs exception ~p ~p~n", ['ClientError', Reason]),
                gen_server:call(Pid, {fetch_close, IsSec, SKey}),                
                ?ClientError(Reason);            
            {_, {Pid,{error, {'ClientError', Reason}}}} ->
                ?Debug("fetch_recs exception ~p ~p~n", ['ClientError', Reason]),
                gen_server:call(Pid, {fetch_close, IsSec, SKey}),                
                ?ClientError(Reason);
            Error ->
                ?Debug("fetch_recs bad async receive~n~p~n", [Error]),
                gen_server:call(Pid, {fetch_close, IsSec, SKey}),                
                ?SystemException({"Bad async receive",Error})            
        end
    after
        gen_server:call(Pid, {fetch_close, IsSec, SKey})
    end,
    Result.


fetch_recs_sort(SKey, #stmtResult{stmtRef=Pid,sortFun=SortFun}, Sock, Timeout, IsSec) ->
    recs_sort(fetch_recs(SKey, Pid, Sock, Timeout, IsSec), SortFun);
fetch_recs_sort(SKey, Pid, Sock, Timeout, IsSec) when is_pid(Pid) ->
    lists:sort(fetch_recs(SKey, Pid, Sock, Timeout, IsSec)).

recs_sort(Recs, SortFun) ->
    % ?LogDebug("Recs:~n~p~n",[Recs]),
    List = [{SortFun(X),setelement(1,X,{}),X} || X <- Recs],
    % ?LogDebug("List:~n~p~n",[List]),
    [Rs || {_, _, Rs} <- lists:sort(List)].

fetch_recs_async(SKey, #stmtResult{stmtRef=Pid}, Sock, IsSec) ->
    fetch_recs_async(SKey, Pid, Sock, IsSec);
fetch_recs_async(SKey, Pid, Sock, IsSec) ->
    fetch_recs_async(SKey, Pid, Sock, [], IsSec).

fetch_recs_async(SKey, #stmtResult{stmtRef=Pid}, Sock, Opts, IsSec) ->
    fetch_recs_async(SKey, Pid, Sock, Opts, IsSec);
fetch_recs_async(SKey, Pid, Sock, Opts, IsSec) when is_pid(Pid) ->
    case [{M,V} || {M,V} <- Opts, true =/= lists:member(M, ?VALID_FETCH_OPTS)] of
        [] -> gen_server:cast(Pid, {fetch_recs_async, IsSec, SKey, Sock, Opts});
        InvalidOpt -> ?ClientError({"Invalid option for fetch", InvalidOpt})
    end.

fetch_close(SKey,  #stmtResult{stmtRef=Pid}, IsSec) ->
    fetch_close(SKey, Pid, IsSec);
fetch_close(SKey, Pid, IsSec) when is_pid(Pid) ->
    gen_server:call(Pid, {fetch_close, IsSec, SKey}).

filter_and_sort(SKey, StmtResult, FilterSpec, SortSpec, IsSec) ->
    filter_and_sort(SKey, StmtResult, FilterSpec, SortSpec, [], IsSec).

filter_and_sort(SKey, #stmtResult{stmtRef=Pid}, FilterSpec, SortSpec, Cols, IsSec) ->
    filter_and_sort(SKey, Pid, FilterSpec, SortSpec, Cols, IsSec);    
filter_and_sort(SKey, Pid, FilterSpec, SortSpec, Cols, IsSec) when is_pid(Pid) ->
    gen_server:call(Pid, {filter_and_sort, IsSec, FilterSpec, SortSpec, Cols, SKey}).

update_cursor_prepare(SKey, #stmtResult{stmtRef=Pid}, IsSec, ChangeList) ->
    update_cursor_prepare(SKey, Pid, IsSec, ChangeList);
update_cursor_prepare(SKey, Pid, IsSec, ChangeList) when is_pid(Pid) ->
    case gen_server:call(Pid, {update_cursor_prepare, IsSec, SKey, ChangeList}) of
        ok ->   ok;
        Error-> throw(Error)
    end.

update_cursor_execute(SKey, #stmtResult{stmtRef=Pid}, IsSec, Lock) ->
    update_cursor_execute(SKey, Pid, IsSec, Lock);
update_cursor_execute(SKey, Pid, IsSec, Lock) when is_pid(Pid) ->
    update_cursor_exec(SKey, Pid, IsSec, Lock).

update_cursor_exec(SKey, Pid, IsSec, Lock) when Lock==none;Lock==optimistic ->
    Result = gen_server:call(Pid, {update_cursor_execute, IsSec, SKey, Lock}),
    % ?Debug("update_cursor_execute ~p~n", [Result]),
    case Result of
        KeyUpd when is_list(KeyUpd) ->  KeyUpd;
        Error ->                        throw(Error)
    end.

close(SKey, #stmtResult{stmtRef=Pid}) ->
    close(SKey, Pid);
close(SKey, Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, {close, SKey}).

init([Statement]) ->
    imem_meta:log_to_db(info,?MODULE,init,[],Statement#statement.stmtStr),
    {ok, #state{statement=Statement}}.

handle_call({set_seco, SKey}, _From, State) ->    
    {reply,ok,State#state{seco=SKey, isSec=true}};
handle_call({update_cursor_prepare, IsSec, _SKey, ChangeList}, _From, #state{statement=Stmt, seco=SKey}=State) ->
    STT = erlang:now(),
    {Reply, UpdatePlan1} = try
        {ok, update_prepare(IsSec, SKey, Stmt#statement.tables, Stmt#statement.colMap, ChangeList)}
    catch
        _:Reason ->  
            imem_meta:log_to_db(error,?MODULE,handle_call,[{reason,Reason},{changeList,ChangeList}],"update_cursor_prepare error"),
            {{error,Reason}, []}
    end,
    imem_meta:log_slow_process(?MODULE,update_cursor_prepare,STT,100,4000,[{table,hd(Stmt#statement.tables)},{rows,length(ChangeList)}]),    
    {reply, Reply, State#state{updPlan=UpdatePlan1}};  
handle_call({update_cursor_execute, IsSec, _SKey, Lock}, _From, #state{seco=SKey, fetchCtx=FetchCtx0, updPlan=UpdatePlan, statement=Stmt}=State) ->
    #fetchCtx{metarec=MR}=FetchCtx0,
    % ?Debug("UpdateMetaRec ~p~n", [MR]),
    STT = erlang:now(),
    Reply = try 
        % case FetchCtx0#fetchCtx.monref of
        %     undefined ->    ok;
        %     MonitorRef ->   kill_fetch(MonitorRef, FetchCtx0#fetchCtx.pid)
        % end,
        % ?Debug("UpdatePlan ~p~n", [UpdatePlan]),
        KeyUpdateRaw = if_call_mfa(IsSec,update_tables,[SKey, UpdatePlan, Lock]),
        % ?Debug("KeyUpdateRaw ~p~n", [KeyUpdateRaw]),
        case length(Stmt#statement.tables) of
            1 ->    
                WrapOut = fun({Tag,X}) -> {Tag,?MetaMain(MR, X)} end,
                lists:map(WrapOut, KeyUpdateRaw);
            _ ->            
                LastIdx = ?TableIdx(length(Stmt#statement.tables)),     %% position of last tuple
                WrapOut = fun
                    ({Tag,{}}) ->
                        R0 = erlang:make_tuple(LastIdx, undefined, [{?MetaIdx,MR},{?MainIdx,{}}]), 
                        {Tag,R0};                        
                    ({Tag,X}) ->
                        case join_rows([?MetaMain(MR, X)], FetchCtx0, Stmt) of
                            [] ->
                                R1 = erlang:make_tuple(LastIdx, undefined, [{?MetaIdx,MR},{?MainIdx,X}]), 
                                {Tag,R1};
                            [R2|_] ->
                                {Tag,R2}
                        end
                end,
                % ?Debug("map KeyUpdateRaw ~p~n", [KeyUpdateRaw]),
                lists:map(WrapOut, KeyUpdateRaw)
        end
    catch
        _:Reason ->
            imem_meta:log_to_db(error,?MODULE,handle_call,[{reason,Reason},{updPlan,UpdatePlan}],"update_cursor_execute error"),
            {error,Reason,erlang:get_stacktrace()}
    end,
    % ?Debug("update_cursor_execute result ~p~n", [Reply]),
    imem_meta:log_slow_process(?MODULE,update_cursor_execute,STT,100,4000,[{table,hd(Stmt#statement.tables)},{rows,length(UpdatePlan)}]),    
    {reply, Reply, State};    
handle_call({filter_and_sort, _IsSec, FilterSpec, SortSpec, Cols0, _SKey}, _From, #state{statement=Stmt}=State) ->
    STT = erlang:now(),
    #statement{stmtParse={select,SelectSections}, colMap=ColMap, fullMap=FullMap} = Stmt,
    {_, WhereTree} = lists:keyfind(where, 1, SelectSections),
    % ?LogDebug("SelectSections~n~p~n", [SelectSections]),
    % ?LogDebug("ColMap~n~p~n", [ColMap]),
    % ?LogDebug("FullMap~n~p~n", [FullMap]),
    Reply = try
        NewSortFun = imem_sql_expr:sort_spec_fun(SortSpec, FullMap, ColMap),
        % ?Info("NewSortFun ~p~n", [NewSortFun]),
        OrderBy = imem_sql_expr:sort_spec_order(SortSpec, FullMap, ColMap),
        % ?Info("OrderBy ~p~n", [OrderBy]),
        Filter =  imem_sql_expr:filter_spec_where(FilterSpec, ColMap, WhereTree),
        % ?Info("Filter ~p~n", [Filter]),
        Cols1 = case Cols0 of
            [] ->   lists:seq(1,length(ColMap));
            _ ->    Cols0
        end,
        AllFields = imem_sql_expr:column_map_items(ColMap, ptree),
        % ?Info("AllFields ~p~n", [AllFields]),
        NewFields =  [lists:nth(N,AllFields) || N <- Cols1],
        % ?Info("NewFields ~p~n", [NewFields]),
        NewSections0 = lists:keyreplace('fields', 1, SelectSections, {'fields',NewFields}),
        NewSections1 = lists:keyreplace('where', 1, NewSections0, {'where',Filter}),
        % ?Info("NewSections1~n~p~n", [NewSections1]),
        NewSections2 = lists:keyreplace('order by', 1, NewSections1, {'order by',OrderBy}),
        % ?Info("NewSections2~n~p~n", [NewSections2]),
        NewSql = sqlparse:pt_to_string({select,NewSections2}),     % sql_box:flat_from_pt({select,NewSections2}),
        % ?Info("NewSql~n~p~n", [NewSql]),
        {ok, NewSql, NewSortFun}
    catch
        _:Reason ->
            imem_meta:log_to_db(error,?MODULE,handle_call,[{reason,Reason},{filter_spec,FilterSpec},{sort_spec,SortSpec},{cols,Cols0}],"filter_and_sort error"),
            {error,Reason}
    end,
    % ?LogDebug("replace_sort result ~p~n", [Reply]),
    imem_meta:log_slow_process(?MODULE,filter_and_sort,STT,100,4000,[{table,hd(Stmt#statement.tables)},{filter_spec,FilterSpec},{sort_spec,SortSpec}]),    
    {reply, Reply, State};
handle_call({fetch_close, _IsSec, _SKey}, _From, #state{statement=Stmt,fetchCtx=FetchCtx0}=State) ->
    % imem_meta:log_to_db(debug,?MODULE,handle_call,[{from,_From},{status,Status}],"fetch_close"),
    #fetchCtx{pid=Pid, monref=MonitorRef, status=Status} = FetchCtx0,
    case Status of
        undefined ->    ok;                             % close is ignored
        done ->         ok;                             % normal close after completed fetch
        waiting ->      kill_fetch(MonitorRef, Pid);    % client stops fetch 
        fetching ->     kill_fetch(MonitorRef, Pid);    % client stops fetch 
        tailing ->      unsubscribe(Stmt);              % client stops tail mode
        aborted ->      ok                              % client acknowledges abort
    end,
    FetchCtx1 = FetchCtx0#fetchCtx{pid=undefined, monref=undefined, metarec=undefined, status=undefined},   
    {reply, ok, State#state{fetchCtx=FetchCtx1}}.      % client may restart the fetch now

handle_cast({fetch_recs_async, _IsSec, _SKey, Sock, _Opts}, #state{fetchCtx=#fetchCtx{status=done}}=State) ->
    % ?Debug("fetch_recs_async called in status done~n", []),
    imem_meta:log_to_db(warning,?MODULE,handle_cast,[{sock,Sock},{opts,_Opts},{status,done}],"fetch_recs_async rejected"),
    send_reply_to_client(Sock, {error,{'ClientError',"Fetch is completed, execute fetch_close before fetching from start again"}}),
    {noreply, State}; 
handle_cast({fetch_recs_async, _IsSec, _SKey, Sock, _Opts}, #state{fetchCtx=#fetchCtx{status=aborted}}=State) ->
    % ?Debug("fetch_recs_async called in status aborted~n", []),
    imem_meta:log_to_db(warning,?MODULE,handle_cast,[{sock,Sock},{opts,_Opts},{status,aborted}],"fetch_recs_async rejected"),
    send_reply_to_client(Sock, {error,{'SystemException',"Fetch is aborted, execute fetch_close before fetching from start again"}}),
    {noreply, State}; 
handle_cast({fetch_recs_async, _IsSec, _SKey, Sock, _Opts}, #state{fetchCtx=#fetchCtx{status=tailing}}=State) ->
    % ?Debug("fetch_recs_async called in status tailing~n", []),
    imem_meta:log_to_db(warning,?MODULE,handle_cast,[{sock,Sock},{opts,_Opts},{status,tailing}],"fetch_recs_async rejected"),
    send_reply_to_client(Sock, {error,{'ClientError',"Fetching in tail mode, execute fetch_close before fetching from start again"}}),
    {noreply, State}; 
handle_cast({fetch_recs_async, IsSec, _SKey, Sock, Opts}, #state{statement=Stmt, seco=SKey, fetchCtx=FetchCtx0}=State) ->
    % ?LogDebug("fetch_recs_async called in status ~p~n", [FetchCtx0#fetchCtx.status]),
    % ?LogDebug("fetch_recs_async called with Stmt~n~p~n", [Stmt]),
    #statement{tables=[Table|JTabs], blockSize=BlockSize, mainSpec=MainSpec, metaFields=MetaFields, stmtParams=Params0} = Stmt,
    % imem_meta:log_to_db(debug,?MODULE,handle_cast,[{sock,Sock},{opts,Opts},{status,FetchCtx0#fetchCtx.status}],"fetch_recs_async"),
    Params1 = case lists:keyfind(params, 1, Opts) of
        false ->    Params0;    %% from statement exec, only used on first fetch
        {_, P} ->   P           %% from fetch_recs, only used on first fetch
    end,
    case {lists:member({fetch_mode,skip},Opts), FetchCtx0#fetchCtx.pid} of
        {true,undefined} ->      %% {SkipFetch, Pid} = {true, uninitialized} -> skip fetch
            RowNum = case MetaFields of
                [<<"rownum">>|_] -> 1;
                _ ->                undefined
            end, 
            MR = imem_sql:meta_rec(IsSec,SKey,MetaFields,Params1,FetchCtx0#fetchCtx.metarec),
            % ?LogDebug("Meta Rec: ~p~n", [MR]),
            % ?LogDebug("Main Spec before meta bind:~n~p~n", [MainSpec]),
            {_SSpec,TailSpec,FilterFun} = imem_sql_expr:bind_scan(?MainIdx,{MR},MainSpec),
            % ?LogDebug("Tail Spec after meta bind:~n~p~n", [TailSpec]),
            % ?LogDebug("Filter Fun after meta bind:~n~p~n", [FilterFun]),
            RecName = try imem_meta:table_record_name(Table)
                      catch {'ClientError', {"Table does not exist", _TableName}} -> undefined
                      end,
            FetchSkip = #fetchCtx{status=undefined,metarec=MR,blockSize=BlockSize
                                 ,rownum=RowNum,remaining=MainSpec#scanSpec.limit
                                 ,opts=Opts,tailSpec=TailSpec
                                 ,filter=FilterFun,recName=RecName},
            handle_fetch_complete(State#state{reply=Sock,fetchCtx=FetchSkip}); 
        {false,undefined} ->     %% {SkipFetch, Pid} = {false, uninitialized} -> initialize fetch
            RowNum = case MetaFields of
                [<<"rownum">>|_] -> 1;
                _ ->                undefined
            end, 
            MR = imem_sql:meta_rec(IsSec,SKey,MetaFields,Params1,FetchCtx0#fetchCtx.metarec),
            % ?LogDebug("Meta Rec: ~p~n", [MR]),
            % ?LogDebug("Main Spec before meta bind:~n~p~n", [MainSpec]),
            {SSpec,TailSpec,FilterFun} = imem_sql_expr:bind_scan(?MainIdx,{MR},MainSpec),
            % ?LogDebug("Scan Spec after meta bind:~n~p~n", [SSpec]),
            % ?LogDebug("Tail Spec after meta bind:~n~p~n", [TailSpec]),
            % ?LogDebug("Filter Fun after meta bind:~n~p~n", [FilterFun]),
            try 
                get_select_permissions(IsSec,SKey, [Table|JTabs]),
                case if_call_mfa(IsSec, fetch_start, [SKey, self(), Table, SSpec, BlockSize, Opts]) of
                    TransPid when is_pid(TransPid) ->
                        MonitorRef = erlang:monitor(process, TransPid),
                        TransPid ! next,
                        % ?Debug("fetch opts ~p~n", [Opts]),
                        RecName = try imem_meta:table_record_name(Table)
                                  catch {'ClientError', {"Table does not exist", _TableName}} -> undefined
                                  end,
                        FetchStart = #fetchCtx{pid=TransPid,monref=MonitorRef,status=waiting
                                              ,metarec=MR,blockSize=BlockSize
                                              ,rownum=RowNum,remaining=MainSpec#scanSpec.limit
                                              ,opts=Opts,tailSpec=TailSpec,filter=FilterFun
                                              ,recName=RecName},
                        {noreply, State#state{reply=Sock,fetchCtx=FetchStart}}; 
                    Error ->
                        send_reply_to_client(Sock, {error, {"Cannot spawn async fetch process", Error}}),
                        FetchAborted1 = #fetchCtx{pid=undefined, monref=undefined, status=aborted},
                        {noreply, State#state{reply=Sock,fetchCtx=FetchAborted1}}
                end
            catch
                _:Err ->
                    send_reply_to_client(Sock, {error, Err}),
                    FetchAborted2 = #fetchCtx{pid=undefined, monref=undefined, status=aborted},
                    {noreply, State#state{reply=Sock,fetchCtx=FetchAborted2}}
            end;
        {true,_Pid} ->          %% skip ongoing fetch (and possibly go to tail_mode)
            MR = imem_sql:meta_rec(IsSec,SKey,MetaFields,Params1,FetchCtx0#fetchCtx.metarec),
            % ?LogDebug("Meta Rec: ~p~n", [MR]),
            % ?LogDebug("Main Spec before meta bind:~n~p~n", [MainSpec]),
            {_SSpec,TailSpec,FilterFun} = imem_sql_expr:bind_scan(?MainIdx,{MR},MainSpec),
            % ?LogDebug("Tail Spec after meta bind:~n~p~n", [TailSpec]),
            % ?LogDebug("Filter Fun after meta bind:~n~p~n", [FilterFun]),
            FetchSkipRemaining = FetchCtx0#fetchCtx{metarec=MR,opts=Opts,tailSpec=TailSpec,filter=FilterFun},
            handle_fetch_complete(State#state{reply=Sock,fetchCtx=FetchSkipRemaining}); 
        {false,Pid} ->          %% fetch next block
            MR = imem_sql:meta_rec(IsSec,SKey,MetaFields,Params1,FetchCtx0#fetchCtx.metarec),
            % ?LogDebug("Meta Rec: ~p~n", [MR]),
            % ?LogDebug("Main Spec before meta bind:~n~p~n", [MainSpec]),
            {_SSpec,TailSpec,FilterFun} = imem_sql_expr:bind_scan(?MainIdx,{MR},MainSpec),
            % ?LogDebug("Tail Spec after meta bind:~n~p~n", [TailSpec]),
            % ?LogDebug("Filter Fun after meta bind:~n~p~n", [FilterFun]),
            Pid ! next,
            % ?LogDebug("fetch opts ~p~n", [Opts]),
            FetchContinue = FetchCtx0#fetchCtx{metarec=MR,opts=Opts,tailSpec=TailSpec,filter=FilterFun}, 
            {noreply, State#state{reply=Sock,fetchCtx=FetchContinue}}  
    end;
handle_cast({close, _SKey}, State) ->
    % imem_meta:log_to_db(debug,?MODULE,handle_cast,[],"close statement"),
    % ?Debug("received close in state ~p~n", [State]),
    {stop, normal, State}; 
handle_cast(Request, State) ->
    ?Debug("received unsolicited cast ~p~nin state ~p~n", [Request, State]),
    imem_meta:log_to_db(error,?MODULE,handle_cast,[{request,Request},{state,State}],"receives unsolicited cast"),
    {noreply, State}.

handle_info({row, ?eot}, #state{reply=Sock,fetchCtx=FetchCtx0}=State) ->
    % ?Debug("received end of table in fetch status ~p~n", [FetchCtx0#fetchCtx.status]),
    % ?Debug("received end of table in state~n~p~n", [State]),
    case FetchCtx0#fetchCtx.status of
        fetching ->
            imem_meta:log_to_db(warning,?MODULE,handle_info,[{row, ?eot},{status,fetching},{sock,Sock}],"eot"),
            send_reply_to_client(Sock, {[],true}),  
            % ?Debug("late end of table received in state~n~p~n", [State]),
            handle_fetch_complete(State);
        _ ->
            ?Debug("unexpected end of table received in state~n~p~n", [State]),        
            imem_meta:log_to_db(warning,?MODULE,handle_info,[{row, ?eot}],"eot"),
            {noreply, State}
    end;        
handle_info({mnesia_table_event, {write, {schema, _TableName, _TableNewProperties}, _ActivityId}}, State) ->
    % imem_meta:log_to_db(debug,?MODULE,handle_info,[{mnesia_table_event,write, schema}],"tail delete"),
    % ?Debug("received mnesia subscription event ~p ~p ~p~n", [write_schema, _TableName, _TableNewProperties]),
    {noreply, State};
handle_info({mnesia_table_event,{write,R0,_ActivityId}}, #state{isSec=IsSec,seco=SKey,reply=Sock,fetchCtx=FetchCtx0,statement=Stmt}=State) ->
    % imem_meta:log_to_db(debug,?MODULE,handle_info,[{mnesia_table_event,write}],"tail write"),
    % ?LogDebug("received mnesia subscription event ~p ~p~n", [write, Record]),
    #fetchCtx{status=Status,metarec=MR0,rownum=RowNum,remaining=Rem0,filter=FilterFun,tailSpec=TailSpec,recName=RecName}=FetchCtx0,
    MR1 = imem_sql:meta_rec(IsSec,SKey,Stmt#statement.metaFields,[],MR0),    %% Params cannot change any more after first fetch
    MR2 = case RowNum of
        undefined -> MR1;
        _ ->         setelement(?RownumIdx,MR1,RowNum)
    end,
    R1 = erlang:setelement(?RecIdx, R0, RecName),  %% Main Tail Record (record name recovered)
    % ?LogDebug("processing tail : record / tail / filter~n~p~n~p~n~p~n", [R1,TailSpec,FilterFun]),
    RawRecords = case {Status,TailSpec,FilterFun} of
        {tailing,false,_} ->        [];
        {tailing,_,false} ->        [];
        {tailing,undefined,_} ->    ?SystemException({"Undefined tail function for tail record",R1}); 
        {tailing,_,undefined} ->    ?SystemException({"Undefined filter function for tail record",R1}); 
        {tailing,true,true} ->      [?MetaMain(MR2, R1)];
        {tailing,true,_} ->         lists:filter(FilterFun, [?MetaMain(MR2, R1)]);
        {tailing,_,true} ->         
            case ets:match_spec_run([R1], TailSpec) of
                [] ->   [];
                [R2] -> [?MetaMain(MR2, R2)]
            end;
        {tailing,_,_} ->            
            case ets:match_spec_run([R1], TailSpec) of
                [] ->   [];
                [R2] -> lists:filter(FilterFun, [?MetaMain(MR2, R2)])
            end
    end,
    case {RawRecords,length(Stmt#statement.tables),RowNum} of
        {[],_,_} ->   %% nothing to be returned  
            {noreply, State};
        {_,1,undefined} ->    %% single table select, avoid join overhead
            if  
                Rem0 =< 1 ->
                    % ?LogDebug("send~n~p~n", [{RawRecords,true}]),
                    send_reply_to_client(Sock, {RawRecords,true}),  
                    unsubscribe(Stmt),
                    {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{status=done}}};
                true ->
                    % ?LogDebug("send~n~p~n", [{RawRecords,tail}]),
                    send_reply_to_client(Sock, {RawRecords,tail}),
                    {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{remaining=Rem0-1}}}
            end;
        {_,1,_FirstRN} ->    %% single table select, avoid join overhead but update RowNum meta field
            if  
                Rem0 =< 1 ->
                    % ?LogDebug("send~n~p~n", [{RawRecords,true}]),
                    send_reply_to_client(Sock, {RawRecords,true}),  
                    unsubscribe(Stmt),
                    {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{status=done}}};
                true ->
                    % ?LogDebug("send~n~p~n", [{RawRecords,tail}]),
                    send_reply_to_client(Sock, {RawRecords,tail}),
                    {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{rownum=RowNum+1,remaining=Rem0-1}}}
            end;
        {_,_,undefined} ->        %% join raw result of main scan with remaining tables
            case join_rows(RawRecords, FetchCtx0, Stmt) of
                [] ->
                    {noreply, State};
                Result ->    
                    if 
                        (Rem0 =< length(Result)) ->
                            % ?LogDebug("send~n~p~n", [{Result,true}]),
                            send_reply_to_client(Sock, {Result, true}),
                            unsubscribe(Stmt),
                            {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{status=done}}};
                        true ->
                            % ?LogDebug("send~n~p~n", [{Result,tail}]),
                            send_reply_to_client(Sock, {Result, tail}),
                            {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{remaining=Rem0-length(Result)}}}
                    end
            end;
        {_,_,_} ->        %% join raw result of main scan with remaining tables, correct RowNum
            case join_rows(RawRecords, FetchCtx0, Stmt) of
                [] ->
                    {noreply, State};
                JoinedRows ->
                    if 
                        (Rem0 =< length(JoinedRows)) ->
                            % ?LogDebug("send~n~p~n", [{Result,true}]),
                            send_reply_to_client(Sock, {update_row_num(MR2, RowNum, JoinedRows), true}),
                            unsubscribe(Stmt),
                            {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{status=done}}};
                        true ->
                            % ?LogDebug("send~n~p~n", [{Result,tail}]),
                            send_reply_to_client(Sock, {update_row_num(MR2, RowNum, JoinedRows), tail}),
                            {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{rownum=RowNum+length(JoinedRows),remaining=Rem0-length(JoinedRows)}}}
                    end
            end
    end;
handle_info({mnesia_table_event,{delete_object, _OldRecord, _ActivityId}}, State) ->
    % imem_meta:log_to_db(debug,?MODULE,handle_info,[{mnesia_table_event,delete_object}],"tail delete"),
    % ?Debug("received mnesia subscription event ~p ~p~n", [delete_object, _OldRecord]),
    {noreply, State};
handle_info({mnesia_table_event,{delete, {_Tab, _Key}, _ActivityId}}, State) ->
    % imem_meta:log_to_db(debug,?MODULE,handle_info,[{mnesia_table_event,delete}],"tail delete"),
    % ?Debug("received mnesia subscription event ~p ~p~n", [delete, {_Tab, _Key}]),
    {noreply, State};
handle_info({row, Rows0}, #state{reply=Sock, isSec=IsSec, seco=SKey, fetchCtx=FetchCtx0, statement=Stmt}=State) ->
    #fetchCtx{metarec=MR0,rownum=RowNum,remaining=Rem0,status=Status,filter=FilterFun, opts=Opts}=FetchCtx0,
    % ?LogDebug("received ~p rows~n", [length(Rows0)]),
    % ?LogDebug("received rows~n~p~n", [Rows0]),
    {Rows1,Complete} = case {Status,Rows0} of
        {waiting,[?sot,?eot|R]} ->
            % imem_meta:log_to_db(debug,?MODULE,handle_info,[{row,length(R)}],"data complete"),     
            {R,true};
        {waiting,[?sot|R]} ->            
            % imem_meta:log_to_db(debug,?MODULE,handle_info,[{row,length(R)}],"data first"),     
            {R,false};
        {fetching,[?eot|R]} ->
            % imem_meta:log_to_db(debug,?MODULE,handle_info,[{row,length(R)}],"data complete"),     
            {R,true};
        {fetching,[?sot,?eot|_R]} ->
            imem_meta:log_to_db(warning,?MODULE,handle_info,[{row,length(_R)}],"data transaction restart"),     
            handle_fetch_complete(State);
        {fetching,[?sot|_R]} ->
            imem_meta:log_to_db(warning,?MODULE,handle_info,[{row,length(_R)}],"data transaction restart"),     
            handle_fetch_complete(State);
        {fetching,R} ->            
            % imem_meta:log_to_db(debug,?MODULE,handle_info,[{row,length(R)}],"data"),     
            {R,false};
        {BadStatus,R} ->            
            imem_meta:log_to_db(error,?MODULE,handle_info,[{status,BadStatus},{row,length(R)}],"data"),     
            {R,false}        
    end,   
    % ?LogDebug("Filtering ~p rows with filter ~p~n", [length(Rows1),FilterFun]),
    MR1 = case RowNum of
        undefined -> MR0;
        _ ->         setelement(?RownumIdx,MR0,RowNum)
    end,
    Wrap = fun(X) -> ?MetaMain(MR1, X) end,
    Result = case {length(Stmt#statement.tables),FilterFun,RowNum} of
        {_,false,_} ->
            [];
        {1,true,undefined} ->
            take_remaining(Rem0, lists:map(Wrap, Rows1));
        {1,_,undefined} ->
            take_remaining(Rem0, lists:filter(FilterFun,lists:map(Wrap, Rows1)));
        {_,true,undefined} ->
            join_rows(lists:map(Wrap, Rows1), FetchCtx0, Stmt);
        {_,_,undefined} ->
            join_rows(lists:filter(FilterFun,lists:map(Wrap, Rows1)), FetchCtx0, Stmt);
        {1,true,FirstRN} ->
            update_row_num(MR1, FirstRN, take_remaining(Rem0, lists:map(Wrap, Rows1)));
        {_,true,FirstRN} ->
            JoinedRows = join_rows(lists:map(Wrap, Rows1), FetchCtx0, Stmt),
            update_row_num(MR1, FirstRN, JoinedRows);
        {_,_,FirstRN} ->
            JoinedRows = join_rows(lists:filter(FilterFun,lists:map(Wrap,Rows1)), FetchCtx0, Stmt),
            update_row_num(MR1, FirstRN, JoinedRows)
    end,
    case is_number(Rem0) of
        true ->
            % ?Debug("sending rows ~p~n", [Result]),
            case length(Result) >= Rem0 of
                true ->     
                    % ?LogDebug("send~n~p~n", [{Result, true}]),
                    send_reply_to_client(Sock, {Result, true}),
                    handle_fetch_complete(State);
                false ->    
                    % ?LogDebug("send~n~p~n", [{Result, Complete}]),
                    send_reply_to_client(Sock, {Result, Complete}),
                    FetchCtx1 = case RowNum of
                        undefined ->    FetchCtx0#fetchCtx{remaining=Rem0-length(Result),status=fetching};
                        _ ->            FetchCtx0#fetchCtx{rownum=RowNum+length(Result),remaining=Rem0-length(Result),status=fetching}
                    end,
                    PushMode = lists:member({fetch_mode,push},Opts),
                    if
                        Complete ->
                            handle_fetch_complete(State#state{fetchCtx=FetchCtx1});
                        PushMode ->
                            gen_server:cast(self(),{fetch_recs_async, IsSec, SKey, Sock, Opts}),
                            {noreply, State#state{fetchCtx=FetchCtx1}};
                        true ->
                            {noreply, State#state{fetchCtx=FetchCtx1}}
                    end
            end;
        false ->
            ?Debug("receiving rows ~n~p~n", [Rows0]),
            ?Debug("in unexpected state ~n~p~n", [State]),
            {noreply, State}
    end;
handle_info({'DOWN', _Ref, process, _Pid, _Reason}, #state{reply=undefined,fetchCtx=FetchCtx0}=State) ->
    % ?Debug("received expected exit info for monitored pid ~p ref ~p reason ~p~n", [_Pid, _Ref, _Reason]),
    FetchCtx1 = FetchCtx0#fetchCtx{monref=undefined, status=undefined},   
    {noreply, State#state{fetchCtx=FetchCtx1}};
handle_info({'DOWN', Ref, process, Pid, {aborted, {no_exists,{_TableName,_}}=Reason}}, State) ->
    handle_info({'DOWN', Ref, process, Pid, Reason}, State);
handle_info({'DOWN', Ref, process, _Pid, {no_exists,{TableName,_}}=_Reason}, #state{reply=Sock,fetchCtx=#fetchCtx{monref=Ref}}=State) ->
    ?Debug("received unexpected exit info for monitored pid ~p ref ~p reason ~p~n", [_Pid, Ref, _Reason]),
    send_reply_to_client(Sock, {error, {'ClientError', {"Table does not exist", TableName}}}),
    {noreply, State#state{fetchCtx=#fetchCtx{pid=undefined, monref=undefined, status=aborted}}};
handle_info(_Info, State) ->
    ?Debug("received unsolicited info ~p~nin state ~p~n", [_Info, State]),
    {noreply, State}.

handle_fetch_complete(#state{reply=Sock,fetchCtx=FetchCtx0,statement=Stmt}=State)->
    #fetchCtx{pid=Pid,monref=MonitorRef,opts=Opts}=FetchCtx0,
    kill_fetch(MonitorRef, Pid),
    % ?Debug("fetch complete, opts ~p~n", [Opts]), 
    case lists:member({tail_mode,true},Opts) of
        false ->
            % ?Debug("fetch complete no tail ~p~n", [Opts]), 
            {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{status=done}}};           
        true ->     
            {_Schema,Table} = hd(Stmt#statement.tables),
            % ?Debug("fetch complete, switching to tail_mode~p~n", [Opts]), 
            case  catch if_call_mfa(false,subscribe,[none,{table,Table,simple}]) of
                ok ->
                    % ?Debug("Subscribed to table changes ~p~n", [Table]),    
                    {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{status=tailing}}};
                Error ->
                    ?Debug("Cannot subscribe to table changes~n~p~n", [{Table,Error}]),    
                    imem_meta:log_to_db(error,?MODULE,handle_fetch_complete,[{table,Table},{error,Error},{sock,Sock}],"Cannot subscribe to table changes"),
                    send_reply_to_client(Sock, {error,{'SystemException',{"Cannot subscribe to table changes",{Table,Error}}}}),
                    {noreply, State#state{fetchCtx=FetchCtx0#fetchCtx{status=done}}}   
            end    
    end.

terminate(_Reason, #state{fetchCtx=#fetchCtx{pid=Pid, monref=undefined}}) -> 
    % ?Debug("terminating monitor not found~n", []),
    catch Pid ! abort, 
    ok;
terminate(_Reason, #state{statement=Stmt,fetchCtx=#fetchCtx{status=tailing}}) -> 
    % ?Debug("terminating tail_mode~n", []),
    unsubscribe(Stmt),
    ok;
terminate(_Reason, #state{fetchCtx=#fetchCtx{pid=Pid, monref=MonitorRef}}) ->
    % ?Debug("demonitor and terminate~n", []),
    kill_fetch(MonitorRef, Pid), 
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.


get_select_permissions(false, _, _) -> true;
get_select_permissions(true, _, []) -> true;
get_select_permissions(true, SKey, [Table|JTabs]) ->
    case imem_sec:have_table_permission(SKey, Table, select) of
        false ->   ?SecurityException({"Select unauthorized", {Table,SKey}});
        true ->    get_select_permissions(true, SKey, JTabs)
    end.

unsubscribe(Stmt) ->
    {_Schema,Table} = hd(Stmt#statement.tables),
    case catch if_call_mfa(false,unsubscribe,[none,{table,Table,simple}]) of
        ok ->       ok;
        {ok,_} ->   ok;
        Error ->
                    ?Debug("Cannot unsubscribe table changes~n~p~n", [{Table,Error}]),    
                    imem_meta:log_to_db(error,?MODULE,unsubscribe,[{table,Table},{error,Error}],"Cannot unsubscribe table changes")
    end.

kill_fetch(undefined, undefined) -> ok;
kill_fetch(MonitorRef, Pid) ->
    catch erlang:demonitor(MonitorRef, [flush]),
    catch Pid ! abort. 

take_remaining(Remaining, Rows) ->            
    RowC = length(Rows),
    if  
        RowC == 0 ->            [];
        RowC < Remaining ->     Rows;
        RowC == Remaining ->    Rows;
        Remaining =< 0 ->       [];
        Remaining > 0 ->
            {ResultRows,_Rest} = lists:split(Remaining, Rows),
            % LastKey = element(?KeyIdx,element(?MainIdx,lists:last(ResultRows))),    %% 2=KeyPosInRecord 2=MainTablePosInRecs
            % Pred = fun(X) -> (element(?KeyIdx,element(?MainIdx,X))==LastKey) end,   %% 2=KeyPosInRecord 2=MainTablePosInRecs
            % ResultTail = lists:takewhile(Pred, Rest),                               %% Try to give all rows for lasr key in a bag
            % %% TODO: may need to read more blocks to completely read this key in a bag
            % ResultRows ++ ResultTail
            ResultRows
    end.

update_row_num(MR, FirstRN, Rows) ->
    UpdRN = fun({R,X}) -> setelement(?MetaIdx, X, setelement(?RownumIdx, MR, R)) end,
    lists:map(UpdRN, zip_row_num(FirstRN,Rows)).

zip_row_num(FirstRN,Rows) ->    
    lists:zip(lists:seq(FirstRN, FirstRN+length(Rows)-1), Rows).

join_rows(MetaAndMainRows, FetchCtx0, Stmt) ->
    #fetchCtx{blockSize=BlockSize, remaining=RemainingRowQuota}=FetchCtx0,
    JoinTables = tl(Stmt#statement.tables),  %% {Schema,Name,Alias} for each table to join
    JoinSpecs = Stmt#statement.joinSpecs,
    % ?Debug("Join Tables: ~p~n", [Tables]),
    % ?Debug("Join Specs: ~p~n", [JoinSpecs]),
    join_rows(MetaAndMainRows, BlockSize, RemainingRowQuota, JoinTables, JoinSpecs, []).

join_rows([], _, _, _, _, Acc) -> Acc;                              %% lists:reverse(Acc);
join_rows(_, _, RRowQuota, _, _, Acc) when RRowQuota < 1 -> Acc;    %% lists:reverse(Acc);
join_rows([Row|Rows], BlockSize, RRowQuota, JoinTables, JoinSpecs, Acc) ->
    Rec = erlang:make_tuple(length(JoinTables)+2, undefined, [{?MetaIdx,element(?MetaIdx,Row)},{?MainIdx,element(?MainIdx,Row)}]),
    JAcc = join_row([Rec], BlockSize, ?MainIdx+1, JoinTables, JoinSpecs),
    join_rows(Rows, BlockSize, RRowQuota-length(JAcc), JoinTables, JoinSpecs, JAcc++Acc).

join_row(Recs, _BlockSize, _Ti, [], []) -> Recs;
join_row(Recs0, BlockSize, Ti, [{_S,JoinTable}|Tabs], [JS|JSpecs]) ->
    %% Ti = tuple index, points to the tuple position, starts with main table index for each row
    Recs1 = case lists:member(JoinTable,?DataTypes) of
        true ->  [join_virtual(Rec, BlockSize, Ti, JoinTable, JS) || Rec <- Recs0];
        false -> [join_table(Rec, BlockSize, Ti, JoinTable, JS) || Rec <- Recs0]
    end,
    join_row(lists:flatten(Recs1), BlockSize, Ti+1, Tabs, JSpecs).

join_table(Rec, _BlockSize, Ti, Table, #scanSpec{limit=Limit}=JoinSpec) ->
    % ?Debug("Join ~p table ~p~n", [Ti,Table]),
    % ?Debug("Rec used for join bind~n~p~n", [Rec]),
    {SSpec,_TailSpec,FilterFun} = imem_sql_expr:bind_scan(Ti,Rec,JoinSpec),
    MaxSize = Limit+1000,   %% TODO: Move away from single shot join fetch, use async block fetch here as well.
    case imem_meta:select(Table, SSpec, MaxSize) of
        {[], true} ->   [];
        {L, true} ->
            case FilterFun of
                true ->     [setelement(Ti, Rec, I) || I <- L];
                false ->    [];
                Filter ->   Recs = [setelement(Ti, Rec, I) || I <- L],
                            lists:filter(Filter,Recs)
            end;
        {_, false} ->   ?ClientError({"Too much data in join intermediate result", MaxSize});
        Error ->        ?SystemException({"Unexpected join intermediate result", Error})
    end.

join_virtual(Rec, _BlockSize, Ti, Table, #scanSpec{limit=Limit}=JoinSpec) ->
    % ?LogDebug("Virtual join scan spec unbound (~p)~n~p~n", [Ti,SSpec0]),
    {SSpec1,_TailSpec,FilterFun} = imem_sql_expr:bind_virtual(Ti,Rec,JoinSpec),
    [{_,[SGuard1],_}] = SSpec1,
    % ?LogDebug("Virtual join table (~p) ~p~n", [Ti,Table]),
    % ?LogDebug("Rec used for join bind (~p)~n~p~n", [Ti,Rec]),
    % ?LogDebug("Virtual join guard bound (~p)~n~p~n", [Ti,SGuard1]),
    MaxSize = Limit+1000,   %% TODO: Move away from single shot join fetch, use async block fetch here as well.
    Recs = case SGuard1 of
        false ->
            [];
        true ->
            ?UnimplementedException({"Unsupported virtual join filter guard", true}); 
        {is_member,Tag, '$_'} when is_atom(Tag) ->
            Items = element(?MainIdx,Rec),
            % ?Debug("generate_virtual table ~p from ~p~n~p~n", [Table,'$_',Items]),
            Virt = generate_virtual(Table,tl(tuple_to_list(Items)),MaxSize),
            % ?Debug("Generated virtual table ~p~n~p~n", [Table,Virt]),
            [setelement(Ti, Rec, {Table,I}) || I <- Virt];
        {is_member,Tag, Items} when is_atom(Tag) ->
            % ?Debug("generate_virtual table ~p from~n~p~n", [Table,Items]),
            Virt = generate_virtual(Table,Items,MaxSize),
            % ?Debug("Generated virtual table ~p~n~p~n", [Table,Virt]),
            [setelement(Ti, Rec, {Table,I}) || I <- Virt];
        {'and',{is_member,Tag, '$_'},_} when is_atom(Tag) ->
            Items = element(?MainIdx,Rec),
            % ?Debug("generate_virtual table ~p from ~p~n~p~n", [Table,'$_',Items]),
            Virt = generate_virtual(Table,tl(tuple_to_list(Items)),MaxSize),
            % ?Debug("Generated virtual table ~p~n~p~n", [Table,Virt]),
            [setelement(Ti, Rec, {Table,I}) || I <- Virt];
        {'and',{is_member,Tag, Items},_} when is_atom(Tag) ->
            % ?Debug("generate_virtual table ~p from~n~p~n", [Table,Items]),
            Virt = generate_virtual(Table,Items,MaxSize),
            % ?Debug("Generated virtual table ~p~n~p~n", [Table,Virt]),
            [setelement(Ti, Rec, {Table,I}) || I <- Virt];
        BadFG ->
            ?UnimplementedException({"Unsupported virtual join bound filter guard",BadFG})
    end,
    case FilterFun of
        true ->     Recs;
        false ->    [];
        Filter ->   lists:filter(Filter,Recs)
    end.

generate_virtual(Table, {const,Items}, MaxSize) when is_tuple(Items) ->
    generate_virtual(Table, tuple_to_list(Items), MaxSize);
generate_virtual(Table, Items, MaxSize) when is_tuple(Items) ->
    generate_virtual(Table, tuple_to_list(Items), MaxSize);

generate_virtual(atom=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_atom(X) end,
    lists:filter(Pred,Items);
generate_virtual(atom, Item, _) when is_atom(Item)-> [Item];
generate_virtual(atom, _, _) -> [];

generate_virtual(binary=Table, Items, MaxSize) when is_binary(Items) ->
    generate_limit_check(Table, byte_size(Items), MaxSize),
    [list_to_binary([B]) || B <- binary_to_list(Items)];
generate_virtual(binary, _, _) -> [];

generate_virtual(binstr=Table, Items, MaxSize) when is_binary(Items) ->
    generate_limit_check(Table, byte_size(Items), MaxSize),
    String = binary_to_list(Items),
    case io_lib:printable_unicode_list(String) of
        true ->     String;
        false ->    []
    end;

generate_virtual(boolean=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_boolean(X) end,
    lists:filter(Pred,Items);
generate_virtual(boolean, Item, _) when is_boolean(Item)-> [Item];
generate_virtual(boolean, _, _) -> [];

generate_virtual(datetime=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun
        ({{_,_,_},{_,_,_}}) -> true;
        (_) -> false
    end,
    lists:filter(Pred,Items);
generate_virtual(datetime, {{_,_,_},{_,_,_}}=Item, _) -> 
    [Item];
generate_virtual(datetime, _, _) -> [];

generate_virtual(decimal=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_integer(X) end,
    lists:filter(Pred,Items);
generate_virtual(decimal, Item, _) when is_integer(Item)-> [Item];
generate_virtual(decimal, _, _) -> [];

generate_virtual(float=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_float(X) end,
    lists:filter(Pred,Items);
generate_virtual(float, Item, _) when is_float(Item)-> [Item];
generate_virtual(float, _, _) -> [];

generate_virtual('fun'=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_function(X) end,
    lists:filter(Pred,Items);
generate_virtual('fun', Item, _) when is_function(Item)-> [Item];
generate_virtual('fun', _, _) -> [];

generate_virtual(integer=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_integer(X) end,
    lists:filter(Pred,Items);
generate_virtual(integer, Item, _) when is_integer(Item)-> [Item];
generate_virtual(integer, _, _) -> [];

generate_virtual(ipaddr=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun
        ({A,B,C,D}) when is_integer(A), is_integer(B), is_integer(C), is_integer(D) -> true;
        (_) -> false
    end,                                %% ToDo: IpV6
    lists:filter(Pred,Items);
generate_virtual(ipaddr, {A,B,C,D}=Item, _) when is_integer(A), is_integer(B), is_integer(C), is_integer(D) -> [Item];
generate_virtual(ipaddr, _, _) -> [];      %% ToDo: IpV6

generate_virtual(list=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Items;

generate_virtual(json=Table, Items, MaxSize) when is_binary(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    [imem_json:to_proplist(I) || I <- Items];
generate_virtual(json=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Items;

generate_virtual(timestamp=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun
        ({Meg,Sec,Mic}) when is_number(Meg), is_integer(Sec), is_integer(Mic) -> true;
        (_) -> false
    end,
    lists:filter(Pred,Items);
generate_virtual(timestamp, {Meg,Sec,Mic}=Item, _) when is_number(Meg), is_integer(Sec), is_integer(Mic) -> 
    [Item];
generate_virtual(timestamp, _, _) -> [];

generate_virtual(tuple=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_tuple(X) end,
    lists:filter(Pred,Items);
generate_virtual(tuple, Item, _) when is_tuple(Item)-> [Item];
generate_virtual(tuple, _, _) -> [];

generate_virtual(pid=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_pid(X) end,
    lists:filter(Pred,Items);
generate_virtual(pid, Item, _) when is_pid(Item)-> [Item];
generate_virtual(pid, _, _) -> [];

generate_virtual(ref=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_reference(X) end,
    lists:filter(Pred,Items);
generate_virtual(ref, Item, _) when is_reference(Item)-> [Item];
generate_virtual(ref, _, _) -> [];

generate_virtual(string=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    case io_lib:printable_unicode_list(Items) of
        true ->     Items;
        false ->    []
    end;

generate_virtual(term=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Items;
generate_virtual(term, Item, _) ->
    [Item];

generate_virtual(userid=Table, Items, MaxSize) when is_list(Items) ->
    generate_limit_check(Table, length(Items), MaxSize),
    Pred = fun(X) -> is_integer(X) end,
    lists:filter(Pred,Items);               %% ToDo: filter in imem_account
generate_virtual(userid, Item, _) when is_integer(Item)-> 
    [Item];                                 %% ToDo: filter in imem_account
generate_virtual(userid, _, _) -> [];

generate_virtual(Table, Items, _MaxSize) -> 
    ?UnimplementedException({"Unsupported virtual table generation",{Table,Items}}).

generate_limit_check(Table, CurSize, MaxSize) when CurSize > MaxSize -> 
    ?ClientError({"Too much data for virtual table generation",{Table,CurSize,MaxSize}});
generate_limit_check(_,_,_) -> ok. 

send_reply_to_client(SockOrPid, Result) ->
    NewResult = {self(),Result},
    imem_server:send_resp(NewResult, SockOrPid).

update_prepare(IsSec, SKey, [{Schema,Table}|_], ColMap, ChangeList) ->
    {TableType, DefRec, Trigger} =  imem_meta:trigger_infos({Schema,Table}),
    User = if_call_mfa(IsSec, meta_field_value, [SKey, user]),
    TableInfo = {Schema,Table,TableType,list_to_tuple(DefRec),Trigger,User},
    %% transform a ChangeList   
        % [1,nop,{?EmptyMR,{def,"2","'2'"}},"2"],               %% no operation on this line
        % [5,ins,{},"99"],                                      %% insert {def,"99", undefined}
        % [3,del,{?EmptyMR,{def,"5","'5'"}},"5"],               %% delete {def,"5","'5'"}
        % [4,upd,{?EmptyMR,{def,"12","'12'"}},"112"]            %% update {def,"12","'12'"} to {def,"112","'12'"}
    %% into an UpdatePlan                                       {table} = {Schema,Table,Type}
        % [1,{table},{def,"2","'2'"},{def,"2","'2'"}],          %% no operation on this line
        % [5,{table},{},{def,"99", undefined}],                 %% insert {def,"99", undefined}
        % [3,{table},{def,"5","'5'"},{}],                       %% delete {def,"5","'5'"}
        % [4,{table},{def,"12","'12'"},{def,"112","'12'"}]      %% failing update {def,"12","'12'"} to {def,"112","'12'"}
    UpdPlan = update_prepare(IsSec, SKey, TableInfo, ColMap, ChangeList, []),
    UpdPlan.

-define(replace(__X,__Cx,__New), setelement(?MainIdx, __X, setelement(__Cx,element(?MainIdx,__X), __New))). 
-define(ins_repl(__X,__Cx,__New), setelement(__Cx,__X, __New)). 

update_prepare(_IsSec, _SKey, _TableInfo, _ColMap, [], Acc) -> Acc;
update_prepare(IsSec, SKey, {S,Tab,Typ,_,Trigger, User}=TableInfo, ColMap, [[Item,nop,Recs|_]|CList], Acc) ->
    Action = [{S,Tab,Typ}, Item, element(?MainIdx,Recs), element(?MainIdx,Recs),Trigger, User],     
    update_prepare(IsSec, SKey, TableInfo, ColMap, CList, [Action|Acc]);
update_prepare(IsSec, SKey, {S,Tab,Typ,_,Trigger, User}=TableInfo, ColMap, [[Item,del,Recs|_]|CList], Acc) ->
    Action = [{S,Tab,Typ}, Item, element(?MainIdx,Recs), {},Trigger, User],     
    update_prepare(IsSec, SKey, TableInfo, ColMap, CList, [Action|Acc]);
update_prepare(IsSec, SKey, {S,Tab,Typ,DefRec,Trigger,User}=TableInfo, ColMap, [[Item,upd,Recs|Values]|CList], Acc) ->
    % ?LogDebug("ColMap~n~p~n", [ColMap]),
    % ?LogDebug("Values~n~p~n", [Values]),
    if  
        length(Values) > length(ColMap) ->      ?ClientError({"Too many values",{Item,Values}});        
        length(Values) < length(ColMap) ->      ?ClientError({"Too few values",{Item,Values}});        
        true ->                                 ok    
    end,            
    UpdateMap = lists:sort(
        [ case CMap of
            #bind{tind=0,cind=0,func=Proj,btree=BTree} when is_function(Proj) ->
                case BTree of
                    {hd,#bind{tind=?MainIdx,cind=Cx,type=Type}=B} ->
                        Fx = fun(X) -> 
                            OldVal = Proj(X),
                            case imem_datatype:io_to_db(Item,OldVal,list_type(Type),undefined,undefined,<<>>,false,Value) of
                                OldVal ->   X;
                                NewVal ->   ?replace(X,Cx,[NewVal|tl(?BoundVal(B,X))])
                            end
                        end,     
                        {Cx,1,Fx};
                    {last,#bind{tind=?MainIdx,cind=Cx,type=Type}=B} ->
                        Pos = length(?BoundVal(B,Recs)),
                        Fx = fun(X) -> 
                            OldVal = Proj(X),
                            case imem_datatype:io_to_db(Item,OldVal,list_type(Type),undefined,undefined,<<>>,false,Value) of
                                OldVal ->   X;
                                NewVal ->   ?replace(X,Cx,lists:sublist(?BoundVal(B,X),Pos-1) ++ NewVal)
                            end
                        end,     
                        {Cx,Pos,Fx};
                    {element,PosBind,#bind{tind=?MainIdx,cind=Cx,type=Type}=B} ->    
                        Pos=imem_sql_expr:bind_tree(PosBind,Recs), 
                        Fx = fun(X) -> 
                            OldVal = Proj(X),
                            case imem_datatype:io_to_db(Item,Proj(X),tuple_type(Type,Pos),undefined,undefined,<<>>,false,Value) of
                                OldVal ->   X;
                                NewVal ->   ?replace(X,Cx,setelement(Pos,?BoundVal(B,X),NewVal))
                            end
                        end,     
                        {Cx,Pos,Fx};
                    {nth,PosBind,#bind{tind=?MainIdx,cind=Cx,type=Type}=B} ->
                        Pos = imem_sql_expr:bind_tree(PosBind,Recs),
                        Fx = fun(X) -> 
                            OldVal = Proj(X),
                            case imem_datatype:io_to_db(Item,Proj(X),list_type(Type),undefined,undefined,<<>>,false,Value) of
                                OldVal ->               
                                    X;
                                NewVal1 when Pos==1 ->  
                                    ?replace(X,Cx,[NewVal1|tl(?BoundVal(B,X))]);
                                NewVal2 ->              
                                    Old = ?BoundVal(B,X),
                                    ?replace(X,Cx,lists:sublist(Old,Pos-1) ++ NewVal2 ++ lists:nthtail(Old,Pos))
                            end 
                        end,     
                        {Cx,Pos,Fx};
                    Other ->    ?SystemException({"Internal error, bad projection binding",{Item,Other}})
                end;
            #bind{tind=0,cind=0} ->  
                ?SystemException({"Internal update error, constant projection binding",{Item,CMap}});
            #bind{tind=?MainIdx,cind=Cx,type=T,len=L,prec=P,default=D} ->
                Fx = fun(X) -> 
                    ?replace(X,Cx,imem_datatype:io_to_db(Item,?BoundVal(CMap,X),T,L,P,D,false,Value))
                end,     
                {Cx,0,Fx}
          end
          || 
          {#bind{readonly=R}=CMap,Value} 
          <- lists:zip(ColMap,Values), R==false, Value /= ?navio
        ]),    
    UpdatedRecs = update_recs(Recs, UpdateMap),
    NewRec = if_call_mfa(IsSec, apply_validators, [SKey, DefRec, element(?MainIdx, UpdatedRecs), Tab]),
    Action = [{S,Tab,Typ}, Item, element(?MainIdx,Recs), NewRec,Trigger, User],     
    update_prepare(IsSec, SKey, TableInfo, ColMap, CList, [Action|Acc]);
update_prepare(IsSec, SKey, {S,Tab,Typ,DefRec,Trigger,User}=TableInfo, ColMap, [[Item,ins,_|Values]|CList], Acc) ->
    % ?Debug("ColMap~n~p~n", [ColMap]),
    % ?Debug("Values~n~p~n", [Values]),
    if  
        length(Values) > length(ColMap) ->      ?ClientError({"Too many values",{Item,Values}});        
        length(Values) < length(ColMap) ->      ?ClientError({"Not enough values",{Item,Values}});        
        true ->                                 ok    
    end,            
    InsertMap = lists:sort(
        [ case CMap of
            #bind{tind=0,cind=0,func=Proj,btree=BTree} when is_function(Proj) ->
                case BTree of
                    {hd,#bind{tind=?MainIdx,cind=Cx,type=Type}} ->
                        Fx = fun(X) -> 
                            NewVal = imem_datatype:io_to_db(Item,<<>>,list_type(Type),undefined,undefined,<<>>,false,Value),
                            ?ins_repl(X,Cx,[NewVal])
                        end,     
                        {Cx,1,Fx};
                    {element,Pos,#bind{tind=?MainIdx,cind=Cx,name=Name,type=Type}} when is_number(Pos) ->    
                        Fx = fun(X) -> 
                            NewVal = imem_datatype:io_to_db(Item,<<>>,tuple_type(Type,Pos),undefined,undefined,<<>>,false,Value),
                            OldList = case element(Cx,X) of
                                T when is_tuple(T) ->   tuple_to_list(T);
                                _ ->                    []
                            end,
                            NewPos = length(OldList) + 1,
                            case Pos of
                                1 ->        ?ins_repl(X,Cx,{NewVal}); 
                                NewPos ->   ?ins_repl(X,Cx,list_to_tuple(OldList ++ [NewVal]));
                                _ ->        ?ClientError({"Missing tuple element",{Item,Name,NewPos}})
                            end
                        end,     
                        {Cx,Pos,Fx};
                    {nth,Pos,#bind{tind=?MainIdx,cind=Cx,name=Name,type=Type}} when is_number(Pos) ->
                        Fx = fun(X) -> 
                            NewVal = imem_datatype:io_to_db(Item,<<>>,list_type(Type),undefined,undefined,<<>>,false,Value),
                            OldList = case element(Cx,X) of
                                L when is_list(L) ->    L;
                                _ ->                    []
                            end,
                            NewPos = length(OldList) + 1,
                            case Pos of
                                1 ->        ?ins_repl(X,Cx,[NewVal]); 
                                NewPos ->   ?ins_repl(X,Cx,OldList ++ [NewVal]);
                                _ ->        ?ClientError({"Missing list element",{Item,Name,NewPos}})
                            end
                        end,     
                        {Cx,Pos,Fx};
                    Other ->    ?SystemException({"Internal error, bad projection binding",{Item,Other}})
                end;
            #bind{tind=0,cind=0} ->  
                ?SystemException({"Internal update error, constant projection binding",{Item,CMap}});
            #bind{tind=?MainIdx,cind=Cx,type=T,len=L,prec=P,default=D} ->
                Fx = fun(X) -> 
                    ?ins_repl(X,Cx,imem_datatype:io_to_db(Item,?nav,T,L,P,D,false,Value))
                end,     
                {Cx,0,Fx}
          end
          || 
          {#bind{readonly=R}=CMap,Value} 
          <- lists:zip(ColMap,Values), R==false, Value /= ?navio
        ]),    
    NewRec = if_call_mfa(IsSec, apply_validators, [SKey, DefRec, update_recs(DefRec, InsertMap), Tab]),
    Action = [{S,Tab,Typ}, Item, {},  NewRec,Trigger, User],     
    update_prepare(IsSec, SKey, TableInfo, ColMap, CList, [Action|Acc]);
update_prepare(_IsSec, _SKey, _TableInfo, _ColMap, [CLItem|_], _Acc) ->
    ?ClientError({"Invalid format of change list", CLItem}).

update_recs(Recs, []) -> Recs;
update_recs(Recs, [{_Cx,_Pos,Fx}|UpdateMap]) ->
    % ?LogDebug("Update rec ~p:~p ~n~p~n", [_Cx,_Pos,Recs]),
    NewRecs = Fx(Recs),
    % ?LogDebug("Updated rec ~n~p~n", [NewRecs]),
    update_recs(NewRecs, UpdateMap).

list_type(list) -> term;
list_type([Type]) when is_atom(Type) -> Type;
list_type(Other) -> ?ClientError({"Invalid list type",Other}).

tuple_type(tuple,_) -> term;
tuple_type({Type},_) when is_atom(Type) -> Type;
tuple_type(T,Pos) when is_tuple(T),(size(T)>=Pos),is_atom(element(Pos,T)) -> element(Pos,T);
tuple_type(Other,_) -> ?ClientError({"Invalid tuple type",Other}).

% update_bag(IsSec, SKey, Table, ColMap, [C|CList]) ->
%     ?UnimplementedException({"Cursor update not supported for bag tables",Table}).

receive_raw() ->
    receive_raw(50, []).

receive_raw(Timeout) ->
    receive_raw(Timeout, []).

receive_raw(Timeout,Acc) ->    
    case receive 
            R ->    ?Debug("receive_raw got:~n~p~n", [R]),
                    R
        after Timeout ->
            stop
        end of
        stop ->         lists:reverse(Acc);
        {_,Result} ->   receive_raw(Timeout,[Result|Acc])
    end.

receive_recs(StmtResult, Complete) ->
    receive_recs(StmtResult,Complete,50,[]).

receive_recs(StmtResult, Complete, Timeout) ->
    receive_recs(StmtResult, Complete, Timeout,[]).

receive_recs(#stmtResult{stmtRef=StmtRef}=StmtResult,Complete,Timeout,Acc) ->    
    case receive
            R ->    % ?Debug("~p got:~n~p~n", [erlang:now(),R]),
                    R
        after Timeout ->
            stop
        end of
        stop ->     
            Unchecked = case Acc of
                [] ->                       
%                    [{StmtRef,[],Complete}];
                    throw({no_response,{expecting,Complete}});
                [{StmtRef,{_,Complete}}|_] -> 
                    lists:reverse(Acc);
                [{StmtRef,{L1,C1}}|_] ->
                    throw({bad_complete,{StmtRef,{L1,C1}}});
                Res ->                      
                    throw({bad_receive,lists:reverse(Res)})
            end,
            case lists:usort([element(1, SR) || SR <- Unchecked]) of
                [StmtRef] ->                
                    List = lists:flatten([element(1,element(2, T)) || T <- Unchecked]),
                    if 
                        length(List) =< 10 ->
                            ?Debug("Received:~n~p~n", [List]);
                        true ->
                            ?Debug("Received: ~p items ~p~n~p~n~p~n", [length(List),hd(List), '...', lists:last(List)])
                    end,            
                    List;
                StmtRefs ->
                    throw({bad_stmtref,lists:delete(StmtRef, StmtRefs)})
            end;
        {_, Result} ->   
            receive_recs(StmtResult,Complete,Timeout,[Result|Acc])
    end.

result_tuples(List,RowFun) when is_list(List), is_function(RowFun) ->  
    [list_to_tuple(R) || R <- lists:map(RowFun,List)].

%% --Interface functions  (calling imem_if for now, not exported) ---------

if_call_mfa(IsSec,Fun,Args) ->
    case IsSec of
        true -> apply(imem_sec,Fun,Args);
        _ ->    apply(imem_meta, Fun, lists:nthtail(1, Args))
    end.

%% TESTS ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

setup() -> 
    ?imem_test_setup,
    catch imem_meta:drop_table(def),
    catch imem_meta:drop_table(tuple_test),
    catch imem_meta:drop_table(fun_test).

teardown(_SKey) -> 
    catch imem_meta:drop_table(def),
    catch imem_meta:drop_table(tuple_test),
    catch imem_meta:drop_table(fun_test),
    ?LogDebug("test teardown....~n",[]),
    ?imem_test_teardown.

db_test_() ->
    {timeout, 20000, 
        {
            setup,
            fun setup/0,
            fun teardown/1,
            {with, [
                  fun test_without_sec/1
                , fun test_with_sec/1
            ]}
        }
    }.
    
test_without_sec(_) -> 
    test_with_or_without_sec(false).

test_with_sec(_) ->
    test_with_or_without_sec(true).

test_with_or_without_sec(IsSec) ->
    try
        ClEr = 'ClientError',
        % SeEx = 'SecurityException',

        ?LogDebug("----------------------------------~n"),
        ?LogDebug("---TEST--- ~p ----Security ~p", [?MODULE, IsSec]),
        ?LogDebug("----------------------------------~n"),

        ?LogDebug("schema ~p~n", [imem_meta:schema()]),
        ?LogDebug("data nodes ~p~n", [imem_meta:data_nodes()]),
        ?assertEqual(true, is_atom(imem_meta:schema())),
        ?assertEqual(true, lists:member({imem_meta:schema(),node()}, imem_meta:data_nodes())),

        ?assertEqual([],receive_raw()),

        SKey=case IsSec of
            true ->     ?imem_test_admin_login();
            false ->    none
        end,

    %% test table tuple_test

        ?assertEqual(ok, imem_sql:exec(SKey, "
            create table fun_test (
                col0 integer
              , col1 integer default fun(_,Rec) -> element(2,Rec)*element(2,Rec) end.
            );"
            , 0, [{schema,imem}], IsSec)),

        Sql0a = "insert into fun_test (col0) values (12)",  
        ?LogDebug("Sql0a:~n~s~n", [Sql0a]),
        ?assertEqual([{fun_test,12,144}], imem_sql:exec(SKey, Sql0a, 0, [{schema,imem}], IsSec)),

        TT0aRows = lists:sort(if_call_mfa(IsSec,read,[SKey, fun_test])),
        ?LogDebug("fun_test~n~p~n", [TT0aRows]),
        [{fun_test,Col0a,Col1a}] = TT0aRows,
        ?assertEqual(Col0a*Col0a, Col1a),

        SR00 = exec(SKey,query00, 15, IsSec, "select col0, col1 from fun_test;"),
        ?assertEqual(ok, fetch_async(SKey,SR00,[],IsSec)),
        [{<<"12">>,<<"144">>}] = receive_tuples(SR00,true),

        ChangeList00 = [
          [1,upd,{?EmptyMR,{fun_test,12,144}},<<"13">>,<<"0">>] 
        ],
        ?assertEqual(ok, update_cursor_prepare(SKey, SR00, IsSec, ChangeList00)),
        ?assertEqual([{1,{?EmptyMR,{fun_test,13,169}}}], update_cursor_execute(SKey, SR00, IsSec, optimistic)),        

        ChangeList01 = [
          [2,ins,{?EmptyMR,{}},<<"15">>,<<"1">>] 
        ],
        ?assertEqual(ok, update_cursor_prepare(SKey, SR00, IsSec, ChangeList01)),
        ?assertEqual([{2,{?EmptyMR,{fun_test,15,225}}}], update_cursor_execute(SKey, SR00, IsSec, optimistic)),        

        ?assertEqual(ok, fetch_close(SKey,SR00,IsSec)),
        ?assertEqual(ok, fetch_async(SKey,SR00,[],IsSec)),
        [{<<"13">>,<<"169">>},{<<"15">>,<<"225">>}] = receive_tuples(SR00,true),
        ?assertEqual(ok, close(SKey, SR00)),

        ?assertEqual(ok, imem_sql:exec(SKey, "drop table fun_test;", 0, [{schema,imem}], IsSec)),
        ?LogDebug("dropped table ~p~n", [fun_test]),

        ?assertEqual(ok, imem_sql:exec(SKey, "
            create table tuple_test (
            col1 tuple, 
            col2 list,
            col3 tuple(2),
            col4 integer
            );"
            , 0, [{schema,imem}], IsSec)),

        Sql1a = "
            insert into tuple_test (
                col1,col2,col3,col4
            ) values (
                 '{key1,nonode@nohost}'
                ,'[key1a,key1b,key1c]'
                ,'{key1,{key1a,key1b}}'
                ,1 
            );",  
        ?LogDebug("Sql1a:~n~s~n", [Sql1a]),
        ?assertEqual( [{tuple_test,{key1,nonode@nohost},[key1a,key1b,key1c],{key1,{key1a,key1b}},1}]
                    , imem_sql:exec(SKey, Sql1a, 0, [{schema,imem}], IsSec)
                    ),

        Sql1b = "
            insert into tuple_test (
                col1,col2,col3,col4
            ) values (
                 '{key2,somenode@somehost}'
                ,'[key2a,key2b,3,4]'
                ,'{a,''B2''}'
                ,2 
            );",  
        ?LogDebug("Sql1b:~n~s~n", [Sql1b]),
        ?assertEqual( [{tuple_test,{key2,somenode@somehost},[key2a,key2b,3,4],{a,'B2'},2}]
                    , imem_sql:exec(SKey, Sql1b, 0, [{schema,imem}], IsSec)
                    ),

        Sql1c = "
            insert into tuple_test (
                col1,col2,col3,col4
            ) values (
                 '{key3,''nonode@nohost''}'
                ,'[key3a,key3b]'
                ,'undefined'
                ,3 
            );",  
        ?LogDebug("Sql1c:~n~s~n", [Sql1c]),
        ?assertEqual( [{tuple_test,{key3,nonode@nohost},[key3a,key3b],undefined,3}]
                    , imem_sql:exec(SKey, Sql1c, 0, [{schema,imem}], IsSec)
                    ),

        TT1Rows = lists:sort(if_call_mfa(IsSec,read,[SKey, tuple_test])),
        ?LogDebug("original table~n~p~n", [TT1Rows]),
        TT1RowsExpected=
        [{tuple_test,{key1,nonode@nohost},[key1a,key1b,key1c],{key1,{key1a,key1b}},1}
        ,{tuple_test,{key2,somenode@somehost},[key2a,key2b,3,4],{a,'B2'},2}
        ,{tuple_test,{key3,nonode@nohost},[key3a,key3b],undefined,3}
        ],
        ?assertEqual(TT1RowsExpected, TT1Rows),

        TT1a = exec(SKey,tt1a, 10, IsSec, "
            select col4 from tuple_test"
        ),
        ?assertEqual(ok, fetch_async(SKey,TT1a,[],IsSec)),
        ListTT1a = receive_tuples(TT1a,true),
        ?assertEqual(3, length(ListTT1a)),

        TT1b = exec(SKey,tt1b, 4, IsSec, "
            select
              element(1,col1)
            , element(1,col3), element(2,col3)
            , col4 
            from tuple_test where col4=2"),
        ?assertEqual(ok, fetch_async(SKey,TT1b,[],IsSec)),
        ListTT1b = receive_tuples(TT1b,true),
        ?assertEqual(1, length(ListTT1b)),

        O1 = {tuple_test,{key1,nonode@nohost},[key1a,key1b,key1c],{key1,{key1a,key1b}},1},
        O1X= {tuple_test,{keyX,nonode@nohost},[key1a,key1b,key1c],{key1,{key1a,key1b}},1},
        O2 = {tuple_test,{key2,somenode@somehost},[key2a,key2b,3,4],{a,'B2'},2},
        O2X= {tuple_test,{key2,somenode@somehost},[key2a,key2b,3,4],{a,b},undefined},
        O3 = {tuple_test,{key3,nonode@nohost},[key3a,key3b],undefined,3},

        TT1aChange = [
          [1,upd,{?EmptyMR,O1},<<"keyX">>,<<"key1">>,<<"{key1a,key1b}">>,<<"1">>] 
        , [2,upd,{?EmptyMR,O2},<<"key2">>,<<"a">>,<<"b">>,<<"">>] 
        , [3,upd,{?EmptyMR,O3},<<"key3">>,<<"'$not_a_value'">>,<<"'$not_a_value'">>,<<"3">>]
        ],
        ?assertEqual(ok, update_cursor_prepare(SKey, TT1b, IsSec, TT1aChange)),
        update_cursor_execute(SKey, TT1b, IsSec, optimistic),        
        TT1aRows = lists:sort(if_call_mfa(IsSec,read,[SKey, tuple_test])),
        ?assertNotEqual(TT1Rows,TT1aRows),
        ?LogDebug("changed table~n~p~n", [TT1aRows]),
        ?assert(lists:member(O1X,TT1aRows)),
        ?assert(lists:member(O2X,TT1aRows)),
        ?assert(lists:member(O3,TT1aRows)),

        O4X= {tuple_test,{key4},undefined,{<<"">>,<<"">>},4},

        TT1bChange = [[4,ins,{},<<"key4">>,<<"">>,<<"">>,<<"4">>]],
        ?assertEqual(ok, update_cursor_prepare(SKey, TT1b, IsSec, TT1bChange)),
        update_cursor_execute(SKey, TT1b, IsSec, optimistic),        
        TT1bRows = lists:sort(if_call_mfa(IsSec,read,[SKey, tuple_test])),
        ?LogDebug("TT1bRows~n~p~n", [TT1bRows]),
        ?assert(lists:member(O4X,TT1bRows)),

        TT2a = exec(SKey,tt2, 4, IsSec, "
            select 
              col1
            , hd(col2), nth(2,col2)
            , col4
            from tuple_test
            where col4=1"),
        ?assertEqual(ok, fetch_async(SKey,TT2a,[],IsSec)),
        ListTT2a = receive_tuples(TT2a,true),
        ?assertEqual(1, length(ListTT2a)),

        TT2aChange = [
         [5,ins,{},<<"{key5,nonode@nohost}">>,<<"a5">>,<<"b5">>,<<"5">>]
        ,[6,ins,{},<<"{key6,somenode@somehost}">>,<<"">>,<<"b6">>,<<"">>]
        ],
        O5X = {tuple_test,{key5,nonode@nohost},[a5,b5],undefined,5},
        O6X = {tuple_test,{key6,somenode@somehost},[<<"">>,b6],undefined,undefined},
        ?assertEqual(ok, update_cursor_prepare(SKey, TT2a, IsSec, TT2aChange)),
        update_cursor_execute(SKey, TT2a, IsSec, optimistic),        
        TT2aRows1 = lists:sort(if_call_mfa(IsSec,read,[SKey, tuple_test])),
        ?LogDebug("appended table~n~p~n", [TT2aRows1]),
        ?assert(lists:member(O5X,TT2aRows1)),
        ?assert(lists:member(O6X,TT2aRows1)),

        % ?assertEqual(ok, close(SKey, TT1b)),
        % ?assertEqual(ok, close(SKey, TT2a)),

        ?assertEqual(ok, imem_sql:exec(SKey, "drop table tuple_test;", 0, [{schema,imem}], IsSec)),
        ?LogDebug("dropped table ~p~n", [tuple_test]),

    %% test table def

        ?assertEqual(ok, imem_sql:exec(SKey, "
            create table def (
                col1 varchar2(10), 
                col2 integer
            );"
            , 0, [{schema,imem}], IsSec)),

        ?assertEqual(ok, insert_range(SKey, 15, def, imem, IsSec)),

        TableRows1 = lists:sort(if_call_mfa(IsSec,read,[SKey, def])),
        [Meta] = if_call_mfa(IsSec, read, [SKey, ddTable, {imem,def}]),
        ?LogDebug("Meta table~n~p~n", [Meta]),
        ?LogDebug("original table~n~p~n", [TableRows1]),

        SR0 = exec(SKey,query0, 15, IsSec, "select * from def;"),
        try
            ?assertEqual(ok, fetch_async(SKey,SR0,[],IsSec)),
            List0 = receive_tuples(SR0,true),
            ?assertEqual(15, length(List0)),
            ?assertEqual([], receive_raw())
        after
            ?assertEqual(ok, close(SKey, SR0))
        end,

        SR0a = exec(SKey,query0a, 4, IsSec, "select rownum from def;"),
        ?assertEqual(ok, fetch_async(SKey,SR0a,[],IsSec)),
        ?assertEqual([{<<"1">>},{<<"2">>},{<<"3">>},{<<"4">>}], receive_tuples(SR0a,false)),
        ?assertEqual([], receive_raw()),
        ?assertEqual(ok, fetch_async(SKey,SR0a,[],IsSec)),
        ?assertEqual([{<<"5">>},{<<"6">>},{<<"7">>},{<<"8">>}], receive_tuples(SR0a,false)),
        ?assertEqual([], receive_raw()),
        ?assertEqual(ok, fetch_async(SKey,SR0a,[],IsSec)),
        ?assertEqual([{<<"9">>},{<<"10">>},{<<"11">>},{<<"12">>}], receive_tuples(SR0a,false)),
        ?assertEqual(ok, fetch_async(SKey,SR0a,[],IsSec)),
        ?assertEqual([{<<"13">>},{<<"14">>},{<<"15">>}], receive_tuples(SR0a,true)),
        ?assertEqual([], receive_raw()),
        ?assertEqual(ok, close(SKey, SR0a)),

        SR1 = exec(SKey,query1, 4, IsSec, "select col1, col2 from def;"),
        ?assertEqual(ok, fetch_async(SKey,SR1,[],IsSec)),
        List1a = receive_tuples(SR1,false),
        ?assertEqual(4, length(List1a)),
        ?assertEqual([], receive_raw()),
        ?assertEqual(ok, fetch_async(SKey,SR1,[],IsSec)),
        List1b = receive_tuples(SR1,false),
        ?assertEqual(4, length(List1b)),
        ?assertEqual([], receive_raw()),
        ?assertEqual(ok, fetch_async(SKey,SR1,[],IsSec)),
        List1c = receive_tuples(SR1,false),
        ?assertEqual(4, length(List1c)),
        ?assertEqual(ok, fetch_async(SKey,SR1,[],IsSec)),
        List1d = receive_tuples(SR1,true),
        ?assertEqual(3, length(List1d)),
        ?assertEqual([], receive_raw()),

        %% ChangeList2 = [[OP,ID] ++ L || {OP,ID,L} <- lists:zip3([nop, ins, del, upd], [1,2,3,4], lists:map(RowFun2,List2a))],
        %% ?LogDebug("change list~n~p~n", [ChangeList2]),
        ChangeList2 = [
        [4,upd,{?EmptyMR,{def,<<"12">>,12}},<<"112">>,<<"12">>] 
        ],
        ?assertEqual(ok, update_cursor_prepare(SKey, SR1, IsSec, ChangeList2)),
        update_cursor_execute(SKey, SR1, IsSec, optimistic),        
        TableRows2 = lists:sort(if_call_mfa(IsSec,read,[SKey, def])),
        ?LogDebug("changed table~n~p~n", [TableRows2]),
        ?assert(TableRows1 /= TableRows2),
        ?assertEqual(length(TableRows1), length(TableRows2)),
        ?assertEqual(true, lists:member({def,<<"112">>,12},TableRows2)),
        ?assertEqual(false, lists:member({def,"12",12},TableRows2)),

        ChangeList3 = [
        [1,nop,{?EmptyMR,{def,<<"2">>,2}},<<"2">>,<<"2">>],         %% no operation on this line
        [5,ins,{},<<"99">>, <<"undefined">>],             %% insert {def,"99", undefined}
        [3,del,{?EmptyMR,{def,<<"5">>,5}},<<"5">>,<<"5">>],         %% delete {def,"5",5}
        [4,upd,{?EmptyMR,{def,<<"112">>,12}},<<"112">>,<<"12">>],   %% nop update {def,"112",12}
        [6,upd,{?EmptyMR,{def,<<"10">>,10}},<<"10">>,<<"110">>]     %% update {def,"10",10} to {def,"10",110}
        ],
        ExpectedRows3 = [
        {def,<<"2">>,2},                            %% no operation on this line
        {def,<<"99">>,undefined},                   %% insert {def,"99", undefined}
        {def,<<"10">>,110},                         %% update {def,"10",10} to {def,"10",110}
        {def,<<"112">>,12}                          %% nop update {def,"112",12}
        ],
        RemovedRows3 = [
        {def,<<"5">>,5}                             %% delete {def,"5",5}
        ],
        ExpectedKeys3 = [
        {1,{?EmptyMR,{def,<<"2">>,2}}},
        {3,{?EmptyMR,{}}},
        {4,{?EmptyMR,{def,<<"112">>,12}}},
        {5,{?EmptyMR,{def,<<"99">>,undefined}}},
        {6,{?EmptyMR,{def,<<"10">>,110}}}
        ],
        ?assertEqual(ok, update_cursor_prepare(SKey, SR1, IsSec, ChangeList3)),
        ChangedKeys3 = update_cursor_execute(SKey, SR1, IsSec, optimistic),        
        TableRows3 = lists:sort(if_call_mfa(IsSec,read,[SKey, def])),
        ?LogDebug("changed table~n~p~n", [TableRows3]),
        [?assert(lists:member(R,TableRows3)) || R <- ExpectedRows3],
        [?assertNot(lists:member(R,TableRows3)) || R <- RemovedRows3],
        ?assertEqual(ExpectedKeys3,lists:sort([ {I,setelement(?MetaIdx,C,?EmptyMR)} || {I,C} <- ChangedKeys3])),

        ?assertEqual(ok, if_call_mfa(IsSec,truncate_table,[SKey, def])),
        ?assertEqual(0,imem_meta:table_size(def)),
        ?assertEqual(ok, insert_range(SKey, 5, def, imem, IsSec)),
        ?assertEqual(5,imem_meta:table_size(def)),

        ?assertEqual(ok, close(SKey, SR1)),

        SR2 = exec(SKey,query2, 100, IsSec, "
            select rownum + 1  as RowNumPlus
            from def 
            where col2 <= 5;"
        ),
        try
            ?assertEqual(ok, fetch_async(SKey,SR2,[{tail_mode,true}],IsSec)),
            List2a = receive_tuples(SR2,true),
            ?assertEqual(5, length(List2a)),
            ?assertEqual([{<<"2">>},{<<"3">>},{<<"4">>},{<<"5">>},{<<"6">>}], List2a),
            ?assertEqual([], receive_raw()),
            ?assertEqual(ok, insert_range(SKey, 10, def, imem, IsSec)),
            ?assertEqual(10,imem_meta:table_size(def)),  %% unchanged, all updates
            List2b = receive_tuples(SR2,tail),
            ?assertEqual(5, length(List2b)),             %% 10 updates, 5 filtered with TailFun()           
            ?assertEqual([{<<"7">>},{<<"8">>},{<<"9">>},{<<"10">>},{<<"11">>}], List2b),
            ?assertEqual(ok, fetch_close(SKey, SR2, IsSec)),
            ?assertEqual(ok, insert_range(SKey, 5, def, imem, IsSec)),
            ?assertEqual([], receive_raw())        
        after
            ?assertEqual(ok, close(SKey, SR2))
        end,

        ?assertEqual(ok, if_call_mfa(IsSec,truncate_table,[SKey, def])),
        ?assertEqual(0,imem_meta:table_size(def)),
        ?assertEqual(ok, insert_range(SKey, 5, def, imem, IsSec)),
        ?assertEqual(5,imem_meta:table_size(def)),

        SR3 = exec(SKey,query3, 2, IsSec, "
            select rownum 
            from def t1, def t2 
            where t2.col1 = t1.col1 
            and t2.col2 <= 5;"
        ),
        try
            ?assertEqual(ok, fetch_async(SKey,SR3,[{tail_mode,true}],IsSec)),
            List3a = receive_tuples(SR3,false),
            ?assertEqual(2, length(List3a)),
            ?assertEqual([{<<"1">>},{<<"2">>}], List3a),
            ?assertEqual(ok, fetch_async(SKey,SR3,[{fetch_mode,push},{tail_mode,true}],IsSec)),
            List3b = receive_tuples(SR3,true),
            ?assertEqual(3, length(List3b)),    %% TODO: Should this come split into 2 + 1 rows ?
            ?assertEqual([{<<"3">>},{<<"4">>},{<<"5">>}], List3b),
            ?assertEqual(ok, insert_range(SKey, 10, def, imem, IsSec)),
            ?assertEqual(10,imem_meta:table_size(def)),
            List3c = receive_tuples(SR3,tail),
            ?assertEqual(5, length(List3c)),           
            ?assertEqual([{<<"6">>},{<<"7">>},{<<"8">>},{<<"9">>},{<<"10">>}], List3c),
            ?assertEqual(ok, fetch_close(SKey, SR3, IsSec)),
            ?assertEqual(ok, insert_range(SKey, 5, def, imem, IsSec)),
            ?assertEqual([], receive_raw())        
        after
            ?assertEqual(ok, close(SKey, SR3))
        end,

        ?assertEqual(ok, if_call_mfa(IsSec,truncate_table,[SKey, def])),
        ?assertEqual(0,imem_meta:table_size(def)),
        ?assertEqual(ok, insert_range(SKey, 10, def, imem, IsSec)),
        ?assertEqual(10,imem_meta:table_size(def)),

        SR3a = exec(SKey,query3a, 10, IsSec, "
            select rownum, t1.col2, t2.col2, t3.col2 
            from def t1, def t2, def t3 
            where t1.col2 < t2.col2 
            and t2.col2 < t3.col2
            and t3.col2 < 5"
        ),
        ?assertEqual(ok, fetch_async(SKey,SR3a,[],IsSec)),
        Cube3a = receive_tuples(SR3a,true),
        ?assertEqual(4, length(Cube3a)),
        ?assertEqual([], receive_raw()),
        ?assertEqual(ok, close(SKey, SR3a)),

        SR3b = exec(SKey,query3b, 10, IsSec, "
            select rownum, t1.col2, t2.col2, t3.col2 
            from def t1, def t2, def t3 
            where t1.col2 < t2.col2 
            and t2.col2 < t3.col2
            and t3.col2 < 6"
        ),
        ?assertEqual(ok, fetch_async(SKey,SR3b,[],IsSec)),
        Cube3b = receive_tuples(SR3b,true),
        ?assertEqual(10, length(Cube3b)),
        ?assertEqual([], receive_raw()),
        ?assertEqual(ok, close(SKey, SR3b)),

        SR3c = exec(SKey,query3c, 10, IsSec, "
            select rownum, t1.col2, t2.col2, t3.col2 
            from def t1, def t2, def t3 
            where t1.col2 < t2.col2 
            and t2.col2 < t3.col2
            and t3.col2 < 7"
        ),
        ?assertEqual(ok, fetch_async(SKey,SR3c,[],IsSec)),
        Cube3c1 = receive_tuples(SR3c,true),
        ?assertEqual(20, length(Cube3c1)),      %% TODO: Treaming join evaluation needed to keep this down at 10
        ?assertEqual(lists:seq(1,20), lists:sort([ list_to_integer(binary_to_list(element(1,Res))) || Res <- Cube3c1])),
        ?assertEqual([], receive_raw()),
        ?assertEqual(ok, close(SKey, SR3c)),

        SR3d = exec(SKey,query3d, 10, IsSec, "
            select rownum 
            from def t1, def t2, def t3"
        ),
        ?assertEqual(ok, fetch_async(SKey,SR3d,[],IsSec)),
%        [?assertEqual(100, length(receive_tuples(SR3d,false))) || _ <- lists:seq(1,9)],   %% TODO: should come in chunks
        ?assertEqual(1000, length(receive_tuples(SR3d,true))),
        ?assertEqual(ok, close(SKey, SR3d)),

        SR3e = exec(SKey,query3e, 10, IsSec, "
            select rownum 
            from def, def, def, def"
        ),
        ?assertEqual(ok, fetch_async(SKey,SR3e,[],IsSec)),
        % ?assertEqual(10000, length(receive_tuples(SR3e,true))),           %% 50 ms is not enough to fetch 10'000 rows
        % ?assertEqual(10000, length(receive_tuples(SR3e,true,1500,[]))),   %% works but times out the test
        ?assertEqual(ok, close(SKey, SR3e)),                                %% test for stmt teardown while joining big result

        SR4 = exec(SKey,query4, 5, IsSec, "
            select col1 from def;"
        ),
        try
            ?assertEqual(ok, fetch_async(SKey,SR4,[],IsSec)),
            List4a = receive_tuples(SR4,false),
            ?assertEqual(5, length(List4a)),
            ?LogDebug("trying to insert one row before fetch complete~n", []),
            ?assertEqual(ok, insert_range(SKey, 1, def, imem, IsSec)),
            ?LogDebug("completed insert one row before fetch complete~n", []),
            ?assertEqual(ok, fetch_async(SKey,SR4,[{tail_mode,true}],IsSec)),
            List4b = receive_tuples(SR4,true),
            ?assertEqual(5, length(List4b)),
            ?assertEqual(ok, insert_range(SKey, 1, def, imem, IsSec)),
            List4c = receive_tuples(SR4,tail),
            ?assertEqual(1, length(List4c)),
            ?assertEqual(ok, insert_range(SKey, 1, def, imem, IsSec)),
            ?assertEqual(ok, insert_range(SKey, 11, def, imem, IsSec)),
            ?assertEqual(11,imem_meta:table_size(def)),
            List4d = receive_tuples(SR4,tail),
            ?assertEqual(12, length(List4d)),
            ?LogDebug("12 tail rows received in single packets~n", []),
            ?assertEqual(ok, fetch_async(SKey,SR4,[],IsSec)),
            Result4e = receive_raw(),
            ?LogDebug("reject received ~p~n", [Result4e]),
            [{StmtRef4, {error, {ClEr,Reason4e}}}] = Result4e, 
            ?assertEqual("Fetching in tail mode, execute fetch_close before fetching from start again",Reason4e),
            ?assertEqual(StmtRef4,SR4#stmtResult.stmtRef),
            ?assertEqual(ok, fetch_close(SKey, SR4, IsSec)),
            ?assertEqual(ok, insert_range(SKey, 5, def, imem, IsSec)),
            ?assertEqual([], receive_raw())
        after
            ?assertEqual(ok, close(SKey, SR4))
        end,

        SR5 = exec(SKey,query5, 100, IsSec, "
            select to_name(qname) from all_tables"
        ),
        try
            ?assertEqual(ok, fetch_async(SKey, SR5, [], IsSec)),
            List5a = receive_tuples(SR5,true),
            ?assert(lists:member({<<"imem.def">>},List5a)),
            ?assert(lists:member({<<"imem.ddTable">>},List5a)),
            ?LogDebug("first read success (async)~n", []),
            ?assertEqual(ok, fetch_async(SKey, SR5, [], IsSec)),
            [{StmtRef5, {error, Reason5a}}] = receive_raw(),
            ?assertEqual({'ClientError',
                "Fetch is completed, execute fetch_close before fetching from start again"},
                Reason5a),
            ?assertEqual(StmtRef5,SR5#stmtResult.stmtRef),
            ?assertEqual(ok, fetch_close(SKey, SR5, IsSec)),
            ?assertEqual(ok, fetch_async(SKey, SR5, [], IsSec)),
            List5b = receive_tuples(SR5,true),
            D12 = List5a--List5b,
            D21 = List5b--List5a,
            ?assert( (D12==[]) orelse (list:usort([imem_meta:is_local_time_partitioned_table(N) || {N} <- D12]) == [true]) ),
            ?assert( (D21==[]) orelse (list:usort([imem_meta:is_local_time_partitioned_table(N) || {N} <- D21]) == [true]) ),
            ?LogDebug("second read success (async)~n", []),
            ?assertException(throw,
                {'ClientError',"Fetch is completed, execute fetch_close before fetching from start again"},
                fetch_recs_sort(SKey, SR5, {self(), make_ref()}, 1000, IsSec)
            ),
            ?assertEqual(ok, fetch_close(SKey, SR5, IsSec)), % actually not needed here, fetch_recs does it
            List5c = fetch_recs_sort(SKey, SR5, {self(), make_ref()}, 1000, IsSec),
            ?assertEqual(length(List5b), length(List5c)),
            ?assertEqual(lists:sort(List5b), lists:sort(result_tuples(List5c,SR5#stmtResult.rowFun))),
            ?LogDebug("third read success (sync)~n", [])
        after
            ?assertEqual(ok, close(SKey, SR4))
        end,

        RowCount6 = imem_meta:table_size(def),
        SR6 = exec(SKey,query6, 3, IsSec, "
            select col1 from def;"
        ),
        try
            ?assertEqual(ok, fetch_async(SKey, SR6, [{fetch_mode,push}], IsSec)),
            List6a = receive_tuples(SR6,true),
            ?assertEqual(RowCount6, length(List6a)),
            ?assertEqual([], receive_raw()),
            ?assertEqual(ok, insert_range(SKey, 5, def, imem, IsSec)),
            ?assertEqual([], receive_raw())            
        after
            ?assertEqual(ok, close(SKey, SR6))
        end,

        SR7 = exec(SKey,query7, 3, IsSec, "
            select col1 from def;"
        ),
        try
            ?assertEqual(ok, fetch_async(SKey, SR7, [{fetch_mode,skip},{tail_mode,true}], IsSec)),
            ?assertEqual([], receive_raw()),
            ?assertEqual(ok, insert_range(SKey, 5, def, imem, IsSec)),
            List7 = receive_tuples(SR7,tail),
            ?assertEqual(5, length(List7)),
            ?assertEqual([], receive_raw()),
            ?assertEqual(ok, fetch_close(SKey, SR7, IsSec)),
            ?assertEqual(ok, insert_range(SKey, 5, def, imem, IsSec)),
            ?assertEqual([], receive_raw())
        after
            ?assertEqual(ok, close(SKey, SR7))
        end,

        SR7a = exec(SKey,query7a, 3, IsSec, [{params,[{<<":key">>,<<"integer">>,<<"0">>,[<<"3">>]}]}], "
            select col2 from def where col2 = :key ;"
        ),
        try
            ?assertEqual(ok, fetch_async(SKey, SR7a, [], IsSec)),
            List7a = receive_tuples(SR7a,true),
            ?assertEqual([{<<"3">>}], List7a),
            ?assertEqual(ok, fetch_close(SKey, SR7a, IsSec)),
            ?assertEqual(ok, fetch_async(SKey, SR7a, [{params,[{<<":key">>,<<"integer">>,<<"0">>,[<<"5">>]}]}], IsSec)),
            List7a1 = receive_tuples(SR7a,true),
            ?assertEqual([{<<"5">>}], List7a1),
            ?assertEqual(ok, fetch_close(SKey, SR7a, IsSec))
        after
            ?assertEqual(ok, close(SKey, SR7a))
        end,

        SR7b = exec(SKey,query7b, 3, IsSec, [{params,[{<<":key">>,<<"integer">>,<<"0">>,[<<"3">>]}]}], "
            select systimestamp, :key from def where col2 = :key ;"
        ),
        try
            ?assertEqual(ok, fetch_async(SKey, SR7b, [{params,[{<<":key">>,<<"integer">>,<<"0">>,[<<"4">>]}]}], IsSec)),
            List7b = receive_tuples(SR7b,true),
            ?assertMatch([{<<_:16,$.,_:16,$.,_:32,32,_:16,$:,_:16,$:,_:16,$.,_:48>>,<<"4">>}], List7b),
            ?assertEqual(ok, fetch_close(SKey, SR7b, IsSec)),
            ?assertEqual(ok, fetch_async(SKey, SR7b, [{params,[{<<":key">>,<<"integer">>,<<"0">>,[<<"6">>]}]}], IsSec)),
            List7b1 = receive_tuples(SR7b,true),
            ?assertMatch([{<<_:16,$.,_:16,$.,_:32,32,_:16,$:,_:16,$:,_:16,$.,_:48>>,<<"6">>}], List7b1),
            ?assertNotEqual(List7b,List7b1),
            ?assertEqual(ok, fetch_close(SKey, SR7b, IsSec))
        after
            ?assertEqual(ok, close(SKey, SR7b))
        end,

        SR8 = exec(SKey,query8, 100, IsSec, "
            select 
                  col1 as c1
                , col2 
            from def 
            where col1 < '4' 
            order by col2 desc;"
        ), 
        % ?LogDebug("StmtCols8 ~p~n", [SR8#stmtResult.stmtCols]),
        % ?LogDebug("SortSpec8 ~p~n", [SR8#stmtResult.sortSpec]),
        ?assertEqual([{2,<<"desc">>}], SR8#stmtResult.sortSpec),
        try
            ?assertEqual(ok, fetch_async(SKey, SR8, [], IsSec)),
            List8a = receive_recs(SR8,true),
            ?assertEqual([{<<"11">>,<<"11">>},{<<"10">>,<<"10">>},{<<"3">>,<<"3">>},{<<"2">>,<<"2">>},{<<"1">>,<<"1">>}], result_tuples_sort(List8a,SR8#stmtResult.rowFun, SR8#stmtResult.sortFun)),
            Result8a = filter_and_sort(SKey, SR8, {'and',[]}, [{2,2,<<"asc">>}], [], IsSec),
            ?LogDebug("Result8a ~p~n", [Result8a]),
            {ok, Sql8b, SF8b} = Result8a,
            Sorted8b = [{<<"1">>,<<"1">>},{<<"10">>,<<"10">>},{<<"11">>,<<"11">>},{<<"2">>,<<"2">>},{<<"3">>,<<"3">>}],
            ?assertEqual(Sorted8b, result_tuples_sort(List8a,SR8#stmtResult.rowFun, SF8b)),
            Expected8b = "select col1 c1, col2 from def where col1 < '4' order by col1 asc",
            ?assertEqual(Expected8b, string:strip(binary_to_list(Sql8b))),

            {ok, Sql8c, SF8c} = filter_and_sort(SKey, SR8, {'and',[{1,[<<"1">>,<<"2">>,<<"3">>]}]}, [{?MainIdx,2,<<"asc">>}], [1], IsSec),
            ?assertEqual(Sorted8b, result_tuples_sort(List8a,SR8#stmtResult.rowFun, SF8c)),
            ?LogDebug("Sql8c ~p~n", [Sql8c]),
            Expected8c = "select col1 c1 from def where imem.def.col1 in ('1', '2', '3') and col1 < '4' order by col1 asc",
            ?assertEqual(Expected8c, string:strip(binary_to_list(Sql8c))),

            {ok, Sql8d, SF8d} = filter_and_sort(SKey, SR8, {'or',[{1,[<<"3">>]}]}, [{?MainIdx,2,<<"asc">>},{?MainIdx,3,<<"desc">>}], [2], IsSec),
            ?assertEqual(Sorted8b, result_tuples_sort(List8a,SR8#stmtResult.rowFun, SF8d)),
            ?LogDebug("Sql8d ~p~n", [Sql8d]),
            Expected8d = "select col2 from def where imem.def.col1 = '3' and col1 < '4' order by col1 asc, col2 desc",
            ?assertEqual(Expected8d, string:strip(binary_to_list(Sql8d))),

            {ok, Sql8e, SF8e} = filter_and_sort(SKey, SR8, {'or',[{1,[<<"3">>]},{2,[<<"3">>]}]}, [{?MainIdx,2,<<"asc">>},{?MainIdx,3,<<"desc">>}], [2,1], IsSec),
            ?assertEqual(Sorted8b, result_tuples_sort(List8a,SR8#stmtResult.rowFun, SF8e)),
            ?LogDebug("Sql8e ~p~n", [Sql8e]),
            Expected8e = "select col2, col1 c1 from def where (imem.def.col1 = '3' or imem.def.col2 = 3) and col1 < '4' order by col1 asc, col2 desc",
            ?assertEqual(Expected8e, string:strip(binary_to_list(Sql8e))),

            ?assertEqual(ok, fetch_close(SKey, SR8, IsSec))
        after
            ?assertEqual(ok, close(SKey, SR8))
        end,

        SR9 = exec(SKey,query9, 100, IsSec, "
            select * from ddTable;"
        ),
        % ?LogDebug("StmtCols9 ~p~n", [SR9#stmtResult.stmtCols]),
        % ?LogDebug("SortSpec9 ~p~n", [SR9#stmtResult.sortSpec]),
        try
            Result9 = filter_and_sort(SKey, SR9, {undefined,[]}, [], [1,3,2], IsSec),
            ?LogDebug("Result9 ~p~n", [Result9]),
            {ok, Sql9, _SF9} = Result9,
            Expected9 = "select qname, opts, columns from ddTable",
            ?assertEqual(Expected9, string:strip(binary_to_list(Sql9))),

            ?assertEqual(ok, fetch_close(SKey, SR9, IsSec))
        after
            ?assertEqual(ok, close(SKey, SR9))
        end,

        SR9a = exec(SKey,query9a, 100, IsSec, "
            select * 
            from def a, def b 
            where a.col1 = b.col1;"
        ),
        ?LogDebug("StmtCols9a ~p~n", [SR9a#stmtResult.stmtCols]),
        try
            Result9a = filter_and_sort(SKey, SR9a, {undefined,[]}, [{1,<<"asc">>},{3,<<"desc">>}], [1,3,2], IsSec),
            % ?LogDebug("Result9a ~p~n", [Result9a]),
            {ok, Sql9a, _SF9a} = Result9a,
            % ?LogDebug("Sql9a ~p~n", [Sql9a]),
            Expected9a = "select a.col1, b.col1, a.col2 from def a, def b where a.col1 = b.col1 order by 1 asc, 3 desc",
            ?assertEqual(Expected9a, string:strip(binary_to_list(Sql9a))),

            Result9b = filter_and_sort(SKey, SR9a, {undefined,[]}, [{3,2,<<"asc">>},{2,3,<<"desc">>}], [1,3,2], IsSec),
            % ?LogDebug("Result9b ~p~n", [Result9b]),
            {ok, Sql9b, _SF9b} = Result9b,
            % ?LogDebug("Sql9b ~p~n", [Sql9b]),
            Expected9b = "select a.col1, b.col1, a.col2 from def a, def b where a.col1 = b.col1 order by b.col1 asc, a.col2 desc",
            ?assertEqual(Expected9b, string:strip(binary_to_list(Sql9b))),

            ?assertEqual(ok, fetch_close(SKey, SR9a, IsSec))
        after
            ?assertEqual(ok, close(SKey, SR9))
        end,


        SR10 = exec(SKey,query10, 100, IsSec, "
            select 
                 a.col1
                ,b.col1 
            from def a, def b 
            where a.col1=b.col1;"
        ),
        ?assertEqual(ok, fetch_async(SKey,SR10,[],IsSec)),
        List10a = receive_tuples(SR10,true),
        ?LogDebug("Result10a ~p~n", [List10a]),
        ?assertEqual(11, length(List10a)),

        ChangeList10 = [
          [1,upd,{?EmptyMR,{def,<<"5">>,5},{def,<<"5">>,5}},<<"X">>,<<"Y">>] 
        ],
        ?assertEqual(ok, update_cursor_prepare(SKey, SR10, IsSec, ChangeList10)),
        Result10b = update_cursor_execute(SKey, SR10, IsSec, optimistic),        
        ?LogDebug("Result10b ~p~n", [Result10b]),
        ?assertMatch([{1,{_,{def,<<"X">>,5},{def,<<"X">>,5}}}],Result10b), 

        ?assertEqual(ok, imem_sql:exec(SKey, "drop table def;", 0, [{schema,imem}], IsSec)),

        case IsSec of
            true ->     ?imem_logout(SKey);
            false ->    ok
        end

    catch
        Class:Reason ->  
            timer:sleep(1000),
            ?LogDebug("Exception~n~p:~p~n~p~n", [Class, Reason, erlang:get_stacktrace()]),
            ?assert( true == "all tests completed")
    end,
    ok. 



receive_tuples(StmtResult, Complete) ->
    receive_tuples(StmtResult,Complete,50,[]).

% receive_tuples(StmtResult, Complete, Timeout) ->
%     receive_tuples(StmtResult, Complete, Timeout,[]).

receive_tuples(#stmtResult{stmtRef=StmtRef,rowFun=RowFun}=StmtResult,Complete,Timeout,Acc) ->    
    case receive
            R ->    % ?Debug("~p got:~n~p~n", [erlang:now(),R]),
                    R
        after Timeout ->
            stop
        end of
        stop ->     
            Unchecked = case Acc of
                [] ->                       
%                    [{StmtRef,[],Complete}];
                    throw({no_response,{expecting,Complete}});
                [{StmtRef,{_,Complete}}|_] -> 
                    lists:reverse(Acc);
                [{StmtRef,{L1,C1}}|_] ->
                    throw({bad_complete,{StmtRef,{L1,C1}}});
                Res ->                      
                    throw({bad_receive,lists:reverse(Res)})
            end,
            case lists:usort([element(1, SR) || SR <- Unchecked]) of
                [StmtRef] -> 
                    % ?LogDebug("Unchecked receive result :~n~p~n",[Unchecked]),               
                    List = lists:flatten([element(1,element(2, T)) || T <- Unchecked]),
                    RT = result_tuples(List,RowFun),
                    if 
                        length(RT) =< 10 ->
                            ?LogDebug("Received:~n~p~n", [RT]);
                        true ->
                            ?LogDebug("Received: ~p items:~n~p~n~p~n~p~n", [length(RT),hd(RT), '...', lists:last(RT)])
                    end,            
                    RT;
                StmtRefs ->
                    throw({bad_stmtref,lists:delete(StmtRef, StmtRefs)})
            end;
        {_,Result} ->   
            receive_tuples(StmtResult,Complete,Timeout,[Result|Acc])
    end.

% result_lists(List,RowFun) when is_list(List), is_function(RowFun) ->  
%     lists:map(RowFun,List).

% result_lists_sort(List,RowFun,SortFun) when is_list(List), is_function(RowFun), is_function(SortFun) ->  
%     lists:map(RowFun,recs_sort(List,SortFun)).

result_tuples_sort(List,RowFun,SortFun) when is_list(List), is_function(RowFun), is_function(SortFun) ->  
    [list_to_tuple(R) || R <- lists:map(RowFun,recs_sort(List,SortFun))].


insert_range(_SKey, 0, _Table, _Schema, _IsSec) -> ok;
insert_range(SKey, N, Table, Schema, IsSec) when is_integer(N), N > 0 ->
    if_call_mfa(IsSec, write,[SKey,Table,{Table,list_to_binary(integer_to_list(N)),N}]),
    insert_range(SKey, N-1, Table, Schema, IsSec).

exec(SKey,Id, BS, IsSec, Sql) ->
    exec(SKey,Id, BS, IsSec, [], Sql).

exec(SKey,Id, BS, IsSec, Opts, Sql) ->
    ?LogDebug("~p : ~s~n", [Id,lists:flatten(Sql)]),
    {RetCode, StmtResult} = imem_sql:exec(SKey, Sql, BS, Opts, IsSec),
    ?assertEqual(ok, RetCode),
    #stmtResult{stmtCols=StmtCols} = StmtResult,
    %?LogDebug("Statement Cols:~n~p~n", [StmtCols]),
    [?assert(is_binary(SC#stmtCol.alias)) || SC <- StmtCols],
    StmtResult.

fetch_async(SKey, StmtResult, Opts, IsSec) ->
    ?assertEqual(ok, fetch_recs_async(SKey, StmtResult#stmtResult.stmtRef, {self(), make_ref()}, Opts, IsSec)).

    % {M1,S1,Mic1} = erlang:now(),
    % {M2,S2,Mic2} = erlang:now(),
    % Count = length(Result),
    % Delta = Mic2 - Mic1 + 1000000 * ((S2-S1) + 1000000 * (M2-M1)),
    % Message = io_lib:format("fetch_recs latency per record: ~p usec",[Delta div Count]),
    % imem_meta:log_to_db(debug,?MODULE,fetch_recs,[{rec_count,Count},{fetch_duration,Delta}], Message),

-endif.

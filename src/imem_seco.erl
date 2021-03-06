-module(imem_seco).

-include("imem_seco.hrl").

-define(GET_PASSWORD_LIFE_TIME(__AccountId), ?GET_CONFIG(passwordLifeTime,[__AccountId],100,"Password expiry time in days.")).
-define(SALT_BYTES, 32).
-define(PWD_HASH, scrypt).                       %% target hash: pwdmd5,md4,md5,sha512,scrypt 
-define(PWD_HASH_LIST, [scrypt,sha512,pwdmd5]).  %% allowed hash types
-define(REQUIRE_PWDMD5, <<"fun(Factors,NetCtx) -> [pwdmd5] -- Factors end">>).  % access | smsott | saml | pwdmd5
-define(AUTH_SMS_TOKEN_RETRY_DELAY, 1000).
-define(FULL_ACCESS, <<"fun(NetCtx) -> true end">>).
-define(PASSWORD_LOCK_TIME, ?GET_CONFIG(passwordLockTime,[],900,"Password lock time in seconds after reaching the password lock count.")).
-define(PASSWORD_LOCK_COUNT, ?GET_CONFIG(passwordLockCount,[],5,"Maximum number of wrong passwords tolerated before temporarily locking the account.")).

-behavior(gen_server).

-record(state, {
        }).

-export([ start_link/1
        ]).

% gen_server interface (monitoring calling processes)
%-export([ monitor/1
%        , cleanup_pid/1
%        ]).

% gen_server behavior callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        , format_status/2
        ]).

% security context library interface
-export([ drop_seco_tables/1
        , create_credentials/2      % parameters: (Name,Password) or (pwdmd5,Password)
        ]).

-export([ authenticate/3            % deprecated
        , auth_start/3
        , auth_add_cred/2
        , auth_abort/1
        , login/1
        , change_credentials/3
        , set_credentials/3
        , set_login_time/2
        , logout/1
        , clone_seco/2
        , cluster_clone_seco/3
        , account_id/1
        , account_name/1
        , password_strength_fun/0
        ]).

-export([ has_role/3
        , has_role/2
        , has_permission/3
        , has_permission/2
        ]).

-export([ have_role/2
        , have_permission/2
        ]).

% Functions applied with Common Test
-export([
          normalized_msisdn/1
        ]).

monitor_pid(SKey,Pid) when is_pid(Pid) -> 
    gen_server:call(?MODULE, {monitor,SKey,Pid}).

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
    try %% try creating system tables, may fail if they exist, then check existence 
        if_check_table(none, ddTable),

        ADef = {record_info(fields, ddAccount),?ddAccount,#ddAccount{}},
        imem_meta:init_create_check_table(ddAccount, ADef, [], system),
        imem_meta:create_or_replace_index(ddAccount, name),

        ADDef = {record_info(fields, ddAccountDyn),?ddAccountDyn,#ddAccountDyn{}},
        imem_meta:init_create_check_table(ddAccountDyn, ADDef, [], system),

        RDef = {record_info(fields, ddRole), ?ddRole, #ddRole{}},
        imem_meta:init_create_check_table(ddRole, RDef, [], system),

        SDef = {record_info(fields, ddSeCo), ?ddSeCo, #ddSeCo{}},
        case (catch imem_meta:table_columns(ddSeCo@)) of
            L when L==element(1,SDef) ->    ok;     % field names in table match the new record
            L when is_list(L) ->            ?Info("dropping old version of table ddSeCo@", []),
                                            imem_meta:drop_table(ddSeCo@);
            _ ->                            ok      % table does not exist
        end,

        imem_meta:init_create_check_table(ddSeCo@, SDef
              , [{scope,local}, {local_content,true},{record_name,ddSeCo}], system),

        PDef = {record_info(fields, ddPerm),?ddPerm, #ddPerm{}},
        imem_meta:init_create_check_table(ddPerm@, PDef
              , [{scope,local}, {local_content,true},{record_name,ddPerm}], system),

        QDef = {record_info(fields, ddQuota), ?ddQuota, #ddQuota{}},
        imem_meta:init_create_check_table(ddQuota@, QDef
              , [{scope,local}, {local_content,true},{record_name,ddQuota}], system),

        case if_select_account_by_name(none, <<"system">>) of
            {[],true} ->  
                    {ok, Pwd} = application:get_env(imem, default_admin_pswd),
                    LocalTime = calendar:local_time(),
                    UserCred=create_credentials(pwdmd5, Pwd),
                    Account = #ddAccount{id=system, type=deamon, name= <<"system">>, credentials=[UserCred]
                                , fullName= <<"DB Administrator">>, lastPasswordChangeTime=LocalTime},
                    AccountDyn = #ddAccountDyn{id=system},
                    if_write(none, ddAccount, Account),                    
                    if_write(none, ddAccountDyn, AccountDyn),                    
                    if_write(none, ddRole, #ddRole{id=system,roles=[],permissions=[manage_system, manage_accounts, manage_system_tables, manage_user_tables,{dderl,con,local,use}]});
            _ ->    ok
        end,
        % imem_meta:fail({"Fail in imem_seco:init on purpose"}),        
        if_truncate_table(none,ddSeCo@),
        if_truncate_table(none,ddPerm@),
        if_truncate_table(none,ddQuota@),

        process_flag(trap_exit, true),
        {ok,#state{}}
    catch
        _Class:Reason -> {stop, {Reason,erlang:get_stacktrace()}} 
    end.

handle_call({monitor, SKey, Pid}, _From, State) ->
    try
        Ref = erlang:monitor(process, Pid),
        % ?Debug("monitoring ~p for SKey ~p returns ~p", [Pid, SKey, Ref]),
        {reply, Ref, State}
    catch 
        Class:Reason -> 
            ?Warn("monitoring ~p for SKey ~p failed with ~p:~p", [Pid, SKey, Class, Reason]),
            {reply, {error,Reason}, State}
    end;
handle_call(Request, From, State) ->
    ?Warn("received unsolited call request ~p from  ~p", [Request,From]),
    {reply, ok, State}.

% handle_cast({stop, Reason}, State) ->
%     {stop,{shutdown,Reason},State};
handle_cast(Request, State) ->
    ?Warn("received unsolited cast request ~p", [Request]),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, normal}, State) ->
    % ?Debug("received normal exit for monitored pid ~p ref ~p~n", [?MODULE, Pid, _Ref]),
    cleanup_pid(Pid),
    {noreply, State};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    ?Info("received unexpected exit for monitored pid ~p ref ~p reason ~p~n", [Pid, _Ref, _Reason]),
    cleanup_pid(Pid),
    {noreply, State};
handle_info(Info, State) ->
    ?Warn("received unsolited info ~p", [Info]),
    {noreply, State}.


terminate(Reason, _State) ->
    case Reason of
        normal ->               ?Info("normal stop~n", []);
        shutdown ->             ?Info("shutdown~n", []);
        {shutdown, _Term} ->    ?Info("shutdown : ~p~n", [_Term]);
        _ ->                    ?Error("stopping unexpectedly : ~p~n", [Reason])
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

format_status(_Opt, [_PDict, _State]) -> ok.


%% --Interface functions  (duplicated in dd_account) ----------------------------------

if_select(_SKey, Table, MatchSpec) ->
    imem_meta:select(Table, MatchSpec). 

if_select_seco_keys_by_pid(SKey, Pid) -> 
    MatchHead = #ddSeCo{skey='$1', pid='$2', _='_'},
    Guard = {'==', '$2', Pid},
    Result = '$1',
    if_select(SKey, ddSeCo@, [{MatchHead, [Guard], [Result]}]).

if_select_perm_keys_by_skey(_SKeyM, SKey) ->      %% M=Monitor / MasterContext 
    MatchHead = #ddPerm{pkey='$1', skey='$2', _='_'},
    Guard = {'==', '$2', SKey},
    Result = '$1',
    if_select(SKey, ddPerm@, [{MatchHead, [Guard], [Result]}]).

if_check_table(_SeKey, Table) ->
    imem_meta:check_table(Table).

%% -- See similar Implementation in imem_account, imem_seco, imem_role -------------- 

if_dirty_index_read(_SeKey, Table, SecKey, Index) -> 
    imem_meta:dirty_index_read(Table, SecKey, Index).

if_select_account_by_name(_SeKey, <<"system">>) -> 
    {if_read(ddAccount, system),true};
if_select_account_by_name(_SeKey, Name) -> 
    {if_dirty_index_read(_SeKey,ddAccount,Name, #ddAccount.name),true}.

%% --Interface functions  (calling imem_meta) ----------------------------------

if_drop_table(_SKey, Table) -> 
    imem_meta:drop_table(Table).

if_truncate_table(_SKey, Table) -> 
    imem_meta:truncate_table(Table).

if_write(_SKey, Table, Record) -> 
    imem_meta:write(Table, Record).

if_read(Table, Key) -> 
    imem_meta:read(Table, Key).

if_delete(_SKey, Table, RowId) ->
    imem_meta:delete(Table, RowId).

if_missing_role(RoleId) when is_atom(RoleId) ->
    ?Warn("Role ~p does not exist", [RoleId]),
    false;
if_missing_role(_) -> false.

has_role(_RootRoleId, _RootRoleId) ->
    true;
has_role(RootRoleId, RoleId) ->
    case if_read(ddRole, RootRoleId) of
        [#ddRole{roles=[]}] ->          false;
        [#ddRole{roles=ChildRoles}] ->  if_has_child_role(ChildRoles, RoleId);
        [] ->                           if_missing_role(RootRoleId)
    end.

if_has_child_role([], _RoleId) -> false;
if_has_child_role([RootRoleId|OtherRoles], RoleId) ->
    case has_role(RootRoleId, RoleId) of
        true ->                         true;
        false ->                        if_has_child_role(OtherRoles, RoleId)
    end.

has_permission(_RootRoleId, []) ->
    false;
has_permission(RootRoleId, PermissionList) when is_list(PermissionList)->
    %% search for first match in list of permissions
    case if_read(ddRole, RootRoleId) of
        [#ddRole{permissions=[],roles=[]}] ->     
            false;
        [#ddRole{permissions=Permissions, roles=[]}] -> 
            list_member(PermissionList, Permissions);
        [#ddRole{permissions=Permissions, roles=ChildRoles}] ->
            case list_member(PermissionList, Permissions) of
                true ->     true;
                false ->    if_has_child_permission(ChildRoles, PermissionList)
            end;
        [] ->
            if_missing_role(RootRoleId)
    end;
has_permission(RootRoleId, PermissionId) ->
    %% search for single permission
    case if_read(ddRole, RootRoleId) of
        [#ddRole{permissions=[],roles=[]}] ->     
            false;
        [#ddRole{permissions=Permissions, roles=[]}] -> 
            lists:member(PermissionId, Permissions);
        [#ddRole{permissions=Permissions, roles=ChildRoles}] ->
            case lists:member(PermissionId, Permissions) of
                true ->     true;
                false ->    if_has_child_permission(ChildRoles, PermissionId)
            end;
        [] ->
            if_missing_role(RootRoleId)
    end.

if_has_child_permission([], _Permission) -> false;
if_has_child_permission([RootRoleId|OtherRoles], Permission) ->
    case has_permission(RootRoleId, Permission) of
        true ->     true;
        false ->    if_has_child_permission(OtherRoles, Permission)
    end.


%% --Implementation (exported helper functions) ----------------------------------------

-spec create_credentials(binary()|pwdmd5, binary()) -> ddCredential().
create_credentials(Name, Password) when is_binary(Name),is_binary(Password) ->
    {pwdmd5, {Name,erlang:md5(Password)}};  % username/password credential for auth_start/3 and auth_add_credential/2
create_credentials(pwdmd5, Password) when is_list(Password) ->
    create_credentials(pwdmd5, list_to_binary(Password));     
create_credentials(pwdmd5, Password) when is_integer(Password) ->
    create_credentials(pwdmd5, list_to_binary(integer_to_list(Password)));    
create_credentials(pwdmd5, Password) when is_binary(Password) ->
    {pwdmd5, erlang:md5(Password)}.         % for use in authenticate/3 and in raw credentials in ddAccount

cleanup_pid(Pid) ->
    MonitorPid =  whereis(?MODULE),
    case self() of
        MonitorPid ->    
            {SKeys,true} = if_select_seco_keys_by_pid(none,Pid),
            seco_delete(none, SKeys);
        _ ->
            ?SecurityViolation({"Cleanup unauthorized",{self(),Pid}})
    end.

list_member([], _Permissions) ->
    false;
list_member([PermissionId|Rest], Permissions) ->
    case lists:member(PermissionId, Permissions) of
        true -> true;
        false -> list_member(Rest, Permissions)
    end.

drop_seco_tables(SKey) ->
    case have_permission(SKey, manage_system_tables) of
        true ->
            if_drop_table(SKey, ddSeCo@),     
            if_drop_table(SKey, ddRole),         
            if_drop_table(SKey, ddAccountDyn),
            if_drop_table(SKey, ddAccount);   
        false ->
            ?SecurityException({"Drop seco tables unauthorized", SKey})
    end.

seco_create(AppId,SessionId) -> 
    SessionCtx = #ddSessionCtx{appId=AppId, sessionId=SessionId},
    SeCo = #ddSeCo{pid=self(), sessionCtx=SessionCtx, authTime=?TIMESTAMP},
    SKey = erlang:phash2(SeCo), 
    SeCo#ddSeCo{skey=SKey}.

seco_register(SeCo) -> seco_register(SeCo,undefined).

seco_register(#ddSeCo{skey=SKey, pid=Pid}=SeCo, AuthState) when Pid == self() -> 
    monitor_pid(SKey,Pid),
    if_write(SKey, ddSeCo@, SeCo#ddSeCo{authState=AuthState}),
    SKey.    %% security hash is returned back to caller

seco_unregister(#ddSeCo{skey=SKey, pid=Pid}) when Pid == self() -> 
    catch if_delete(SKey, ddSeCo@, SKey).


seco_existing(SKey) -> 
    case if_read(ddSeCo@, SKey) of
        [#ddSeCo{pid=Pid} = SeCo] when Pid == self() -> 
            SeCo;
        [] ->               
            ?SecurityException({"Not logged in", SKey})
    end.   

seco_authenticated(SKey) -> 
    case if_read(ddSeCo@, SKey) of
        [#ddSeCo{pid=Pid, authState=authenticated} = SeCo] when Pid == self() -> 
            SeCo;
        [#ddSeCo{pid=Pid, authState=authorized} = SeCo] when Pid == self() -> 
            SeCo;
        [#ddSeCo{}] ->      
            ?SecurityViolation({"Not authenticated", SKey});    % Not authenticated
        [] ->               
            ?SecurityException({"Not authenticated", SKey})
    end.   

seco_authorized(SKey) -> 
    case if_read(ddSeCo@, SKey) of
        [#ddSeCo{pid=Pid, authState=authorized} = SeCo] when Pid == self() -> 
            SeCo;
        [#ddSeCo{}] ->      
            ?SecurityViolation({"Not logged in", SKey});
        [] ->               
            ?SecurityException({"Not logged in", SKey})
    end.   

seco_update(#ddSeCo{skey=SKey,pid=Pid}=SeCo, #ddSeCo{skey=SKey,pid=Pid}=SeCoNew) when Pid == self() -> 
    case if_read(ddSeCo@, SKey) of
        [] ->       ?SecurityException({"Not logged in", SKey});
        [SeCo] ->   if_write(SKey, ddSeCo@, SeCoNew);
        [_] ->      ?SecurityException({"Security context is modified by someone else", SKey})
    end;
seco_update(#ddSeCo{skey=SKey}, _) -> 
    ?SecurityViolation({"Not logged in", SKey}).

seco_delete(_SKeyM, []) -> ok;
seco_delete(SKeyM, [SKey|SKeys]) ->
    seco_delete(SKeyM, SKey),
    seco_delete(SKeyM, SKeys);    
seco_delete(SKeyM, SKey) ->
    {Keys,true} = if_select_perm_keys_by_skey(SKeyM, SKey), 
    seco_perm_delete(SKeyM, Keys),
    try 
        if_delete(SKeyM, ddSeCo@, SKey)
    catch
        _Class:_Reason -> ?Warn("seco_delete(~p) - exception ~p:~p", [SKey, _Class, _Reason])
    end.

seco_perm_delete(_SKeyM, []) -> ok;
seco_perm_delete(SKeyM, [PKey|PKeys]) ->
    try
        if_delete(SKeyM, ddPerm@, PKey)
    catch
        _Class:_Reason -> ?Warn("seco_perm_delete(~p) - exception ~p:~p", [PKey, _Class, _Reason])
    end,
    seco_perm_delete(SKeyM, PKeys).

account_id(SKey) ->
    #ddSeCo{accountId=AccountId} = seco_authorized(SKey),
    AccountId.

account_name(SKey) ->
    #ddSeCo{accountId=AccountId} = seco_authorized(SKey),
    case if_read(ddAccount, AccountId) of
        [#ddAccount{name=Name}] ->  Name;
        [] ->                       ?ClientError({"Account does not exist", AccountId})
    end.

has_role(SKey, RootRoleId, RoleId) ->
    case have_permission(SKey, read_accounts) of
        true ->
            has_role(RootRoleId, RoleId);
        false ->     
            case have_permission(SKey, manage_accounts) of
                true ->     has_role(RootRoleId, RoleId); 
                false ->    ?SecurityException({"Has role unauthorized",SKey})
            end
    end.

has_permission(SKey, RootRoleId, Permission) ->
    case have_permission(SKey, read_accounts) of
        true ->     
            has_permission(RootRoleId, Permission); 
        false ->    
            case have_permission(SKey, manage_accounts) of
                true ->     has_permission(RootRoleId, Permission); 
                false ->    ?SecurityException({"Has permission unauthorized",SKey})
            end
    end.

have_role(SKey, RoleId) ->
    #ddSeCo{accountId=AccountId} = seco_authorized(SKey),
    has_role(AccountId, RoleId).

have_permission(SKey, Permission) ->
    #ddSeCo{accountId=AccountId} = seco_authorized(SKey),
    has_permission(AccountId, Permission).

fail_or_clear_password_lock(#ddSeCo{skey=SKey} = SeCo, AccountId) ->
    case if_read(ddAccountDyn, AccountId) of
        [] ->          % create default for missing dynamic account record
            if_write(SKey, ddAccountDyn, #ddAccountDyn{id=AccountId});
        [#ddAccountDyn{lastFailureTime=undefined}] ->
            ok;
        [#ddAccountDyn{lastFailureTime=LastFailureTuple}=AD] ->
            FailureCount = failure_count(LastFailureTuple),
            {{FY,FM,FD},{FHr,FMin,FSec}} = failure_datetime(LastFailureTuple),
            {{LY,LM,LD},{LHr,LMin,LSec}} = calendar:local_time(),
            UnlockSecs = 86400*(366*FY + 31*FM + FD) + 3600*FHr + 60*FMin + FSec + ?PASSWORD_LOCK_TIME,
            EffectiveSecs = 86400*(366*LY + 31*LM + LD) + 3600*LHr + 60*LMin + LSec,  % no need for monotony
            PLC = ?PASSWORD_LOCK_COUNT,
            if 
                EffectiveSecs > UnlockSecs ->
                    %% clear the password lock because user waited long enough
                    if_write(SKey, ddAccountDyn, AD#ddAccountDyn{lastFailureTime=undefined});
                FailureCount > PLC ->
                    %% lie a bit, don't show to a fast attacker that this attempt might have worked
                    authenticate_fail(SeCo, "Your account is temporarily locked. Try again in a few minutes.", true);
                true ->
                    %% user has not used up his password attempts, grant one more
                    ok
            end
    end.

-spec authenticate(any(), binary(), ddCredential()) -> ddSeCoKey() | no_return(). 
authenticate(SessionId, Name, {pwdmd5,Token}) ->            % old direct API for simple password authentication, deprecated
    #ddSeCo{skey=SKey} = SeCo = seco_create(imem, SessionId), 
    case if_select_account_by_name(SKey, Name) of
        {[#ddAccount{locked='true'}],true} ->
            authenticate_fail(SeCo, "Account is locked. Contact a system administrator", true);
        {[#ddAccount{id=AccountId} = Account],true} ->
            case if_read(ddAccountDyn, AccountId) of
                [] ->                                               % create missing dynamic account record
                    AD = #ddAccountDyn{id=AccountId},
                    if_write(SKey, ddAccountDyn, AD);               
                [#ddAccountDyn{lastFailureTime=undefined}] ->       % never had a failure before
                    ok;
                [#ddAccountDyn{id=AccountId}] ->
                    fail_or_clear_password_lock(SeCo, AccountId)
            end,
            ok = check_re_hash(SeCo, Account, Token, Token, true, ?PWD_HASH_LIST),
            seco_register(SeCo#ddSeCo{accountName=Name, accountId=AccountId, authFactors=[pwdmd5]}, authenticated);     % return SKey only
        {[],true} ->    
            authenticate_fail(SeCo, "Invalid account credentials. Please retry", true)
    end.

-spec auth_start(atom(), any(), ddCredential()) -> {ddSeCoKey(),[ddCredRequest()]} | no_return(). 
auth_start(AppId, SessionId, Credential) ->                % access context / network parameters 
    auth_step(seco_create(AppId, SessionId), Credential).

-spec auth_add_cred(ddSeCoKey(), ddCredential()) -> {ddSeCoKey(),[ddCredRequest()]} | no_return(). 
auth_add_cred(SKey, Credential) ->
    auth_step(seco_existing(SKey), Credential).

-spec auth_abort(ddSeCoKey()) -> ok. 
auth_abort(SKey) ->
    seco_unregister(seco_existing(SKey)).

-spec auth_step(ddSeCoKey(), ddCredential()) -> {ddSeCoKey(),[ddCredRequest()]} | no_return(). 
auth_step(SeCo, {access,NetworkCtx}) when is_map(NetworkCtx) ->
    #ddSeCo{skey = SKey, sessionCtx=SessionCtx, accountName=AccountName0, accountId=AccountId0} = SeCo,
    AccessCheckFunStr = ?GET_CONFIG(accessCheckFun,[SessionCtx#ddSessionCtx.appId],?FULL_ACCESS,"Function to check network access parameters in preparation of authentication steps."),
    CacheKey = {?MODULE,accessCheckFun,AccessCheckFunStr},
    AccessCheckFun = case imem_cache:read(CacheKey) of 
        [] ->
            case imem_datatype:io_to_fun(AccessCheckFunStr) of
                ACF when is_function(ACF,1) ->
                    imem_cache:write(CacheKey,ACF),
                    ACF;
                _ ->
                    authenticate_fail(SeCo,{"Invalid accessCheckFun", AccessCheckFunStr}, true) 
            end;    
        [ACF] when is_function(ACF,1) -> ACF;
        Err -> authenticate_fail(SeCo,{"Invalid accessCheckFun", Err}, true)
    end,
    NewSessionCtx = SessionCtx#ddSessionCtx{networkCtx=NetworkCtx},
    {AccountName1, AccountId1} = case AccessCheckFun(NewSessionCtx#ddSessionCtx.networkCtx) of
        true ->         
            {AccountName0, AccountId0};                                         %% access granted
        false ->        
            authenticate_fail(SeCo,{"Network access denied",NetworkCtx}, true); %% access denied
        AccountName0 -> 
            {AccountName0, AccountId0};                                         %% accountName confirmed by network
        Name when is_binary(Name), AccountName0 == undefined ->                 %% accountName defined by network
            case if_select_account_by_name(SKey, Name) of
              {[#ddAccount{locked='true'}],true} ->
                  authenticate_fail(SeCo, "Account is locked. Contact a system administrator", true);
              {[#ddAccount{id=AccId}],true} ->
                  {Name, AccId};
              {[],true} ->
                  authenticate_fail(SeCo, {"Access denied for", Name}, true)
            end;
        _ ->
            authenticate_fail(SeCo, "Account name conflict", true)                      
    end,
    case lists:member(access, SeCo#ddSeCo.authFactors) of
        false ->
            AuthFactors = [access|SeCo#ddSeCo.authFactors],
            auth_step_succeed(SeCo#ddSeCo{authFactors=AuthFactors, sessionCtx=NewSessionCtx, accountName=AccountName1, accountId=AccountId1});
        true ->
            AuthRequireFun = get_auth_fun(SeCo),
            {SKey, [{A,#{accountName=>AccountName0}} || A <- AuthRequireFun(SeCo#ddSeCo.authFactors, SessionCtx#ddSessionCtx.networkCtx)]}
    end;
auth_step(SeCo, {pwdmd5,{Name,Token}}) ->
    #ddSeCo{skey=SKey, accountId=AccountId0, authFactors=AFs} = SeCo, % may not yet exist in ddSeco@
    case if_select_account_by_name(SKey, Name) of
        {[#ddAccount{locked='true'}],true} ->
            authenticate_fail(SeCo, "Account is locked. Contact a system administrator", true);
        {[#ddAccount{id=AccountId1} = Account],true} when AccountId0==AccountId1; AccountId0==undefined ->
            ok = fail_or_clear_password_lock(SeCo, AccountId1),
            ok = check_re_hash(SeCo, Account, Token, Token, true, ?PWD_HASH_LIST),
            auth_step_succeed(SeCo#ddSeCo{accountName=Name, accountId=AccountId1, authFactors=[pwdmd5|AFs]});
        {[#ddAccount{}],true} -> 
            authenticate_fail(SeCo, "Account name conflict", true);
        {[],true} ->
            authenticate_fail(SeCo, "Invalid account credentials. Please retry", true)
    end;
auth_step(SeCo, {smsott,Token}) ->
    #ddSeCo{sessionCtx=SessionCtx, accountName=AccountName, accountId=AccountId, authFactors=AFs} = SeCo,
    case sms_ott_mobile_phone(AccountId) of
        undefined ->    
            authenticate_fail(SeCo, "Missing mobile phone number for SMS one time token", true);
        To ->           
            case (catch imem_auth_smsott:verify_sms_token(SessionCtx#ddSessionCtx.appId, To, Token, {smsott, #{}})) of % TODO : smsott with parameters
                ok ->
                    auth_step_succeed(SeCo#ddSeCo{authFactors=[smsott|AFs]});
                _ ->
                    case ?GET_CONFIG(smsTokenValidationRetry,[SessionCtx#ddSessionCtx.appId],true,"Can a wrong SMS authentication token answer be retried (within time limit)?") of
                        true ->
                            case (catch imem_auth_smsott:send_sms_token(SessionCtx#ddSessionCtx.appId, To, {smsott, #{}})) of
                                ok ->
                                    timer:sleep(?AUTH_SMS_TOKEN_RETRY_DELAY),           
                                    {seco_register(SeCo),[{smsott,#{accountName=>AccountName,to=>To}}]};     % re-ask for new token
                                _ -> 
                                    authenticate_fail(SeCo, "SMS one time token validation failed", true)
                            end;
                        _ ->
                            authenticate_fail(SeCo, "SMS one time token validation failed", true)
                    end
            end
    end;
auth_step(SeCo, {saml, Name}) ->
    #ddSeCo{skey=SKey, accountId=AccountId0, authFactors=AFs} = SeCo, % may not yet exist in ddSeco@
    case if_select_account_by_name(SKey, Name) of
        {[#ddAccount{id=AccountId1}],true} when AccountId0==AccountId1; AccountId0==undefined ->
            auth_step_succeed(SeCo#ddSeCo{accountName=Name, accountId=AccountId1, authFactors=[saml|AFs]});
        {[#ddAccount{locked='true'}],true} ->
            authenticate_fail(SeCo, "Account is locked. Contact a system administrator", true);
        {[#ddAccount{}],true} -> 
            authenticate_fail(SeCo, "Account name conflict", true);
        {[],true} ->
            authenticate_fail(SeCo, "Not a valid user", true)
    end;
auth_step(SeCo, Credential) ->
    authenticate_fail(SeCo,{"Invalid credential type",element(1,Credential)}, true).

-spec authenticate_fail(ddSeCoKey(), list() | tuple(), boolean()) -> no_return(). 
authenticate_fail(SeCo, ErrorTerm, true) ->
    seco_unregister(SeCo),
    ?SecurityException(ErrorTerm);
authenticate_fail(_SeCo, ErrorTerm, false) ->
    ?SecurityException(ErrorTerm).

get_auth_fun(#ddSeCo{sessionCtx=SessionCtx} = SeCo) ->
    AuthRequireFunStr = ?GET_CONFIG(authenticateRequireFun,[SessionCtx#ddSessionCtx.appId],?REQUIRE_PWDMD5,"Function which defines authentication requirements depending on current authentication step."),
    CacheKey = {?MODULE,authenticateRequireFun,AuthRequireFunStr},
    case imem_cache:read(CacheKey) of 
        [] ->
            case imem_datatype:io_to_fun(AuthRequireFunStr) of
                CF when is_function(CF,2) ->
                    imem_cache:write(CacheKey,CF),
                    CF;
                _ ->
                    authenticate_fail(SeCo,{"Invalid authenticatonRequireFun", AuthRequireFunStr}, true) 
            end;    
        [AF] when is_function(AF,2) -> AF;
        Err1 -> authenticate_fail(SeCo,{"Invalid authenticatonRequireFun", Err1}, true)
    end.

-spec auth_step_succeed(ddSeCoKey()) -> ddSeCoKey() | [ddCredRequest()] | no_return(). 
auth_step_succeed(#ddSeCo{skey=SKey, accountName=AccountName, accountId=AccountId, sessionCtx=SessionCtx, authFactors=AFs} = SeCo) ->
    AuthRequireFun = get_auth_fun(SeCo),
    case AuthRequireFun(AFs,SessionCtx#ddSessionCtx.networkCtx) of
        [] ->   
            case if_read(ddAccountDyn, AccountId) of
                [] ->   
                    AD = #ddAccountDyn{id=AccountId},
                    if_write(SKey, ddAccountDyn, AD);   % create dynamic account record if missing
                [#ddAccountDyn{lastFailureTime=undefined}] ->
                    ok;
                [#ddAccountDyn{} = AD] ->
                    if_write(SKey, ddAccountDyn, AD#ddAccountDyn{lastFailureTime=undefined})
            end,
            {seco_register(SeCo, authenticated),[]};   % authentication success, return {SKey,[]} 
        [smsott] ->
            case sms_ott_mobile_phone(AccountId) of
                undefined ->    
                    authenticate_fail(SeCo, "Missing mobile phone number for SMS one time token", true);
                To ->           
                    case (catch imem_auth_smsott:send_sms_token(SessionCtx#ddSessionCtx.appId, To, {smsott, #{}})) of
                        ok ->           
                            {seco_register(SeCo),[{smsott,#{accountName=>AccountName,to=>To}}]};     % request a SMS one time token
                        {'EXIT',{Err2,_StackTrace}} ->
                            case ?GET_CONFIG(smsTokenSendingErrorSkip,[SessionCtx#ddSessionCtx.appId],false,"Should SMS token authentication be skipped when the token server is unavailable?") of
                                true -> {seco_register(SeCo, authenticated),[]};   % authentication success, return {SKey,[]} 
                                _ ->    authenticate_fail(SeCo,{"SMS one time token sending failed", Err2}, true)
                            end
                    end
            end;
        [smsott|Rest] ->
            case sms_ott_mobile_phone(AccountId) of
                undefined ->    {seco_register(SeCo),[{A,#{accountName=>AccountName}} || A <- Rest]};
                To ->           
                    case (catch imem_auth_smsott:send_sms_token(SessionCtx#ddSessionCtx.appId, To, {smsott, #{}})) of
                        ok ->   {seco_register(SeCo),[{smsott,#{accountName=>AccountName,to=>To}}|Rest]};   % request a SMS one time token
                        _ ->    {seco_register(SeCo),[{A,#{accountName=>AccountName}} || A <- Rest]}        % skip SMS one time token factor
                    end
            end;
        OFs ->  {seco_register(SeCo),[{A,#{accountName=>AccountName}} || A <- OFs]}   % ask for remaining factors to try
    end.       

sms_ott_mobile_phone(AccountId) ->
    case if_read(ddAccount, AccountId) of
        [] ->                           
            undefined;
        [#ddAccount{fullName=FN}] ->    
            case (catch imem_json:get(<<"MOBILE">>,FN,undefined)) of
                undefined ->            undefined;
                B when is_binary(B) ->  normalized_msisdn(B);
                _ ->                    undefined
            end;
        _ -> undefined
    end.

normalized_msisdn(B0) ->
    case binary:replace(B0,[<<"-">>,<<" ">>,<<"(0)">>],<<>>,[global]) of
        <<$+,Rest1/binary>> -> <<$+,Rest1/binary>>;
        <<$0,Rest2/binary>> -> <<$+,$4,$1,Rest2/binary>>;
        Rest3 ->               <<$+,Rest3/binary>>
    end.

failure_count(undefined) -> 0;
failure_count({{_,_,_},{_,_,SF}}) -> SF rem 10. % Failure count is packed into last second digit of a datetime tuple

failure_datetime(undefined) -> undefined;
failure_datetime({{Y,M,D},{Hr,Mi,Ss}}) -> {{Y,M,D},{Hr,Mi,10*(Ss div 10)}}.

failure_tuple({{Y,M,D},{Hr,Mi,Ss}},undefined) -> {{Y,M,D},{Hr,Mi,10*(Ss div 10) + 1}};      % first failure (last digit in seconds)
failure_tuple({{Y,M,D},{Hr,Mi,Ss}},{{_,_,_},{_,_,SF}}) -> {{Y,M,D},{Hr,Mi, 10 * (Ss div 10) + (SF+1) rem 10}}.    % next failure

check_re_hash(#ddSeCo{skey=SKey}=SeCo, #ddAccount{id=AccountId}=_Account, _OldToken, _NewToken, Unregister, []) ->
    % no more credential types to check, credential check failed
    LocalTime = calendar:local_time(),
    case if_read(ddAccountDyn, AccountId) of
        [] ->                                           % create missing dynamic account record   
            if_write(SKey, ddAccountDyn, #ddAccountDyn{id=AccountId,lastFailureTime=failure_tuple(LocalTime,undefined)});
        [#ddAccountDyn{lastFailureTime=LFT}=AD] ->                         % update last error time
            if_write(SKey, ddAccountDyn, AD#ddAccountDyn{lastFailureTime=failure_tuple(LocalTime,LFT)})
    end,    
    authenticate_fail(SeCo, "Invalid account credentials. Please retry", Unregister);
check_re_hash(SeCo, Account, OldToken, NewToken, Unregister, [pwdmd5|Types]) ->
    case lists:member({pwdmd5,OldToken},Account#ddAccount.credentials) of
        true ->  
            re_hash(SeCo, {pwdmd5,OldToken}, OldToken, NewToken, Account);              % succeed
        false ->
            check_re_hash(SeCo, Account, OldToken, NewToken, Unregister, Types)         % continue
    end;
check_re_hash(SeCo, Account, OldToken, NewToken, Unregister, [Type|Types]) ->
    case lists:keyfind(Type,1,Account#ddAccount.credentials) of
        {Type,{Salt,Hash}} ->
            case hash(Type,Salt,OldToken) of
                Hash ->
                    re_hash(SeCo, {Type,{Salt,Hash}}, OldToken, NewToken, Account);     % succeed
                _ ->
                    check_re_hash(SeCo, Account, OldToken, NewToken, Unregister, [])    % fail
            end;
        false ->
            check_re_hash(SeCo, Account, OldToken, NewToken, Unregister, Types)         % continue
    end.

find_re_hash(SeCo, Account, NewToken, []) ->
    re_hash(SeCo, undefined, undefined, NewToken, Account);
find_re_hash(SeCo, Account, NewToken, [Type|Types]) ->
    case lists:keyfind(Type,1,Account#ddAccount.credentials) of
        false ->
            find_re_hash(SeCo, Account, NewToken, Types);
        FoundCred ->
            re_hash(SeCo, FoundCred, <<>>, NewToken, Account)
    end.

re_hash( _ , {?PWD_HASH,_}, Token, Token, _) -> ok;   %% re_hash not needed, already using target hash
re_hash(SeCo, FoundCred, OldToken, NewToken, Account) ->
    Salt = crypto:strong_rand_bytes(?SALT_BYTES),
    Hash = hash(?PWD_HASH, Salt, NewToken),
    NewCreds = [{?PWD_HASH,{Salt,Hash}} | lists:delete(FoundCred,Account#ddAccount.credentials)],
    NewAccount = case NewToken of
        OldToken -> Account#ddAccount{credentials=NewCreds};
        _ ->        Account#ddAccount{credentials=NewCreds,lastPasswordChangeTime=calendar:local_time()}
    end,
    ok=if_write(SeCo#ddSeCo.skey, ddAccount, NewAccount).


hash(scrypt,Salt,Token) when is_binary(Salt), is_binary(Token) ->
    %io:format(user,"scrypt hash start ~p ~p~n",[Salt,Token]),
    %Self = self(),
    %spawn(fun() -> 
    %    {T,Res}=timer:tc(fun()-> erlscrypt:scrypt(Token, Salt, 16384, 8, 1, 64) end),
    %    io:format(user,"scrypt hash result after ~p ~p~n",[T,Res]),
    %    Self! Res
    %end),
    %receive
    %    Res2 -> Res2
    %after 2000 ->
    %    throw(scrypt_timeout)
    %end;
    erlscrypt:scrypt(nif, Token, Salt, 16384, 8, 1, 64);
hash(Type,Salt,Token) when is_atom(Type), is_binary(Salt), is_binary(Token) ->
    crypto:hash(Type,<<Salt/binary,Token/binary>>).

login(SKey) ->
    #ddSeCo{accountId=AccountId, authFactors=AuthenticationFactors} = SeCo = seco_authenticated(SKey),
    LocalTime = calendar:local_time(),
    PwdExpireSecs = calendar:datetime_to_gregorian_seconds(LocalTime),
    PwdExpireDate = case {AccountId,?GET_PASSWORD_LIFE_TIME(AccountId)} of
        {system,_} ->   0;
        {_,infinity} -> 0;      % sorts in after any date tuple
        {_,PVal} ->     calendar:gregorian_seconds_to_datetime(PwdExpireSecs-24*3600*PVal)
    end,
    case {if_read(ddAccount, AccountId), lists:member(pwdmd5,AuthenticationFactors)} of
        {[#ddAccount{type='user',lastPasswordChangeTime=undefined}], true} -> 
            ?SecurityException({?PasswordChangeNeeded, AccountId});
        {[#ddAccount{type='user',lastPasswordChangeTime=LastChange}], true} when LastChange < PwdExpireDate -> 
            ?SecurityException({?PasswordChangeNeeded, AccountId});
        {[#ddAccount{}], _} ->
            [AccountDyn] = if_read(ddAccountDyn,AccountId),
            ok = seco_update(SeCo, SeCo#ddSeCo{authState=authorized}),
            if_write(SKey, ddAccountDyn, AccountDyn#ddAccountDyn{lastLoginTime=LocalTime}),
            SKey;            
        {[], _} ->                    
            logout(SKey),
            ?SecurityException({"Invalid account credentials. Please retry", AccountId})
    end.

change_credentials(SKey, {pwdmd5,Token}, {pwdmd5,Token}) ->
    #ddSeCo{accountId=AccountId} = seco_authenticated(SKey),
    ?SecurityException({"The same password cannot be re-used. Please retry", AccountId});
change_credentials(SKey, {pwdmd5,OldToken}, {pwdmd5,NewToken}) ->
    #ddSeCo{accountId=AccountId} = SeCo = seco_authenticated(SKey),
    [Account] = if_read(ddAccount, AccountId),
    ok = check_re_hash(SeCo, Account, OldToken, NewToken, false, ?PWD_HASH_LIST),
    login(SKey).

set_credentials(SKey, Name, {pwdmd5,NewToken}) ->
    SeCo = seco_authorized(SKey),
    case have_permission(SKey, manage_accounts) of
        true ->     Account = imem_account:get_by_name(SKey, Name),
                    find_re_hash(SeCo, Account, NewToken, ?PWD_HASH_LIST); 
        false ->    ?SecurityException({"Set credentials unauthorized",SKey})
    end.

set_login_time(SKey, AccountId) ->
    case have_permission(SKey, manage_accounts) of
        true ->
            AccountDyn = case if_read(ddAccountDyn,AccountId) of
                             [AccountDynRec] ->  AccountDynRec;
                             [] -> #ddAccountDyn{id = AccountId}
                         end,
            if_write(SKey, ddAccountDyn, AccountDyn#ddAccountDyn{lastLoginTime=calendar:local_time()});
        false ->    ?SecurityException({"Set login time unauthorized",SKey})
    end.

logout(SKey) ->
    seco_delete(SKey, SKey).

clone_seco(SKeyParent, Pid) ->
    SeCoParent = seco_authorized(SKeyParent),
    SeCo = SeCoParent#ddSeCo{skey=undefined, pid=Pid},
    SKey = erlang:phash2(SeCo), 
    monitor_pid(SKey,Pid),
    if_write(SKeyParent, ddSeCo@, SeCo#ddSeCo{skey=SKey}),
    SKey.

cluster_clone_seco(SKeyParent, Node, Pid) ->
    SeCoParent = seco_authorized(SKeyParent),
    SeCo = SeCoParent#ddSeCo{skey=undefined, pid=Pid},
    SKey = erlang:phash2(SeCo), 
    case rpc:call(Node, gen_server, call, [?MODULE, {monitor,SKey,Pid}]) of
        Ref when is_reference(Ref) -> 
            case rpc:call(Node, imem_meta, write, [ddSeCo@, SeCo#ddSeCo{skey=SKey}]) of
                ok ->       SKey;
                Error ->    throw(Error)
            end;
        Error ->
            throw(Error)
    end.

-spec password_strength_fun() ->
    fun((list()|binary()) -> short|weak|medium|strong).
password_strength_fun() ->
    PasswordStrengthFunStr =
    ?GET_CONFIG(
       passwordStrength, [],
       <<"fun(Password) ->"
           "  REStrong = \"^(?=.{8,})(?=.*[A-Z])(?=.*[a-z])(?=.*[0-9])(?=.*\\\\W).*$\","
           "  REMedium = \"^(?=.{7,})(((?=.*[A-Z])(?=.*[a-z]))|((?=.*[A-Z])(?=.*[0-9]))"
                          "|((?=.*[a-z])(?=.*[0-9]))).*$\","
           "  REEnough = \"(?=.{6,}).*\","
           "  case re:run(Password, REEnough) of"
           "   nomatch -> short;"
           "   _ ->"
           "    case re:run(Password, REStrong) of"
           "     nomatch ->"
           "      case re:run(Password, REMedium) of"
           "       nomatch -> weak;"
           "       _ -> medium"
           "      end;"
           "     _ -> strong"
           "    end"
           "  end"
           " end.">>,
         "Function to measure the effectiveness of a string as potential password."),
    ?Debug("PasswordStrength ~p", [PasswordStrengthFunStr]),
    imem_compiler:compile(PasswordStrengthFunStr).

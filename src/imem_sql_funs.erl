-module(imem_sql_funs).

-include("imem_seco.hrl").
-include("imem_sql.hrl").

-define( FilterFuns, 
            [ list, prefix_ul, concat, upper, lower, split, slice 
            , is_nav, is_val, is_key , is_member, is_like, is_regexp_like
            , add_dt, add_ts, diff_dt, diff_ts, list_to_tuple, list_to_binstr
            , to_name, to_text, to_atom, to_string, to_binstr, to_binary, to_integer, to_float, to_number
            , to_boolean, to_tuple, to_list, to_map, to_term, to_binterm, to_pid, from_binterm
            , to_decimal, from_decimal, to_timestamp, to_time, to_datetime, to_ipaddr
            , to_json, json_to_list, json_arr_proj, json_obj_proj, json_value, json_diff, md5
            , byte_size, bit_size, nth, sort, usort, reverse, last, remap, phash2, bits, bytes
            , map_size, map_get, map_merge, map_remove, map_with, map_without
            , '[]', '{}', ':', '#keys', '#key','#values','#value', '::'
            , mfa, preview, preview_keys, trunc, round, integer_uid, time_uid, diff, diff_only
            , cmp, cmp_white_space, norm_white_space
            , safe_atom, safe_binary, safe_binstr, safe_boolean, safe_function, safe_float
            , safe_integer, safe_json, safe_list, safe_map, safe_term, safe_tuple
            , nvl_atom, nvl_binary, nvl_binstr, nvl_float, nvl_integer, nvl_json, nvl_term, nvl_tuple
            , vnf_identity,vnf_lcase_ascii,vnf_lcase_ascii_ne,vnf_tokens,vnf_integer
            , vnf_float,vnf_datetime,vnf_datetime_ne
            ]).

-export([ filter_funs/0
        , expr_fun/1
        , filter_fun/1
        ]).

-export([ unary_fun_bind_type/1
        , unary_fun_result_type/1
        , binary_fun_bind_type1/1
        , binary_fun_bind_type2/1
        , binary_fun_result_type/1
        , ternary_fun_bind_type1/1
        , ternary_fun_bind_type2/1
        , ternary_fun_bind_type3/1
        , ternary_fun_result_type/1
        , ternary_not/1
        , ternary_and/2
        , ternary_or/2
        , mod_op_1/3
        , mod_op_2/4
        , mod_op_3/5
        , math_plus/1
        , math_minus/1
        , is_val/1
        , is_nav/1
        , is_key/2
        , is_binstr/1
        , is_binterm/1
        , is_decimal/1
        , is_ipaddr/1
        , is_name/1
        , is_json/1
        , is_string/1
        , is_text/1
        , is_timestamp/1
        , is_datetime/1
        ]).

-export([ re_compile/1
        , re_match/2
        , like_compile/1
        , like_compile/2
        ]).

-export([ to_integer/1
        , to_float/1
        , to_number/1
        , to_string/1
        , to_binstr/1
        , to_binary/1
        , to_json/1
        , to_atom/1
        , to_boolean/1
        , to_existing_atom/1
        , to_tuple/1
        , to_list/1
        , to_map/1
        , to_term/1
        , to_pid/1
        , to_binterm/1
        , to_timestamp/1
        , to_time/1
        , to_datetime/1
        , to_ipaddr/1
        , to_name/1
        , to_text/1
        , list_to_binstr/1
        ]).

-export([ concat/2
        , trunc/1    
        , trunc/2
        , round/1
        , round/2
        , add_dt/2
        , add_ts/2
        , diff_dt/2
        , diff_ts/2
        , to_decimal/2
        , from_decimal/2
        , from_binterm/1
        , is_member/2
        , prefix_ul/1
        , remap/3
        ]).

-export([ '#keys'/1
        , '#key'/1
        , '#values'/1
        , '#value'/1
        , json_to_list/1
        , json_arr_proj/2
        , json_obj_proj/2
        , json_value/2
        , json_diff/2
        , mfa/3
        , upper/1
        , lower/1
        , split/2
        , slice/2
        , slice/3
        , bits/2
        , bits/3
        , bytes/2
        , bytes/3
        , preview/3
        , preview_keys/3
        , cmp/2
        , cmp/3
        , diff/2
        , diff/3
        , diff_only/2
        , diff_only/3
        ]).

% Functions applied with Common Test
-export([ transform_like/2
        ]).


filter_funs() -> ?FilterFuns.

unary_fun_bind_type(B) when is_binary(B) ->     unary_fun_bind_type(binary_to_list(B));
unary_fun_bind_type([$t,$o,$_|_]) ->            #bind{type=binstr,default= <<>>};
unary_fun_bind_type([$#,_]) ->                  #bind{type=json,default= <<>>};     % #key(s), #value(s) for now
unary_fun_bind_type([$v,$n,$f,$_|_]) ->         #bind{type=term,default= <<>>};     % vnf_.... value normalizing functions
unary_fun_bind_type([$i,$s,$_|_]) ->            #bind{type=term,default=undefined};
unary_fun_bind_type("length") ->                #bind{type=list,default=[]};
unary_fun_bind_type("hd") ->                    #bind{type=list,default=[]};
unary_fun_bind_type("tl") ->                    #bind{type=list,default=[]};
unary_fun_bind_type("last") ->                  #bind{type=list,default=[]};
unary_fun_bind_type("sort") ->                  #bind{type=list,default=[]};
unary_fun_bind_type("usort") ->                 #bind{type=list,default=[]};
unary_fun_bind_type("reverse") ->               #bind{type=list,default=[]};
unary_fun_bind_type("size") ->                  #bind{type=tuple,default=undefined};
unary_fun_bind_type("tuple_size") ->            #bind{type=tuple,default=undefined};
unary_fun_bind_type("byte_size") ->             #bind{type=binary,default= <<>>};
unary_fun_bind_type("bit_size") ->              #bind{type=binary,default= <<>>};
unary_fun_bind_type("map_size") ->              #bind{type=map,default= #{}};
unary_fun_bind_type("from_binterm") ->          #bind{type=binterm,default= ?nav};
unary_fun_bind_type("prefix_ul") ->             #bind{type=list,default= ?nav};
unary_fun_bind_type("list_to_binstr") ->        #bind{type=list,default= ?nav};
unary_fun_bind_type("json_to_list") ->          #bind{type=json,default= []};
unary_fun_bind_type("phash2") ->                #bind{type=term,default= []};
unary_fun_bind_type("md5") ->                   #bind{type=binstr,default= <<>>};
unary_fun_bind_type("cmp_white_space") ->       #bind{type=binstr,default= <<>>};
unary_fun_bind_type("norm_white_space") ->      #bind{type=binstr,default= <<>>};
unary_fun_bind_type("round") ->                 #bind{type=number,default=0};
unary_fun_bind_type("trunc") ->                 #bind{type=timestamp,default=0};
unary_fun_bind_type("lower") ->                 #bind{type=binstr,default= <<>>};
unary_fun_bind_type("upper") ->                 #bind{type=binstr,default= <<>>};
unary_fun_bind_type("safe_atom") ->             #bind{type=atom,default=?nav};
unary_fun_bind_type("safe_binary") ->           #bind{type=binary,default=?nav};
unary_fun_bind_type("safe_binstr") ->           #bind{type=binstr,default=?nav};
unary_fun_bind_type("safe_binterm") ->          #bind{type=binterm,default=?nav};
unary_fun_bind_type("safe_boolean") ->          #bind{type=boolean,default=?nav};
unary_fun_bind_type("safe_datetime") ->         #bind{type=datetime,default=?nav};
unary_fun_bind_type("safe_decimal") ->          #bind{type=decimal,default=?nav};
unary_fun_bind_type("safe_float") ->            #bind{type=float,default=?nav};
unary_fun_bind_type("safe_function") ->         #bind{type=function,default=?nav};
unary_fun_bind_type("safe_integer") ->          #bind{type=integer,default=?nav};
unary_fun_bind_type("safe_ipaddr") ->           #bind{type=ipaddr,default=?nav};
unary_fun_bind_type("safe_json") ->             #bind{type=json,default=?nav};        
unary_fun_bind_type("safe_list") ->             #bind{type=list,default=?nav};
unary_fun_bind_type("safe_map") ->              #bind{type=term,default=?nav};
unary_fun_bind_type("safe_name") ->             #bind{type=binstr,default=?nav};
unary_fun_bind_type("safe_pid") ->              #bind{type=pid,default=?nav};
unary_fun_bind_type("safe_string") ->           #bind{type=string,default=?nav};
unary_fun_bind_type("safe_term") ->             #bind{type=term,default=?nav};
unary_fun_bind_type("safe_text") ->             #bind{type=binstr,default=?nav};
unary_fun_bind_type("safe_timestamp") ->        #bind{type=timestamp,default=?nav};
unary_fun_bind_type("safe_tuple") ->            #bind{type=tuple,default=?nav};
unary_fun_bind_type("integer_uid") ->           #bind{type=term,default=?nav};
unary_fun_bind_type("time_uid") ->              #bind{type=term,default=?nav};
unary_fun_bind_type(_) ->                       #bind{type=number,default= ?nav}.

unary_fun_result_type(B) when is_binary(B) ->   unary_fun_result_type(binary_to_list(B));
unary_fun_result_type([$i,$s,$_|_]) ->          #bind{type=boolean,default=?nav};
unary_fun_result_type([$#,_]) ->                #bind{type=json,default= []};     % #key(s), #value(s) for now
unary_fun_result_type([$v,$n,$f,$_|_]) ->       #bind{type=list,default= []};     % vnf_.... value normalizing functions
unary_fun_result_type("hd") ->                  #bind{type=term,default=undefined};
unary_fun_result_type("last") ->                #bind{type=term,default=undefined};
unary_fun_result_type("tl") ->                  #bind{type=list,default=[]};
unary_fun_result_type("sort") ->                #bind{type=list,default=[]};
unary_fun_result_type("usort") ->               #bind{type=list,default=[]};
unary_fun_result_type("reverse") ->             #bind{type=list,default=[]};
unary_fun_result_type("length") ->              #bind{type=integer,default=?nav};
unary_fun_result_type("size") ->                #bind{type=integer,default=?nav};
unary_fun_result_type("tuple_size") ->          #bind{type=integer,default=?nav};
unary_fun_result_type("byte_size") ->           #bind{type=integer,default=?nav};
unary_fun_result_type("bit_size") ->            #bind{type=integer,default=?nav};
unary_fun_result_type("map_size") ->            #bind{type=integer,default=?nav};
unary_fun_result_type("integer_uid") ->         #bind{type=integer,default=?nav};
unary_fun_result_type("time_uid") ->            #bind{type=timestamp,default=?nav};
unary_fun_result_type("from_decimal") ->        #bind{type=float,default=?nav};
unary_fun_result_type("from_binterm") ->        #bind{type=term,default=?nav};
unary_fun_result_type("prefix_ul") ->           #bind{type=list,default=?nav};
unary_fun_result_type("json_to_list") ->        #bind{type=list,default=[]};
unary_fun_result_type("phash2") ->              #bind{type=integer,default=0};
unary_fun_result_type("md5") ->                 #bind{type=binary,default= <<>>};
unary_fun_result_type("cmp_white_space") ->     #bind{type=boolean,default= false};
unary_fun_result_type("norm_white_space") ->    #bind{type=binstr,default= <<>>};
unary_fun_result_type("round") ->               #bind{type=number,default=0};
unary_fun_result_type("trunc") ->               #bind{type=timestamp,default=0};
unary_fun_result_type("lower") ->               #bind{type=binstr,default= <<>>};
unary_fun_result_type("upper") ->               #bind{type=binstr,default= <<>>};
unary_fun_result_type("to_atom") ->             #bind{type=atom,default=?nav};
unary_fun_result_type("to_binary") ->           #bind{type=binary,default=?nav};
unary_fun_result_type("to_binstr") ->           #bind{type=binstr,default=?nav};
unary_fun_result_type("list_to_binstr") ->      #bind{type=binstr,default=?nav};
unary_fun_result_type("to_binterm") ->          #bind{type=binterm,default=?nav};
unary_fun_result_type("to_boolean") ->          #bind{type=boolean,default=?nav};
unary_fun_result_type("to_datetime") ->         #bind{type=datetime,default=?nav};
unary_fun_result_type("to_decimal") ->          #bind{type=decimal,default=?nav};
unary_fun_result_type("to_float") ->            #bind{type=float,default=?nav};
unary_fun_result_type("to_integer") ->          #bind{type=integer,default=?nav};
unary_fun_result_type("to_json") ->             #bind{type=json,default=?nav};        
unary_fun_result_type("to_list") ->             #bind{type=list,default=[]};
unary_fun_result_type("to_map") ->              #bind{type=term,default=?nav};
unary_fun_result_type("to_name") ->             #bind{type=binstr,default=?nav};
unary_fun_result_type("to_number") ->           #bind{type=number,default=?nav};
unary_fun_result_type("to_pid") ->              #bind{type=pid,default=?nav};
unary_fun_result_type("to_string") ->           #bind{type=string,default=?nav};
unary_fun_result_type("to_term") ->             #bind{type=term,default=?nav};
unary_fun_result_type("to_text") ->             #bind{type=binstr,default=?nav};
unary_fun_result_type("to_timestamp") ->        #bind{type=timestamp,default=?nav};
unary_fun_result_type("to_ipaddr") ->           #bind{type=ipaddr,default=?nav};
unary_fun_result_type("to_time") ->             #bind{type=timestamp,default=?nav}; % ToDo: Type=time
unary_fun_result_type("to_tuple") ->            #bind{type=tuple,default=?nav};
unary_fun_result_type("safe_atom") ->           #bind{type=atom,default=?nav};
unary_fun_result_type("safe_binary") ->         #bind{type=binary,default=?nav};
unary_fun_result_type("safe_binstr") ->         #bind{type=binstr,default=?nav};
unary_fun_result_type("safe_binterm") ->        #bind{type=binterm,default=?nav};
unary_fun_result_type("safe_boolean") ->        #bind{type=boolean,default=?nav};
unary_fun_result_type("safe_datetime") ->       #bind{type=datetime,default=?nav};
unary_fun_result_type("safe_decimal") ->        #bind{type=decimal,default=?nav};
unary_fun_result_type("safe_float") ->          #bind{type=float,default=?nav};
unary_fun_result_type("safe_function") ->       #bind{type=function,default=?nav};
unary_fun_result_type("safe_integer") ->        #bind{type=integer,default=?nav};
unary_fun_result_type("safe_ipaddr") ->         #bind{type=ipaddr,default=?nav};
unary_fun_result_type("safe_json") ->           #bind{type=json,default=?nav};        
unary_fun_result_type("safe_list") ->           #bind{type=list,default=[]};
unary_fun_result_type("safe_map") ->            #bind{type=term,default=?nav};
unary_fun_result_type("safe_name") ->           #bind{type=binstr,default=?nav};
unary_fun_result_type("safe_pid") ->            #bind{type=pid,default=?nav};
unary_fun_result_type("safe_string") ->         #bind{type=string,default=?nav};
unary_fun_result_type("safe_term") ->           #bind{type=term,default=?nav};
unary_fun_result_type("safe_text") ->           #bind{type=binstr,default=?nav};
unary_fun_result_type("safe_timestamp") ->      #bind{type=timestamp,default=?nav};
unary_fun_result_type("safe_tuple") ->          #bind{type=tuple,default=?nav};
unary_fun_result_type(_) ->                     #bind{type=number,default=?nav}.

binary_fun_bind_type1(B) when is_binary(B) ->   binary_fun_bind_type1(binary_to_list(B));
binary_fun_bind_type1("element") ->             #bind{type=integer,default=?nav};
binary_fun_bind_type1("nth") ->                 #bind{type=integer,default=?nav};
binary_fun_bind_type1("is_like") ->             #bind{type=binstr,default=?nav};
binary_fun_bind_type1("is_key") ->              #bind{type=term,default=?nav};
binary_fun_bind_type1("is_regexp_like") ->      #bind{type=binstr,default=?nav};
binary_fun_bind_type1("to_decimal") ->          #bind{type=binstr,default=?nav};
binary_fun_bind_type1("from_decimal") ->        #bind{type=decimal,default=?nav};
binary_fun_bind_type1("json_arr_proj") ->       #bind{type=list,default=[]};
binary_fun_bind_type1("json_obj_proj") ->       #bind{type=list,default=[]};
binary_fun_bind_type1("json_value") ->          #bind{type=binstr,default=?nav};
binary_fun_bind_type1("json_diff") ->           #bind{type=binstr,default=?nav};
binary_fun_bind_type1("phash2") ->              #bind{type=term,default=?nav};
binary_fun_bind_type1("nvl_binstr") ->          #bind{type=binstr,default=?nav};
binary_fun_bind_type1("nvl_binary") ->          #bind{type=binary,default=?nav};
binary_fun_bind_type1("nvl_integer") ->         #bind{type=integer,default=?nav};
binary_fun_bind_type1("nvl_json") ->            #bind{type=json,default=?nav};
binary_fun_bind_type1("nvl_float") ->           #bind{type=float,default=?nav};
binary_fun_bind_type1("nvl_atom") ->            #bind{type=atom,default=?nav};
binary_fun_bind_type1("nvl_list") ->            #bind{type=list,default=?nav};
binary_fun_bind_type1("nvl_string") ->          #bind{type=string,default=?nav};
binary_fun_bind_type1("nvl_term") ->            #bind{type=term,default=?nav};
binary_fun_bind_type1("nvl_tuple") ->           #bind{type=tuple,default=?nav};
binary_fun_bind_type1("round") ->               #bind{type=number,default=?nav};
binary_fun_bind_type1("trunc") ->               #bind{type=timestamp,default=?nav};
binary_fun_bind_type1("split") ->               #bind{type=binstr,default=?nav};
binary_fun_bind_type1("slice") ->               #bind{type=binstr,default=?nav};
binary_fun_bind_type1("bits") ->                #bind{type=binary,default=?nav};
binary_fun_bind_type1("bytes") ->               #bind{type=binary,default=?nav};
binary_fun_bind_type1("map_get") ->             #bind{type=binstr,default=?nav};
binary_fun_bind_type1("map_merge") ->           #bind{type=map,default= #{}};
binary_fun_bind_type1("map_remove") ->          #bind{type=term,default=?nav};
binary_fun_bind_type1("map_with") ->            #bind{type=list,default= []};
binary_fun_bind_type1("map_without") ->         #bind{type=list,default= []};
binary_fun_bind_type1("cmp") ->                 #bind{type=term,default=?nav};
binary_fun_bind_type1("diff") ->                #bind{type=term,default=?nav};
binary_fun_bind_type1("diff_only") ->           #bind{type=term,default=?nav};
binary_fun_bind_type1(_) ->                     #bind{type=number,default=?nav}.

binary_fun_bind_type2(B) when is_binary(B) ->   binary_fun_bind_type2(binary_to_list(B));
binary_fun_bind_type2("element") ->             #bind{type=tuple,default=?nav};
binary_fun_bind_type2("nth") ->                 #bind{type=list,default=[]};
binary_fun_bind_type2("is_like") ->             #bind{type=binstr,default=?nav};
binary_fun_bind_type2("is_key") ->              #bind{type=map,default= #{}};
binary_fun_bind_type2("is_regexp_like") ->      #bind{type=binstr,default=?nav};
binary_fun_bind_type2("to_decimal") ->          #bind{type=integer,default=0};
binary_fun_bind_type2("from_decimal") ->        #bind{type=integer,default=0};
binary_fun_bind_type2("json_arr_proj") ->       #bind{type=list,default=[]};
binary_fun_bind_type2("json_obj_proj") ->       #bind{type=list,default=[]};
binary_fun_bind_type2("json_value") ->          #bind{type=json,default=[]};
binary_fun_bind_type2("json_diff") ->           #bind{type=json,default=?nav};
binary_fun_bind_type2("phash2") ->              #bind{type=integer,default=27};
binary_fun_bind_type2("nvl_atom") ->            #bind{type=atom,default=?nav};
binary_fun_bind_type2("nvl_binary") ->          #bind{type=binary,default=?nav};
binary_fun_bind_type2("nvl_binstr") ->          #bind{type=binstr,default=?nav};
binary_fun_bind_type2("nvl_float") ->           #bind{type=float,default=?nav};
binary_fun_bind_type2("nvl_integer") ->         #bind{type=integer,default=?nav};
binary_fun_bind_type2("nvl_json") ->            #bind{type=json,default=?nav};
binary_fun_bind_type2("nvl_list") ->            #bind{type=list,default=?nav};
binary_fun_bind_type2("nvl_string") ->          #bind{type=string,default=?nav};
binary_fun_bind_type2("nvl_term") ->            #bind{type=term,default=?nav};
binary_fun_bind_type2("nvl_tuple") ->           #bind{type=tuple,default=?nav};
binary_fun_bind_type2("round") ->               #bind{type=integer,default=0};
binary_fun_bind_type2("trunc") ->               #bind{type=integer,default=0};
binary_fun_bind_type2("split") ->               #bind{type=binstr,default=?nav};
binary_fun_bind_type2("slice") ->               #bind{type=integer,default=1};
binary_fun_bind_type2("bits") ->                #bind{type=integer,default=0};
binary_fun_bind_type2("bytes") ->               #bind{type=integer,default=0};
binary_fun_bind_type2("map_get") ->             #bind{type=map,default= #{}};
binary_fun_bind_type2("map_merge") ->           #bind{type=map,default= #{}};
binary_fun_bind_type2("map_remove") ->          #bind{type=map,default= #{}};
binary_fun_bind_type2("map_with") ->            #bind{type=map,default= #{}};
binary_fun_bind_type2("map_without") ->         #bind{type=map,default= #{}};
binary_fun_bind_type2("cmp") ->                 #bind{type=term,default=?nav};
binary_fun_bind_type2("diff") ->                #bind{type=term,default=?nav};
binary_fun_bind_type2("diff_only") ->           #bind{type=term,default=?nav};
binary_fun_bind_type2(_) ->                     #bind{type=number,default=?nav}.

binary_fun_result_type(B) when is_binary(B) ->  binary_fun_result_type(binary_to_list(B));
binary_fun_result_type("element") ->            #bind{type=term,default=?nav};
binary_fun_result_type("nth") ->                #bind{type=term,default=?nav};
binary_fun_result_type("is_like") ->            #bind{type=boolean,default=?nav};
binary_fun_result_type("is_key") ->             #bind{type=boolean,default=?nav};
binary_fun_result_type("is_regexp_like") ->     #bind{type=boolean,default=?nav};
binary_fun_result_type("to_decimal") ->         #bind{type=decimal,default=?nav};
binary_fun_result_type("from_decimal") ->       #bind{type=float,default=?nav};
binary_fun_result_type("json_arr_proj") ->      #bind{type=list,default=[]};
binary_fun_result_type("json_obj_proj") ->      #bind{type=list,default=[]};
binary_fun_result_type("json_value") ->         #bind{type=json,default=[]};
binary_fun_result_type("json_diff") ->          #bind{type=json,default=[]};
binary_fun_result_type("phash2") ->             #bind{type=integer,default=0};
binary_fun_result_type("nvl_atom") ->           #bind{type=atom,default=?nav};
binary_fun_result_type("nvl_binary") ->         #bind{type=binary,default=?nav};
binary_fun_result_type("nvl_binstr") ->         #bind{type=binstr,default=?nav};
binary_fun_result_type("nvl_float") ->          #bind{type=float,default=?nav};
binary_fun_result_type("nvl_integer") ->        #bind{type=integer,default=?nav};
binary_fun_result_type("nvl_json") ->           #bind{type=json,default=?nav};
binary_fun_result_type("nvl_list") ->           #bind{type=list,default=?nav};
binary_fun_result_type("nvl_string") ->         #bind{type=string,default=?nav};
binary_fun_result_type("nvl_term") ->           #bind{type=term,default=?nav};
binary_fun_result_type("nvl_tuple") ->          #bind{type=tuple,default=?nav};
binary_fun_result_type("round") ->              #bind{type=number,default=?nav};
binary_fun_result_type("trunc") ->              #bind{type=timestamp,default=?nav};
binary_fun_result_type("split") ->              #bind{type=list,default= []};
binary_fun_result_type("slice") ->              #bind{type=binstr,default=?nav};
binary_fun_result_type("bits") ->               #bind{type=integer,default=?nav};
binary_fun_result_type("bytes") ->              #bind{type=binary,default=?nav};
binary_fun_result_type("map_get") ->            #bind{type=map,default=?nav};
binary_fun_result_type("map_merge") ->          #bind{type=map,default=?nav};
binary_fun_result_type("map_remove") ->         #bind{type=map,default=?nav};
binary_fun_result_type("map_with") ->           #bind{type=map,default=?nav};
binary_fun_result_type("map_without") ->        #bind{type=map,default=?nav};
binary_fun_result_type("cmp") ->                #bind{type=binstr,default= <<>>};
binary_fun_result_type("diff") ->               #bind{type=binstr,default= <<>>};
binary_fun_result_type("diff_only") ->          #bind{type=binstr,default= <<>>};
binary_fun_result_type(_) ->                    #bind{type=number,default=?nav}.


ternary_fun_bind_type1(B) when is_binary(B) ->  ternary_fun_bind_type1(binary_to_list(B));
ternary_fun_bind_type1("mfa") ->                #bind{type=atom,default=?nav};
ternary_fun_bind_type1("slice") ->              #bind{type=binstr,default=?nav};
ternary_fun_bind_type1("bits") ->               #bind{type=binary,default=?nav};
ternary_fun_bind_type1("bytes") ->              #bind{type=binary,default=?nav};
ternary_fun_bind_type1("preview") ->            #bind{type=binstr,default=?nav};
ternary_fun_bind_type1("preview_keys") ->       #bind{type=binstr,default=?nav};
ternary_fun_bind_type1("cmp") ->                #bind{type=term,default=?nav};
ternary_fun_bind_type1("diff") ->               #bind{type=term,default=?nav};
ternary_fun_bind_type1("diff_only") ->          #bind{type=term,default=?nav};
ternary_fun_bind_type1(_) ->                    #bind{type=term,default=?nav}.

ternary_fun_bind_type2(B) when is_binary(B) ->  ternary_fun_bind_type2(binary_to_list(B));
ternary_fun_bind_type2("mfa") ->                #bind{type=atom,default=?nav};
ternary_fun_bind_type2("slice") ->              #bind{type=integer,default=1};
ternary_fun_bind_type2("bits") ->               #bind{type=integer,default=0};
ternary_fun_bind_type2("bytes") ->              #bind{type=integer,default=0};
ternary_fun_bind_type2("preview") ->            #bind{type=list,default=?nav};  % or integer index id accepted
ternary_fun_bind_type2("preview_keys") ->       #bind{type=list,default=?nav};  % or integer index id accepted
ternary_fun_bind_type2("cmp") ->                #bind{type=term,default=?nav};
ternary_fun_bind_type2("diff") ->               #bind{type=term,default=?nav};
ternary_fun_bind_type2("diff_only") ->          #bind{type=term,default=?nav};
ternary_fun_bind_type2(_) ->                    #bind{type=term,default=?nav}.

ternary_fun_bind_type3(B) when is_binary(B) ->  ternary_fun_bind_type3(binary_to_list(B));
ternary_fun_bind_type3("slice") ->              #bind{type=integer,default=1};
ternary_fun_bind_type3("bits") ->               #bind{type=integer,default=0};
ternary_fun_bind_type3("bytes") ->              #bind{type=integer,default=0};
ternary_fun_bind_type3("preview") ->            #bind{type=binstr,default=?nav};    % or integer search token accepted 
ternary_fun_bind_type3("preview_keys") ->       #bind{type=binstr,default=?nav};    % or integer search token accepted
ternary_fun_bind_type3("cmp") ->                #bind{type=list,default= []};
ternary_fun_bind_type3("diff") ->               #bind{type=list,default= []};
ternary_fun_bind_type3("diff_only") ->          #bind{type=list,default= []};
ternary_fun_bind_type3(_) ->                    #bind{type=term,default=?nav}.

ternary_fun_result_type(B) when is_binary(B) -> ternary_fun_result_type(binary_to_list(B));
ternary_fun_result_type("slice") ->             #bind{type=binstr,default=?nav};
ternary_fun_result_type("bits") ->              #bind{type=integer,default=?nav};
ternary_fun_result_type("bytes") ->             #bind{type=binary,default=?nav};
ternary_fun_result_type("preview") ->           #bind{type=list,default=?nav};
ternary_fun_result_type("preview_keys") ->      #bind{type=list,default=?nav};
ternary_fun_result_type("cmp") ->               #bind{type=binstr,default= <<>>};
ternary_fun_result_type("diff") ->              #bind{type=list,default= []};
ternary_fun_result_type("diff_only") ->         #bind{type=list,default= []};
ternary_fun_result_type(_) ->                   #bind{type=term,default=?nav}.

re_compile(?nav) -> ?nav;
re_compile(S) when is_list(S);is_binary(S) ->
    case (catch re:compile(S, [dotall]))  of
        {ok, MP} -> MP;
        _ ->        ?nav
    end;
re_compile(_) ->    ?nav.

like_compile(S) -> like_compile(S, <<>>).

like_compile(_, ?nav) -> ?nav;
like_compile(?nav, _) -> ?nav;
like_compile(S, Esc) when is_list(S); is_binary(S) -> re_compile(transform_like(S, Esc));
like_compile(_,_)     -> ?nav.

transform_like(S, Esc) ->
    list_to_binary(
      ["^", trns_like(
              re:replace(
                S,
                "([\\\\^$.\\[\\]|()?*+\\-{}])",
                "\\\\\\1",
                [global, {return, list}]),
              case Esc of
                  [C]     -> C;
                  <<C:8>> -> C;
                  _       -> '$none'
              end),
       "$"]).

trns_like([],             _) -> [];
trns_like([E,N      | R], E) -> [N     | trns_like(R,E)];
trns_like([$%,$%,$_ | R], E) -> [$%,$. | trns_like(R,E)];
trns_like([$%,$_    | R], E) -> [$_    | trns_like(R,E)];
trns_like([$%,$%    | R], E) -> [$%    | trns_like(R,E)];
trns_like([$%       | R], E) -> [$.,$* | trns_like(R,E)];
trns_like([$_       | R], E) -> [$.    | trns_like(R,E)];
trns_like([A        | R], E) -> [A     | trns_like(R,E)].

re_match(?nav, _) -> ?nav;
re_match(_, ?nav) -> ?nav;
re_match(RE, S) when is_binary(S) ->
    case re:run(S, RE) of
        nomatch ->  false;
        _ ->        true
    end;
re_match(RE, S) ->
    case re:run(lists:flatten(io_lib:format("~p", [S])), RE) of
        nomatch ->  false;
        _ ->        true
    end.

filter_fun(FTree) ->
    fun(X) -> 
        case expr_fun(FTree) of
            true ->     true;
            false ->    false;
            ?nav ->     false;
            F when is_function(F,1) ->
                case F(X) of
                    true ->     true;
                    false ->    false;
                    ?nav ->     false
                    %% Other ->    ?ClientError({"Filter function evaluating to non-boolean term",Other})
                end
        end
    end.

%% Constant tuple expressions
expr_fun({const, A}) when is_tuple(A) -> A;
%% create a list
expr_fun({list, L}) when is_list(L) -> 
    list_fun(lists:reverse([expr_fun(E) || E <- L]),[]);
expr_fun(L) when is_list(L) -> 
    list_fun(lists:reverse([expr_fun(E) || E <- L]),[]);
%% Select field Expression header
expr_fun(#bind{tind=0,cind=0,btree=BTree}) -> expr_fun(BTree);
%% Comparison expressions
% expr_fun({'==', Same, Same}) -> true;        %% TODO: Is this always true? (what if Same evaluates to ?nav)
% expr_fun({'/=', Same, Same}) -> false;       %% TODO: Is this always true? (what if Same evaluates to ?nav)
expr_fun({Op, A, B}) when Op=='==';Op=='>';Op=='>=';Op=='<';Op=='=<';Op=='/=' ->
    comp_fun({Op, A, B}); 
%% Mathematical expressions    
expr_fun({pi}) -> math:pi();
expr_fun({Op, A}) when Op=='+';Op=='-' ->
    math_fun({Op, A}); 
expr_fun({Op, A}) when Op==sqrt;Op==log;Op==log10;Op==exp;Op==erf;Op==erfc ->
    module_fun(math, {Op, A});
expr_fun({Op, A}) when Op==sin;Op==cos;Op==tan;Op==asin;Op==acos;Op==atan ->
    module_fun(math, {Op, A});
expr_fun({Op, A}) when Op==sinh;Op==cosh;Op==tanh;Op==asinh;Op==acosh;Op==atanh ->
    module_fun(math, {Op, A});
expr_fun({Op, A, B}) when Op=='+';Op=='-';Op=='*';Op=='/';Op=='div';Op=='rem' ->
    math_fun({Op, A, B});
expr_fun({Op, A, B}) when Op==pow;Op==atan2 ->
    module_fun(math, {Op, A, B});

%% Erlang module
expr_fun({Op, A}) when Op==abs;Op==length;Op==hd;Op==tl;Op==size;Op==tuple_size ->
    module_fun(erlang, {Op, A});
expr_fun({Op, A}) when Op==atom_to_list;Op==binary_to_float;Op==binary_to_integer;Op==binary_to_list ->
    module_fun(erlang, {Op, A});
expr_fun({Op, A}) when Op==bitstring_to_list;Op==binary_to_term;Op==bit_size;Op==byte_size;Op==crc32 ->
    module_fun(erlang, {Op, A});
expr_fun({Op, A}) when Op==float;Op==float_to_binary;Op==float_to_list;Op==fun_to_list;Op==tuple_to_list ->
    module_fun(erlang, {Op, A});
expr_fun({Op, A}) when Op==integer_to_binary;Op==integer_to_list;Op==fun_to_list;Op==list_to_float ->
    module_fun(erlang, {Op, A});
expr_fun({Op, A}) when Op==list_to_integer;Op==list_to_pid;Op==list_to_tuple;Op==phash2;Op==pid_to_list ->
    module_fun(erlang, {Op, A});
expr_fun({Op, A}) when Op==is_atom;Op==is_binary;Op==is_bitstring;Op==is_boolean ->
    module_fun(erlang, {Op, A});
expr_fun({Op, A}) when Op==is_atom;Op==is_binary;Op==is_boolean;Op==is_integer;Op==is_float;Op==is_function;Op==is_list;Op==is_map;Op==is_pid;Op==is_term;Op==is_tuple ->
    module_fun(erlang, {Op, A});
expr_fun({Op, A}) when Op==is_pid;Op==is_port;Op==is_reference;Op==is_tuple;Op==md5 ->
    module_fun(erlang, {Op, A});
expr_fun({Op, A, B}) when Op==is_function;Op==is_record;Op==atom_to_binary;Op==binary_part ->
    module_fun(erlang, {Op, A, B});
expr_fun({Op, A, B}) when  Op==integer_to_binary;Op==integer_to_list;Op==list_to_binary;Op==list_to_bitstring ->
    module_fun(erlang, {Op, A, B});
expr_fun({Op, A, B}) when  Op==list_to_integer;Op==max;Op==min;Op==phash2 ->
    module_fun(erlang, {Op, A, B});
expr_fun({Op, A, B}) when Op==crc32;Op==float_to_binary;Op==float_to_list ->
    module_fun(erlang, {Op, A, B});
expr_fun({Op, A, B}) when Op==atom_to_binary;Op==binary_to_integer;Op==binary_to_integer;Op==binary_to_term ->
    module_fun(erlang, {Op, A, B});
%% lists module and others
expr_fun({Op, A}) when Op==last;Op==reverse;Op==sort;Op==usort ->
    module_fun(lists, {Op, A});
expr_fun({Op, A}) when Op==vnf_identity;Op==vnf_lcase_ascii;Op==vnf_lcase_ascii_ne;Op==vnf_tokens;Op==vnf_integer;Op==vnf_float;Op==vnf_datetime;Op==vnf_datetime_ne ->
    module_fun(imem_index, {Op, A});
expr_fun({Op, A}) when Op==integer_uid;Op==time_uid;Op==time ->
    module_fun(imem_meta, {Op, A});
expr_fun({Op, A}) when Op==cmp_white_space; Op==norm_white_space ->
    module_fun(imem_cmp, {Op, A});
expr_fun({Op, A, B}) when Op==nth;Op==member;Op==merge;Op==nthtail;Op==seq;Op==sublist;Op==subtract;Op==usort ->
    module_fun(lists, {Op, A, B});
%% maps module
expr_fun({Op, A}) when Op==map_size ->
    module_fun(maps, {size, A});
expr_fun({Op, A, B}) when Op==map_get;Op==map_merge;Op==map_remove;Op==map_with;Op==map_without->
    module_fun(maps, {list_to_atom(lists:nthtail(4,atom_to_list(Op))), A, B});
%% Logical expressions
expr_fun({'not', A}) ->
    case expr_fun(A) of
        F when is_function(F) ->    fun(X) -> ternary_not(F(X)) end;
        V ->                        ternary_not(V)
    end;                       
expr_fun({'and', A, B}) ->
    Fa = expr_fun(A),
    Fb = expr_fun(B),
    case {Fa,Fb} of
        {true,true} ->  true;
        {false,_} ->    false;
        {_,false} ->    false;
        {true,_} ->     Fb;         %% may be ?nav or a fun evaluating to ?nav
        {_,true} ->     Fa;         %% may be ?nav or a fun evaluating to ?nav
        {_,_} ->        fun(X) -> ternary_and(Fa(X),Fb(X)) end
    end;
expr_fun({'or', A, B}) ->
    Fa = expr_fun(A),
    Fb = expr_fun(B),
    case {Fa,Fb} of
        {false,false}-> false;
        {true,_} ->     true;
        {_,true} ->     true;
        {false,_} ->    Fb;         %% may be ?nav or a fun evaluating to ?nav
        {_,false} ->    Fa;         %% may be ?nav or a fun evaluating to ?nav
        {_,_} ->        fun(X) -> ternary_or(Fa(X),Fb(X)) end
    end;
%% Unary custom filters
expr_fun({Op, A}) when Op==safe_atom;Op==safe_binary;Op==safe_binstr;Op==safe_binterm;Op==safe_boolean;Op==safe_datetime;Op==safe_decimal;Op==safe_integer;Op==safe_ipaddr;Op==safe_json;Op==safe_float;Op==safe_json;Op==safe_list;Op==safe_map;Op==safe_name;Op==safe_pid;Op==safe_string;Op==safe_term;Op==safe_text;Op==safe_timestamp;Op==safe_tuple ->
    safe_fun(A);
expr_fun({Op, A}) when Op==to_atom;Op==to_binary;Op==to_binstr;Op==list_to_binstr;Op==to_binterm;Op==to_boolean;Op==to_datetime;Op==to_decimal;Op==to_json;Op==to_float;Op==to_integer;Op==to_json;Op==to_list ->
    unary_fun({Op, A});
expr_fun({Op, A}) when Op==to_map;Op==to_name;Op==to_number;Op==to_pid;Op==to_string;Op==to_term;Op==to_text;Op==to_timestamp;Op==to_time;Op==to_tuple ->
    unary_fun({Op, A});
expr_fun({Op, A}) when Op==from_binterm;Op==prefix_ul;Op==phash2;Op==is_nav;Op==is_val;Op==to_ipaddr ->
    unary_fun({Op, A});
expr_fun({Op, A}) when Op==is_binstr;Op==is_binterm;Op==is_datetime;Op==is_decimal;Op==is_ipaddr;Op==is_json;Op==is_json;Op==is_name;Op==is_string;Op==is_text;Op==is_timestamp ->
    unary_fun({Op, A});
expr_fun({Op, A}) when Op==round;Op==trunc;Op==upper;Op==lower ->
    unary_fun({Op, A});
expr_fun({Op, A}) when Op=='#keys';Op=='#key';Op=='#values';Op=='#value';Op==json_to_list->
    unary_json_fun({Op, A});
expr_fun({Op, A}) ->
    ?UnimplementedException({"Unsupported expression operator", {Op, A}});
%% Binary custom filters
expr_fun({Op, A, B}) when Op==is_member;Op==is_like;Op==is_regexp_like;Op==element;Op==concat;Op==is_key;Op==trunc;Op==round ->
    binary_fun({Op, A, B});
expr_fun({Op, A, B}) when Op==to_decimal;Op==from_decimal;Op==add_dt;Op==add_ts;Op==slice;Op==bits;Op==bytes;Op==split ->
    binary_fun({Op, A, B});
expr_fun({Op, A, B}) when Op==nvl_atom;Op==nvl_binary;Op==nvl_binstr;Op==nvl_float;Op==nvl_integer;Op==nvl_json;Op==nvl_term;Op==nvl_tuple ->
    binary_fun({Op, A, B});
expr_fun({Op, A, B}) when Op==json_arr_proj;Op==json_obj_proj;Op==json_value;Op==json_diff;Op==cmp;Op==diff;Op==diff_only ->
    binary_fun({Op, A, B});
expr_fun({Op, A, B}) ->
    ?UnimplementedException({"Unsupported expression operator", {Op, A, B}});
%% Ternary custom filters
expr_fun({Op, A, B, C}) when Op==remap;Op==mfa;Op==slice;Op==preview;Op==preview_keys;Op==bits;Op==bytes;Op==cmp;Op==diff;Op==diff_only ->
    ternary_fun({Op, A, B, C});
expr_fun({Op, A, B, C}) ->
    ?UnimplementedException({"Unsupported function arity 3", {Op, A, B, C}});
expr_fun({Op, A, B, C, D}) ->
    ?UnimplementedException({"Unsupported function arity 4", {Op, A, B, C, D}});
expr_fun(Value)  -> Value.

bind_action(P) when is_function(P) -> true;     %% parameter already bound to function
bind_action(#bind{tind=0,cind=0}=P) ->          ?SystemException({"Unexpected expression binding",P});
bind_action(#bind{}=P) -> P;                    %% find bind by tag name or return false for value prameter
bind_action(_) -> false. 

safe_fun(A) ->
    Fa = expr_fun(A),
    safe_fun_final(Fa).

safe_fun_final(A) ->
    case bind_action(A) of 
        false ->            A;        
        true ->             fun(X) -> try A(X) catch _:_ -> ?nav end end;       
        ABind ->            fun(X) -> try ?BoundVal(ABind,X) catch _:_ -> ?nav end end
    end.

list_fun([],Acc) ->     Acc;
list_fun([A],Acc) when is_list(Acc) -> 
    case bind_action(A) of 
        false ->        [A|Acc];
        true ->         fun(X) -> [A(X)|Acc] end;
        ABind ->        fun(X) -> [?BoundVal(ABind,X)|Acc] end
    end;
list_fun([A],Acc) -> 
    case bind_action(A) of 
        false ->        fun(X) -> [A|Acc(X)] end;
        true ->         fun(X) -> [A(X)|Acc(X)] end;
        ABind ->        fun(X) -> [?BoundVal(ABind,X)|Acc(X)] end
    end;
list_fun([A|Rest],Acc) when is_list(Acc) -> 
    case bind_action(A) of 
        false ->        list_fun(Rest,[A|Acc]);
        true ->         list_fun(Rest,fun(X) -> [A(X)|Acc] end);
        ABind ->        list_fun(Rest,fun(X) -> [?BoundVal(ABind,X)|Acc] end)
    end;
list_fun([A|Rest],Acc) -> 
    case bind_action(A) of 
        false ->        list_fun(Rest,fun(X) -> [A|Acc(X)] end);
        true ->         list_fun(Rest,fun(X) -> [A(X)|Acc(X)] end);
        ABind ->        list_fun(Rest,fun(X) -> [?BoundVal(ABind,X)|Acc(X)] end)
    end.

module_fun(Mod, {Op, {const,A}}) when is_tuple(A) ->
    module_fun_final(Mod, {Op, A});
module_fun(Mod, {Op, A}) ->
    module_fun_final(Mod, {Op, expr_fun(A)});
module_fun(Mod, {Op, {const,A}, {const,B}}) when is_tuple(A),is_tuple(B)->
    module_fun_final(Mod, {Op, A, B});
module_fun(Mod, {Op, {const,A}, B}) when is_tuple(A) ->
    module_fun_final(Mod, {Op, A, expr_fun(B)});
module_fun(Mod, {Op, A, {const,B}}) when is_tuple(B) ->
    module_fun_final(Mod, {Op, expr_fun(A), B});
module_fun(Mod, {Op, A, B}) ->
    Fa = expr_fun(A),
    Fb = expr_fun(B),
    module_fun_final(Mod, {Op, Fa, Fb}).

module_fun_final(Mod, {Op, A}) -> 
    case bind_action(A) of 
        false ->        mod_op_1(Mod,Op,A);
        true ->         fun(X) -> mod_op_1(Mod,Op,A(X)) end;
        ABind ->        fun(X) -> mod_op_1(Mod,Op,?BoundVal(ABind,X)) end
    end;
module_fun_final(Mod, {Op, A, B}) -> 
    case {bind_action(A),bind_action(B)} of 
        {false,false} ->        mod_op_2(Mod,Op,A,B);
        {false,true} ->         fun(X) -> mod_op_2(Mod,Op,A,B(X)) end;
        {false,BBind} ->        fun(X) -> mod_op_2(Mod,Op,A,?BoundVal(BBind,X)) end;
        {true,false} ->         fun(X) -> mod_op_2(Mod,Op,A(X),B) end;
        {true,true} ->          fun(X) -> mod_op_2(Mod,Op,A(X),B(X)) end; 
        {true,BBind} ->         fun(X) -> mod_op_2(Mod,Op,A(X),?BoundVal(BBind,X)) end; 
        {ABind,false} ->        fun(X) -> mod_op_2(Mod,Op,?BoundVal(ABind,X),B) end; 
        {ABind,true} ->         fun(X) -> mod_op_2(Mod,Op,?BoundVal(ABind,X),B(X)) end; 
        {ABind,BBind} ->        fun(X) -> mod_op_2(Mod,Op,?BoundVal(ABind,X),?BoundVal(BBind,X)) end 
    end.

mod_op_1(_,_,?nav) -> ?nav;
mod_op_1(Mod,Op,A) -> 
    try     Mod:Op(A)
    catch   _:_ -> ?nav 
    end.

mod_op_2(?MODULE,Op,?nav,B) when Op==nvl_atom;Op==nvl_binary;Op==nvl_binstr;Op==nvl_float;Op==nvl_integer;Op==nvl_json;Op==nvl_term;Op==nvl_tuple -> B;
mod_op_2(?MODULE,Op,A,_) when Op==nvl_atom;Op==nvl_binary;Op==nvl_binstr;Op==nvl_float;Op==nvl_integer;Op==nvl_json;Op==nvl_term;Op==nvl_tuple -> A;
mod_op_2(_,_,_,?nav) -> ?nav;
mod_op_2(_,_,?nav,_) -> ?nav;
mod_op_2(Mod,Op,A,B) -> 
    try     Mod:Op(A,B)
    catch   _:_ -> ?nav
    end.

mod_op_3(_,_,_,_,?nav) -> ?nav;
mod_op_3(_,_,_,?nav,_) -> ?nav;
mod_op_3(_,_,?nav,_,_) -> ?nav;
mod_op_3(Mod,Op,A,B,C) -> 
    try     Mod:Op(A,B,C)
    catch   _:_ -> ?nav
    end.

math_fun({Op, A}) ->
    math_fun_unary({Op, expr_fun(A)});
math_fun({Op, A, B}) ->
    Fa = expr_fun(A),
    Fb = expr_fun(B),
    math_fun_binary({Op, Fa, Fb}).

math_fun_unary({'+', A}) ->
    case bind_action(A) of 
        false ->            math_plus(A);        
        true ->             fun(X) -> math_plus(A(X)) end;       
        ABind ->            fun(X) -> math_plus(?BoundVal(ABind,X)) end
    end;
math_fun_unary({'-', A}) ->
    case bind_action(A) of 
        false ->            math_minus(A);        
        true ->             fun(X) -> math_minus(A(X)) end;
        ABind ->            fun(X) -> math_minus(?BoundVal(ABind,X)) end
    end.

math_plus(?nav) ->                  ?nav;
math_plus(A) when is_number(A) ->   A;
math_plus(_) ->                     ?nav.

math_minus(?nav) ->                 ?nav;
math_minus(A) when is_number(A) ->  (-A);
math_minus(_) ->                    ?nav.

-define(MathOpBlockBinary(__Op,__A,__B), 
        case __Op of
            '+'  when is_list(__A), is_list(__B) ->                     (__A ++ __B);
            '+'  when is_map(__A), is_map(__B) ->                       maps:merge(__A,__B);
            '-'  when is_list(__A), is_list(__B) ->                     (__A -- __B);
            '-'  when is_map(__A), is_list(__B) ->                      maps:without(__B,__A);
            _ when (is_number(__A)==false);(is_number(__B)==false) ->   ?nav;
            '+'  ->      (__A + __B);
            '-'  ->      (__A - __B);
            '*'  ->      (__A * __B);
            '/'  ->      (__A / __B);
            'div'  ->    (__A div __B);
            'rem'  ->    (__A rem __B)
        end).

math_fun_binary({Op, A, B}) ->
    case {bind_action(A),bind_action(B)} of 
        {false,false} ->    ?MathOpBlockBinary(Op,A,B);
        {false,true} ->     fun(X) -> Bb=B(X),?MathOpBlockBinary(Op,A,Bb) end;
        {false,BBind} ->    fun(X) -> Bb=?BoundVal(BBind,X),?MathOpBlockBinary(Op,A,Bb) end;
        {true,false} ->     fun(X) -> Ab=A(X),?MathOpBlockBinary(Op,Ab,B) end;
        {true,true} ->      fun(X) -> Ab=A(X),Bb=B(X),?MathOpBlockBinary(Op,Ab,Bb) end;  
        {true,BBind} ->     fun(X) -> Ab=A(X),Bb=?BoundVal(BBind,X),?MathOpBlockBinary(Op,Ab,Bb) end;  
        {ABind,false} ->    fun(X) -> Ab=?BoundVal(ABind,X),?MathOpBlockBinary(Op,Ab,B) end;  
        {ABind,true} ->     fun(X) -> Ab=?BoundVal(ABind,X),Bb=B(X),?MathOpBlockBinary(Op,Ab,Bb) end;  
        {ABind,BBind} ->    fun(X) -> Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),?MathOpBlockBinary(Op,Ab,Bb) end
    end.

comp_fun({Op, {const,A}, {const,B}}) when is_tuple(A),is_tuple(B)->
    comp_fun_final({Op, A, B});
comp_fun({Op, {const,A}, B}) when is_tuple(A) ->
    comp_fun_final({Op, A, expr_fun(B)});
comp_fun({Op, A, {const,B}}) when is_tuple(B) ->
    comp_fun_final({Op, expr_fun(A), B});
comp_fun({Op, A, B}) ->
    Fa = expr_fun(A),
    Fb = expr_fun(B),
    comp_fun_final({Op, Fa, Fb}).


-define(CompOpBlock(__Op,__A,__B), 
        case __Op of
             _   when __A==?nav;__B==?nav -> ?nav;
            '==' ->  (__A==__B);
            '>'  ->  (__A>__B);
            '>=' ->  (__A>=__B);
            '<'  ->  (__A<__B);
            '=<' ->  (__A=<__B);
            '/=' ->  (__A/=__B)
        end).

comp_fun_final({Op, A, B}) ->
    case {bind_action(A),bind_action(B)} of 
        {false,false} ->    ?CompOpBlock(Op,A,B);
        {false,true} ->     fun(X) -> Bb=B(X),?CompOpBlock(Op,A,Bb) end;
        {false,BBind} ->    fun(X) -> Bb=?BoundVal(BBind,X),?CompOpBlock(Op,A,Bb) end;
        {true,false} ->     fun(X) -> Ab=A(X),?CompOpBlock(Op,Ab,B) end;
        {true,true} ->      fun(X) -> Ab=A(X),Bb=B(X),?CompOpBlock(Op,Ab,Bb) end;  
        {true,BBind} ->     fun(X) -> Ab=A(X),Bb=?BoundVal(BBind,X),?CompOpBlock(Op,Ab,Bb) end;  
        {ABind,false} ->    fun(X) -> Ab=?BoundVal(ABind,X),?CompOpBlock(Op,Ab,B) end;  
        {ABind,true} ->     fun(X) -> Ab=?BoundVal(ABind,X),Bb=B(X),?CompOpBlock(Op,Ab,Bb) end;  
        {ABind,BBind} ->    fun(X) -> Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),?CompOpBlock(Op,Ab,Bb) end
    end.

unary_fun({Op, {const,A}}) when is_tuple(A) ->
    unary_fun_final({Op, A});
unary_fun({Op, A}) ->
    unary_fun_final( {Op, expr_fun(A)});
unary_fun(Value) -> Value.

unary_fun_final({is_val, A}) -> 
    case bind_action(A) of 
        false ->        is_val(A);
        true ->         fun(X) -> Ab=A(X),is_val(Ab) end;
        ABind ->        fun(X) -> Ab=?BoundVal(ABind,X),is_val(Ab) end
    end;
unary_fun_final({is_nav, A}) -> 
    case bind_action(A) of 
        false ->        is_nav(A);
        true ->         fun(X) -> Ab=A(X),is_nav(Ab) end;
        ABind ->        fun(X) -> Ab=?BoundVal(ABind,X),is_nav(Ab) end
    end;
unary_fun_final({Op, A}) -> 
    case bind_action(A) of 
        false ->        mod_op_1(?MODULE,Op,A);
        true ->         fun(X) -> Ab=A(X),mod_op_1(?MODULE,Op,Ab) end;
        ABind ->        fun(X) -> Ab=?BoundVal(ABind,X),mod_op_1(?MODULE,Op,Ab) end
    end.

is_nav(?nav) -> true;
is_nav(_) -> false.

is_val(?nav) -> false;
is_val(_) -> true.

is_binstr(A) -> is_binary(A).   % TODO: not precise enough

is_binterm(A) -> is_binary(A).  % TODO: not precise enough

is_datetime({{A,B,C},{D,E,F}}) when is_integer(A),is_integer(B),is_integer(C),is_integer(D),is_integer(E),is_integer(F) -> true;
is_datetime(_) -> false.        % TODO: not precise enough

is_decimal(A) -> is_integer(A).

is_ipaddr({A,B,C,D}) when is_integer(A),is_integer(B),is_integer(C),is_integer(D) -> true; 
is_ipaddr(_) -> false.          % TODO: not precise enough

is_json(A) ->   is_binary(A).   % TODO: not precise enough

is_name(A) ->   is_binary(A).   % TODO: not precise enough

is_string(A) -> is_list(A).     % TODO: not precise enough

is_text(A) ->   is_list(A).     % TODO: not precise enough

is_timestamp({A, B, C, D}) when is_integer(A), is_integer(B), is_atom(C), is_integer(D) -> true;
is_timestamp({A, B}) when is_integer(A), is_integer(B) -> true;
is_timestamp({A, B, C}) when is_integer(A), is_integer(B), is_integer(C) -> true;   % remove later
is_timestamp(_) -> false.       % TODO: not precise enough

upper(S) when is_binary(S) ->   unicode:characters_to_binary(string:uppercase(unicode:characters_to_list(S, utf8)), unicode, utf8);
upper(S) when is_list(S) ->     string:uppercase(S);
upper(S) ->     S.

lower(S) when is_binary(S) ->   unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(S, utf8)), unicode, utf8);
lower(S) when is_list(S) ->     string:lowercase(S);
lower(S) ->     S.

split(S,Sep) when is_binary(S) -> string:split(S,Sep,all);
split(S,Sep) when is_list(S) -> string:split(S,Sep,all);
split(E,_) ->   [E].

to_atom(A) when is_atom(A) -> A;
to_atom(B) when is_binary(B) -> ?binary_to_atom(B);
to_atom(L) when is_list(L) -> list_to_atom(L).

to_boolean(A) when is_boolean(A) -> A;
to_boolean(L) when is_list(L) -> to_boolean(list_to_binary(L));
to_boolean(<<"true">>) -> true;
to_boolean(<<"false">>) -> false;
to_boolean(_) -> ?nav.

to_name(T) when is_tuple(T) ->
    imem_datatype:io_to_binstr(string:join([imem_datatype:strip_squotes(to_string(E)) || E <- tuple_to_list(T)],"."));
to_name(E) -> imem_datatype:strip_squotes(to_binstr(E)).

to_text(T) when is_binary(T) ->
    to_text(binary_to_list(T));
to_text(T) when is_list(T) ->
    try
        Mask=fun(X) ->
                case unicode:characters_to_list([X], unicode) of
                    [X] when (X<16#20) ->   $.;
                    [X]  ->   X;
                     _ -> 
                        case unicode:characters_to_list([X], latin1) of
                            [Y] -> Y;
                             _ ->  $.
                        end
                end
            end,
        unicode:characters_to_binary(lists:map(Mask,T),unicode)
    catch
        _:_ -> imem_datatype:term_to_io(T)
    end;
to_text(T) ->
    imem_datatype:term_to_io(T).

to_tuple(B) when is_binary(B) -> imem_datatype:io_to_tuple(B,0);
to_tuple(T) when is_tuple(T) -> T.

to_list(B) when is_binary(B) -> 
    try imem_datatype:io_to_list(B,0)
    catch _:_ -> ?nav
    end;
to_list(M) when is_map(M) -> maps:to_list(M);
to_list(L) when is_list(L) -> L.

to_map(M) when is_map(M) ->     M;
to_map(L) when is_list(L) ->    maps:from_list(L);
to_map(B) when is_binary(B) ->  
    case catch imem_datatype:io_to_map(B) of        
        M when is_map(M) -> 
            M;
        _ ->                
            imem_json:decode(B, [return_maps])
    end.

to_term(B) when is_binary(B) -> 
    try imem_datatype:io_to_term(B)
    catch _:_ -> ?nav
    end;
to_term(T) -> T.

to_json(N) when is_number(N) -> N; 
to_json(true) -> true;
to_json(false) -> false;
to_json(null) -> null;
to_json(B) when is_binary(B) ->
    try 
        imem_json:decode(B)
    catch _:_ -> B
    end;
to_json(L) when is_list(L) -> L;
    % case catch imem_json:encode(L) of 
    %     JO when is_binary(JO) -> JO;
    %     _ ->    ?nav
    % end;
to_json(M) when is_map(M) ->  
    try 
        imem_json:to_proplist(M)
    catch _:_ ->  ?nav
    end;
to_json(_) -> ?nav.
to_pid(T) when is_pid(T) -> T;
to_pid(B) -> 
    try imem_datatype:io_to_pid(B)
    catch _:_ -> ?nav
    end.

to_existing_atom(A) when is_atom(A) -> A;
to_existing_atom(B) when is_binary(B) -> 
    try ?binary_to_existing_atom(B)
    catch _:_ -> ?nav
    end;
to_existing_atom(L) when is_list(L) -> 
    try list_to_existing_atom(L)
    catch _:_ -> ?nav
    end;
to_existing_atom(_) -> ?nav.

to_integer(B) when is_binary(B) -> 
    try to_integer(binary_to_list(B))
    catch _:_ -> ?nav
    end;
to_integer(I) when is_integer(I) -> I;
to_integer(F) when is_float(F) -> erlang:round(F);
to_integer(L) when is_list(L) -> 
    try list_to_integer(L)
    catch _:_ -> ?nav
    end;
to_integer(_) -> ?nav.

to_float(B) when is_binary(B) -> to_float(binary_to_list(B));
to_float(F) when is_float(F) -> F;
to_float(I) when is_integer(I) -> I + 0.0;
to_float(L) when is_list(L) -> 
    case (catch list_to_integer(L)) of
        I when is_integer(I) -> float(I);
        _ -> list_to_float(L)
    end.

to_number(B) when is_binary(B) -> 
    try to_number(binary_to_list(B))
    catch _:_ -> ?nav
    end;
to_number(F) when is_float(F) -> F;
to_number(I) when is_integer(I) -> I;
to_number(L) when is_list(L) -> 
    case (catch list_to_integer(L)) of
        I when is_integer(I) -> I;
        _ -> 
            try list_to_float(L)
            catch _:_ -> ?nav
            end
    end.

to_string(B) when is_binary(B) ->   binary_to_list(B);
to_string(I) when is_integer(I) -> integer_to_list(I);
to_string(F) when is_float(F) -> float_to_list(F);
to_string(A) when is_atom(A) -> atom_to_list(A);
to_string(X) -> io_lib:format("~p", [X]).

to_binstr(B) when is_binary(B) ->   B;
to_binstr(I) when is_integer(I) -> list_to_binary(integer_to_list(I));
to_binstr(F) when is_float(F) -> list_to_binary(float_to_list(F));
to_binstr(A) when is_atom(A) -> list_to_binary(atom_to_list(A));
to_binstr(X) -> list_to_binary(io_lib:format("~p", [X])).

list_to_binstr(X) -> 
    try list_to_binary(io_lib:format("~s", [X]))
    catch _:_ -> ?nav
    end.

to_binary(B) when is_binary(B) ->   B;
to_binary(I) when is_integer(I) -> <<I/integer>>;
to_binary(_) -> ?nav.

to_binterm(B) when is_binary(B) ->  imem_datatype:io_to_binterm(B);
to_binterm(T) ->                    imem_datatype:term_to_binterm(T).

to_datetime(B) when is_binary(B) -> imem_datatype:io_to_datetime(B);
to_datetime(L) when is_list(L) ->   imem_datatype:io_to_datetime(L);
to_datetime(T) when is_tuple(T) ->  T.

to_timestamp(B) when is_binary(B)-> imem_datatype:io_to_timestamp(B);
to_timestamp(L) when is_list(L) ->  imem_datatype:io_to_timestamp(L);   
to_timestamp({Secs, Micros})  ->    {Secs, Micros, node(), 0};
to_timestamp({Megas, Secs, Micros}) -> {1000000*Megas+Secs, Micros, node(), 0};  % remove later
to_timestamp({Secs, Micros, Node, Cnt}) -> {Secs, Micros, Node, Cnt}.

to_time(B) when is_binary(B) ->     Time = imem_datatype:io_to_timestamp(B),
                                    {element(1, Time), element(2, Time)};
to_time(L) when is_list(L) ->       Time = imem_datatype:io_to_timestamp(L),
                                    {element(1, Time), element(2, Time)};
to_time({Secs, Micros})  ->         {Secs, Micros};
to_time({Megas, Secs, Micros})  ->  {1000000*Megas+Secs, Micros};  % remove later
to_time({Secs, Micros, _, _})->     {Secs, Micros}.

to_ipaddr(B) when is_binary(B) ->   imem_datatype:io_to_ipaddr(B);
to_ipaddr(L) when is_list(L) ->     imem_datatype:io_to_ipaddr(L);
to_ipaddr(T) when is_tuple(T) ->    T.

from_binterm(B)  ->                 imem_datatype:binterm_to_term(B).

prefix_ul(L) when is_list(L) ->     L ++ <<255>>. % improper list [...|<<255>>]

unary_json_fun({_, {const,A}}) when is_tuple(A) ->
    ?nav;
unary_json_fun({Op, A}) ->
    unary_json_fun_final( {Op, expr_fun(A)});
unary_json_fun(Value) -> Value.

unary_json_fun_final({Op, A}) -> 
    case bind_action(A) of 
        false ->        mod_op_1(?MODULE,Op,A);
        true ->         fun(X) -> Ab=A(X),mod_op_1(?MODULE,Op,Ab) end;
        ABind ->        fun(X) -> Ab=?BoundVal(ABind,X),mod_op_1(?MODULE,Op,Ab) end
    end.

'#keys'(O) when is_map(O) -> maps:keys(O);
'#keys'(O) when is_list(O);is_binary(O) -> imem_json:keys(O);
'#keys'(_) -> ?nav.

'#key'(O) when is_list(O);is_map(O);is_binary(O) -> safe_hd(imem_json:keys(O));
'#key'(_) -> ?nav.

'#values'(O) when is_map(O) -> maps:values(O);
'#values'(O) when is_list(O);is_binary(O) -> imem_json:values(O);
'#values'(_) -> ?nav.

'#value'(O) when is_list(O);is_map(O);is_binary(O) -> safe_hd(imem_json:values(O));
'#value'(_) -> ?nav.

safe_hd([]) -> ?nav;
safe_hd(L) -> hd(L).

json_to_list(O) when is_list(O);is_map(O);is_binary(O) -> imem_json:to_proplist(O).

binary_fun({Op, {const,A}, {const,B}}) when is_tuple(A), is_tuple(B) ->
    binary_fun_final({Op, A, B});
binary_fun({Op, {const,A}, B}) when is_tuple(A) ->
    binary_fun_final({Op, A, expr_fun(B)});
binary_fun({Op, A, {const,B}}) when is_tuple(B) ->
    binary_fun_final({Op, expr_fun(A), B});
binary_fun({Op, A, B}) ->
    FA = expr_fun(A),
    FB = expr_fun(B),
    binary_fun_final( {Op, FA, FB});
binary_fun(Value) -> Value.

-define(ElementOpBlock(__A,__B), 
    if 
        (not is_number(__A)) -> ?nav; 
        (not is_tuple(__B)) -> ?nav;
        (not tuple_size(__B) >= __A) -> ?nav;
        true -> element(__A,__B)
    end).

binary_fun_final({element, A, B})  ->
    case {bind_action(A),bind_action(B)} of 
        {false,false} ->    ?ElementOpBlock(A,B);
        {false,true} ->     fun(X) -> Bb=B(X),?ElementOpBlock(A,Bb) end;
        {false,BBind} ->    fun(X) -> Bb=?BoundVal(BBind,X),?ElementOpBlock(A,Bb) end;
        {true,false} ->     fun(X) -> Ab=A(X),?ElementOpBlock(Ab,B) end;
        {true,true} ->      fun(X) -> Ab=A(X),Bb=B(X),?ElementOpBlock(Ab,Bb) end;
        {true,BBind} ->     fun(X) -> Ab=A(X),Bb=?BoundVal(BBind,X),?ElementOpBlock(Ab,Bb) end;
        {ABind,false} ->    fun(X) -> Ab=?BoundVal(ABind,X),?ElementOpBlock(Ab,B) end;
        {ABind,true} ->     fun(X) -> Ab=?BoundVal(ABind,X),Bb=B(X),?ElementOpBlock(Ab,Bb) end;
        {ABind,BBind} ->    fun(X) -> Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),?ElementOpBlock(Ab,Bb) end
    end;
binary_fun_final({is_like, A, B})  ->
    case {bind_action(A),bind_action(B)} of 
        {false,false} ->    re_match(like_compile(B),A);
        {false,true} ->     fun(X) -> Bb=B(X),re_match(like_compile(Bb),A) end;
        {false,BBind} ->    fun(X) -> Bb=?BoundVal(BBind,X),re_match(like_compile(Bb),A) end;
        {true,false} ->     RE = like_compile(B),fun(X) -> Ab=A(X),re_match(RE,Ab) end;
        {true,true} ->      fun(X) -> Ab=A(X),Bb=B(X),re_match(like_compile(Bb),Ab) end;
        {true,BBind} ->     fun(X) -> Ab=A(X),Bb=?BoundVal(BBind,X),re_match(like_compile(Ab),Bb) end;
        {ABind,false} ->    RE = like_compile(B),fun(X) -> Bb=?BoundVal(ABind,X),re_match(RE,Bb) end;
        {ABind,true} ->     fun(X) -> Ab=?BoundVal(ABind,X),Bb=B(X),re_match(like_compile(Bb),Ab) end;
        {ABind,BBind} ->    fun(X) -> Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),re_match(like_compile(Bb),Ab) end
    end;
binary_fun_final({is_regexp_like, A, B})  ->
    case {bind_action(A),bind_action(B)} of 
        {false,false} ->    re_match(re_compile(B),A);
        {false,true} ->     fun(X) -> Bb=B(X),re_match(re_compile(Bb),A) end;
        {false,BBind} ->    fun(X) -> Bb=?BoundVal(BBind,X),re_match(re_compile(Bb),A) end;
        {true,false} ->     RE = re_compile(B),fun(X) -> Ab=A(X),re_match(RE,Ab) end;
        {true,true} ->      fun(X) -> Ab=A(X),Bb=B(X),re_match(re_compile(Bb),Ab) end;
        {true,BBind} ->     fun(X) -> Ab=A(X),Bb=?BoundVal(BBind,X),re_match(re_compile(Ab),Bb) end;
        {ABind,false} ->    RE = re_compile(B),fun(X) -> Ab=?BoundVal(ABind,X),re_match(RE,Ab) end;
        {ABind,true} ->     fun(X) -> Ab=?BoundVal(ABind,X),Bb=B(X),re_match(re_compile(Bb),Ab) end;
        {ABind,BBind} ->    fun(X) -> Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),re_match(re_compile(Bb),Ab) end
    end;
binary_fun_final({Op, A, B}) when Op==to_decimal;Op==from_decimal;Op==add_dt;Op==add_ts;Op==is_member;Op==concat;Op==trunc;Op==round;Op==json_arr_proj;Op==json_obj_proj;Op==json_value;Op==json_diff;Op==is_key;Op==slice;Op==bits;Op==bytes ->
    case {bind_action(A),bind_action(B)} of 
        {false,false} ->    mod_op_2(?MODULE,Op,A,B);        
        {false,true} ->     fun(X) -> Bb=B(X),mod_op_2(?MODULE,Op,A,Bb) end;
        {false,BBind} ->    fun(X) -> Bb=?BoundVal(BBind,X),mod_op_2(?MODULE,Op,A,Bb) end;
        {true,false} ->     fun(X) -> Ab=A(X),mod_op_2(?MODULE,Op,Ab,B) end;
        {true,true} ->      fun(X) -> Ab=A(X),Bb=B(X),mod_op_2(?MODULE,Op,Ab,Bb) end;
        {true,BBind} ->     fun(X) -> Ab=A(X),Bb=?BoundVal(BBind,X),mod_op_2(?MODULE,Op,Ab,Bb) end;
        {ABind,false} ->    fun(X) -> Ab=?BoundVal(ABind,X),mod_op_2(?MODULE,Op,Ab,B) end;
        {ABind,true} ->     fun(X) -> Ab=?BoundVal(ABind,X),Bb=B(X),mod_op_2(?MODULE,Op,Ab,Bb) end;
        {ABind,BBind} ->    fun(X) -> Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),mod_op_2(?MODULE,Op,Ab,Bb) end
    end;
binary_fun_final({Op, A, B}) when Op==nvl_atom;Op==nvl_binary;Op==nvl_binstr;Op==nvl_float;Op==nvl_integer;Op==nvl_json;Op==nvl_term;Op==nvl_tuple;Op==cmp;Op==diff;Op==diff_only;Op==split ->
    case {bind_action(A),bind_action(B)} of 
        {false,false} ->    mod_op_2(?MODULE,Op,A,B);        
        {false,true} ->     fun(X) -> Bb=B(X),mod_op_2(?MODULE,Op,A,Bb) end;
        {false,BBind} ->    fun(X) -> Bb=?BoundVal(BBind,X),mod_op_2(?MODULE,Op,A,Bb) end;
        {true,false} ->     fun(X) -> Ab=A(X),mod_op_2(?MODULE,Op,Ab,B) end;
        {true,true} ->      fun(X) -> Ab=A(X),Bb=B(X),mod_op_2(?MODULE,Op,Ab,Bb) end;
        {true,BBind} ->     fun(X) -> Ab=A(X),Bb=?BoundVal(BBind,X),mod_op_2(?MODULE,Op,Ab,Bb) end;
        {ABind,false} ->    fun(X) -> Ab=?BoundVal(ABind,X),mod_op_2(?MODULE,Op,Ab,B) end;
        {ABind,true} ->     fun(X) -> Ab=?BoundVal(ABind,X),Bb=B(X),mod_op_2(?MODULE,Op,Ab,Bb) end;
        {ABind,BBind} ->    fun(X) -> Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),mod_op_2(?MODULE,Op,Ab,Bb) end
    end;
binary_fun_final(BTree) ->
    ?UnimplementedException({"Unsupported filter function",{BTree}}).

-spec add_dt(ddDatetime(), number()) -> ddDatetime(). 
add_dt(DT, Offset) when is_tuple(DT),is_number(Offset) -> imem_datatype:offset_datetime('+', DT, Offset).   %% Offset by (fractions of) days

-spec diff_dt(ddDatetime(), ddDatetime()) -> float(). 
diff_dt(A, B) when is_tuple(A), is_tuple(B) -> imem_datatype:datetime_diff(B, A).                           %% Difference in (fractions of) days

-spec add_ts(ddTimeUID() | ddTimestamp() | {integer(), integer(), integer()}, number()) -> ddTimestamp(). 
add_ts(TS, Offset) when is_tuple(TS),is_number(Offset) ->  imem_datatype:offset_timestamp('+', TS, Offset). %% Offset by (fractions of) days

-spec diff_ts(ddTimeUID() | ddTimestamp() | {integer(), integer(), integer()}, ddTimeUID() | ddTimestamp() | {integer(), integer(), integer()}) -> float(). 
diff_ts(TS1, TS2) ->      imem_datatype:usec_diff(TS1, TS2)/86400000000.0.                                  %% Difference in (fractions of) days

concat(A, B) when is_list(A),is_list(B) -> A ++ B;
concat(A, B) when is_map(A),is_map(B) -> maps:merge(A,B);
concat(A, B) when is_binary(A),is_binary(B) -> <<A/binary,B/binary>>.

trunc(A) when is_number(A) -> trunc(A,0);
trunc(A) when is_tuple(A) -> trunc(A,86400);
trunc(_) -> ?nav.

trunc(A,0) when is_float(A) -> erlang:trunc(A);
trunc(A,N) when is_float(A),is_integer(N), N>0 ->
    P = math:pow(10, N),
    erlang:trunc(A * P) / P;
trunc(A,N) when is_float(A),is_integer(N) ->
    P = math:pow(10, N),
    erlang:trunc(erlang:trunc(A * P) / P);
trunc(A,0) when is_integer(A) -> A;
trunc(A,N) when is_integer(A),is_integer(N) -> trunc(A+0.0,N);
trunc({Sec,Micro},0) when is_integer(Sec),is_integer(Micro) -> {Sec,0};
trunc({Sec,Micro},N) when is_integer(Sec),is_integer(Micro),is_integer(N),N>0 -> {erlang:trunc(Sec / N) * N,0};
trunc({Sec,Micro,Node,I},0) when is_integer(Sec),is_integer(Micro) -> {Sec,0,Node,I};
trunc({Sec,Micro,Node,I},N) when is_integer(Sec),is_integer(Micro),is_integer(N),N>0 -> {erlang:trunc(Sec / N) * N,0,Node,I};
trunc({{Y,M,D},{_,_,_}},0) when is_integer(Y),is_integer(M),is_integer(D) -> {{Y,M,D},{0,0,0}};
trunc(_,_) -> ?nav.

round(A) -> round(A,0).

round(A,0) when is_float(A) -> erlang:round(A);
round(A,N) when is_float(A),is_integer(N), N>0 ->
    P = math:pow(10, N),
    erlang:round(A * P) / P;
round(A,N) when is_float(A),is_integer(N) ->
    P = math:pow(10, N),
    erlang:round(erlang:round(A * P) / P);
round(A,0) when is_integer(A) -> A;
round(A,N) when is_integer(A),is_integer(N) -> round(A+0.0,N);
round(_,_) -> ?nav.

is_key(K, M) when is_map(M) -> maps:is_key(K,M);
is_key(K, L) when is_list(L) ->
    case lists:keyfind(K, 1, L) of
        {_, _} ->   true;
        false ->    false
    end;
is_key(_, _) -> ?nav.

json_arr_proj(A, [B]) ->    % reduce result to element
    L = json_to_list(A),
    safe_nth(B,L);
json_arr_proj(A, B) when is_list(B) ->
    L = json_to_list(A),
    [safe_nth(I,L) || I <- B];
json_arr_proj(A, B) ->
    L = json_to_list(A),
    case json_to_list(B) of
        [One] ->    safe_nth(One,L);
        F ->        [safe_nth(I,L) || I <- F]
    end.

safe_nth(I,A) ->
    L=length(A),
    if 
        I < 1 ->    ?nav;
        I > L ->    ?nav;
        true ->     lists:nth(I,A)
    end.

json_obj_proj(A, B) when is_list(B) ->      % filter json object A with names in B
    L = json_to_list(A),
    [safe_property(Name,L) || Name <- B];
json_obj_proj(A, B) ->
    L = json_to_list(A),
    F = json_to_list(B),
    [safe_property(Name,L) || Name <- F].

safe_property(Name,A) ->
    case lists:keyfind(Name, 1, A) of
        {_, Value} ->   {Name,Value};
        _ ->            {Name,?nav}
    end.

json_value(A, B) when is_binary(A),is_binary(B) ->
    json_value(A, json_to_list(B));
json_value(_, [])  ->   ?nav;
json_value(A, [{_,_}|_]=B) when is_binary(A) ->     % pick value of attribute A in json object B
    safe_value(A,B);
json_value(A, B) when is_binary(A),is_map(B) ->     % pick value of attribute A in json object B
    safe_value(A,B);
json_value(A, [[{_,_}|_]]=[B]) when is_binary(A) -> % pick value of attribute A in array with one object B
    safe_value(A,B);
json_value(A, [B]) when is_binary(A),is_map(B) ->   % pick value of attribute A in array with one object B
    safe_value(A,B);
json_value(A, [[{_,_}|_]|_]=L) when is_binary(A) -> % pick value of attribute A in array of objects L
    [safe_value(A,B) || B <- L];
json_value(A, [#{}|_]=L) when is_binary(A) ->       % pick value of attribute A in array of objects L
    [safe_value(A,B) || B <- L];
json_value(_Name, _PL)  ->    
    % ?Info("JSON attribute ~p not found in ~p",[_Name,_PL]),
    ?nav.

json_diff(A, B) -> imem_json:diff(A, B).

safe_value(Name,M) when is_map(M) -> 
    case maps:find(Name, M) of
        {ok, Value} ->  Value;
        _ ->            ?nav
    end;
safe_value(Name,PL) ->
    case lists:keyfind(Name, 1, PL) of
        {_, Value} ->   Value;
        _ ->            
            % ?Info("Unsafe JSON attribute ~p in ~p",[Name,PL]),
            ?nav
    end.

from_decimal(I,0) when is_integer(I) -> I; 
from_decimal(I,P) when is_integer(I),is_integer(P),(P>0) -> 
    Str = integer_to_list(I),
    Len = length(Str),
    if 
        P-Len+1 > 0 -> 
            {Whole,Frac} = lists:split(1,lists:duplicate(P-Len+1,$0) ++ Str),
            to_float(io_lib:format("~s.~s",[Whole,Frac]));
        true ->
            {Whole,Frac} = lists:split(Len-P,Str),
            to_float(io_lib:format("~s.~s",[Whole,Frac]))
    end;
from_decimal(I,P) -> ?ClientError({"Invalid conversion from_decimal",{I,P}}).

is_member(A, B) when is_list(B) ->     lists:member(A,B);
is_member(A, B) when is_tuple(B) ->    lists:member(A,tuple_to_list(B));
is_member(A, B) when is_map(B) ->      lists:member(A,maps:to_list(B));
is_member(_, _) ->                     false.

cmp(A, B) -> imem_cmp:cmp(A, B).

cmp(A, B, Opts) -> imem_cmp:cmp(A, B, Opts).

diff(A, B) -> imem_tdiff:diff(A, B).

diff(A, B, Opts) -> imem_tdiff:diff(A, B, Opts).

diff_only(A, B) -> imem_tdiff:diff_only(A, B).

diff_only(A, B, Opts) -> imem_tdiff:diff_only(A, B, Opts).

ternary_not(?nav) ->        ?nav;
ternary_not(true) ->        false;
ternary_not(false) ->       true.

ternary_and(?nav,_)->       ?nav;
ternary_and(_,?nav)->       ?nav;
ternary_and(A,B)->          (A and B).

ternary_or(_,true) ->       true;
ternary_or(true,_) ->       true;
ternary_or(A,?nav) ->       A;
ternary_or(?nav,B) ->       B;
ternary_or(A,false) ->      A;
ternary_or(false,B) ->      B;
ternary_or(A,B) ->          (A or B).

to_decimal(B,0) -> erlang:round(to_number(B));
to_decimal(B,P) when is_integer(P),(P>0) ->
    erlang:round(math:pow(10, P) * to_number(B)).

ternary_fun({Op, {const,A}, B, C}) when is_tuple(A) ->
    ternary_fun({Op, A, B, C});
ternary_fun({Op, A, {const,B}, C}) when is_tuple(B) ->
    ternary_fun({Op, A, B, C});
ternary_fun({Op, A, B, {const,C}}) when is_tuple(C) ->
    ternary_fun({Op, A, B, C});
ternary_fun({Op, A, B, C}) ->
    FA = expr_fun(A),
    FB = expr_fun(B),
    FC = expr_fun(C),
    % ?Info("FA ~p FB ~p FC ~p",[FA,FB,FC]),
    ternary_fun_final( {Op, FA, FB, FC});
ternary_fun(Value) -> Value.

ternary_fun_final({'mfa', Mod, Func, Args}) when is_atom(Mod),is_atom(Func) ->
    % ?LogDebug("Permission query ~p ~p ~p ~p",[Mod, Func, Args,?IMEM_SKEY_GET]),
    case imem_sec:have_permission(?IMEM_SKEY_GET,{eval_mfa,Mod,Func}) of
        true ->     ok;   
        false ->    ?SecurityException({"Function evaluation unauthorized",{Mod,Func,?IMEM_SKEY_GET,self()}})
    end,
    case bind_action(Args) of 
        false ->  apply(Mod,Func,Args);        
        true ->   fun(X) -> Cb=Args(X),apply(Mod,Func,Cb) end;        
        CBind ->  fun(X) -> Cb=?BoundVal(CBind,X),apply(Mod,Func,Cb) end
    end;
ternary_fun_final({Op, A, B, C}) when Op=='remap';Op=='mfa';Op=='slice';Op=='preview';Op=='preview_keys';Op=='bits';Op=='bytes';Op==cmp;Op==diff;Op==diff_only ->
    case {bind_action(A),bind_action(B),bind_action(C)} of 
        {false,false,false} ->  mod_op_3(?MODULE,Op,A,B,C);        
        {false,true,false} ->   fun(X) -> Bb=B(X),mod_op_3(?MODULE,Op,A,Bb,C) end;
        {false,BBind,false} ->  fun(X) -> Bb=?BoundVal(BBind,X),mod_op_3(?MODULE,Op,A,Bb,C) end;
        {true,false,false} ->   fun(X) -> Ab=A(X),mod_op_3(?MODULE,Op,Ab,B,C) end;
        {true,true,false} ->    fun(X) -> Ab=A(X),Bb=B(X),mod_op_3(?MODULE,Op,Ab,Bb,C) end;
        {true,BBind,false} ->   fun(X) -> Ab=A(X),Bb=?BoundVal(BBind,X),mod_op_3(?MODULE,Op,Ab,Bb,C) end;
        {ABind,false,false} ->  fun(X) -> Ab=?BoundVal(ABind,X),mod_op_3(?MODULE,Op,Ab,B,C) end;
        {ABind,true,false} ->   fun(X) -> Ab=?BoundVal(ABind,X),Bb=B(X),mod_op_3(?MODULE,Op,Ab,Bb,C) end;
        {ABind,BBind,false} ->  fun(X) -> Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),mod_op_3(?MODULE,Op,Ab,Bb,C) end;

        {false,false,true} ->   fun(X) -> Cb=C(X),mod_op_3(?MODULE,Op,A,B,Cb) end;        
        {false,true,true} ->    fun(X) -> Cb=C(X),Bb=B(X),mod_op_3(?MODULE,Op,A,Bb,Cb) end;
        {false,BBind,true} ->   fun(X) -> Cb=C(X),Bb=?BoundVal(BBind,X),mod_op_3(?MODULE,Op,A,Bb,Cb) end;
        {true,false,true} ->    fun(X) -> Cb=C(X),Ab=A(X),mod_op_3(?MODULE,Op,Ab,B,Cb) end;
        {true,true,true} ->     fun(X) -> Cb=C(X),Ab=A(X),Bb=B(X),mod_op_3(?MODULE,Op,Ab,Bb,Cb) end;
        {true,BBind,true} ->    fun(X) -> Cb=C(X),Ab=A(X),Bb=?BoundVal(BBind,X),mod_op_3(?MODULE,Op,Ab,Bb,Cb) end;
        {ABind,false,true} ->   fun(X) -> Cb=C(X),Ab=?BoundVal(ABind,X),mod_op_3(?MODULE,Op,Ab,B,Cb) end;
        {ABind,true,true} ->    fun(X) -> Cb=C(X),Ab=?BoundVal(ABind,X),Bb=B(X),mod_op_3(?MODULE,Op,Ab,Bb,Cb) end;
        {ABind,BBind,true} ->   fun(X) -> Cb=C(X),Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),mod_op_3(?MODULE,Op,Ab,Bb,Cb) end;

        {false,false,CBind} ->  fun(X) -> Cb=?BoundVal(CBind,X),mod_op_3(?MODULE,Op,A,B,Cb) end;        
        {false,true,CBind} ->   fun(X) -> Cb=?BoundVal(CBind,X),Bb=B(X),mod_op_3(?MODULE,Op,A,Bb,Cb) end;
        {false,BBind,CBind} ->  fun(X) -> Cb=?BoundVal(CBind,X),Bb=?BoundVal(BBind,X),mod_op_3(?MODULE,Op,A,Bb,Cb) end;
        {true,false,CBind} ->   fun(X) -> Cb=?BoundVal(CBind,X),Ab=A(X),mod_op_3(?MODULE,Op,Ab,B,Cb) end;
        {true,true,CBind} ->    fun(X) -> Cb=?BoundVal(CBind,X),Ab=A(X),Bb=B(X),mod_op_3(?MODULE,Op,Ab,Bb,Cb) end;
        {true,BBind,CBind} ->   fun(X) -> Cb=?BoundVal(CBind,X),Ab=A(X),Bb=?BoundVal(BBind,X),mod_op_3(?MODULE,Op,Ab,Bb,Cb) end;
        {ABind,false,CBind} ->  fun(X) -> Cb=?BoundVal(CBind,X),Ab=?BoundVal(ABind,X),mod_op_3(?MODULE,Op,Ab,B,Cb) end;
        {ABind,true,CBind} ->   fun(X) -> Cb=?BoundVal(CBind,X),Ab=?BoundVal(ABind,X),Bb=B(X),mod_op_3(?MODULE,Op,Ab,Bb,Cb) end;
        {ABind,BBind,CBind} ->  fun(X) -> Cb=?BoundVal(CBind,X),Ab=?BoundVal(ABind,X),Bb=?BoundVal(BBind,X),mod_op_3(?MODULE,Op,Ab,Bb,Cb) end
    end;
ternary_fun_final(BTree) ->
    ?UnimplementedException({"Unsupported filter function",BTree}).

remap(Val,From,To) ->
    if 
        Val == From ->  To;
        true ->         Val
    end.

preview(IndexTable, Options, SearchTerm) -> imem_index:preview(IndexTable, Options, SearchTerm).

preview_keys(IndexTable, Options, SearchTerm) -> imem_index:preview_keys(IndexTable, Options, SearchTerm).

slice(<<>>,_) -> <<>>;
slice(B,Start) when is_binary(B) -> 
    unicode:characters_to_binary(slice(unicode:characters_to_list(B, utf8),Start));
slice([],_) -> [];
slice(L,Start) when is_list(L),Start==1 -> L;
slice(L,Start) when is_list(L),Start > 0 -> lists:nthtail(Start-1, L);
slice(L,Start) when is_list(L) -> 
    if 
        length(L)+Start >= 0 ->
            lists:nthtail(length(L)+Start, L);
        true ->
            L
    end;
slice(A,Start) when is_atom(A) -> slice(atom_to_list(A),Start);
slice(I,Start) when is_integer(I) -> slice(integer_to_list(I),Start);
slice(F,Start) when is_float(F) -> slice(float_to_list(F),Start).

slice(<<>>,_,_) -> <<>>;
slice(B,Start,Len) when is_binary(B) -> 
    unicode:characters_to_binary(slice(unicode:characters_to_list(B, utf8),Start,Len));
slice([],_,_) -> [];
slice(L,_,Len) when is_list(L), Len < 1 -> [];
slice(L,Start,Len) when is_list(L), Start > 0 -> lists:sublist(L, Start, Len);
slice(L,Start,Len) when is_list(L) -> 
    if
        length(L)+Start >= 0 ->
            lists:sublist(L, length(L)+Start+1, Len);
        true ->
            lists:sublist(L, Len)
    end;
slice(A,Start,Len) when is_atom(A) -> slice(atom_to_list(A),Start,Len);
slice(I,Start,Len) when is_integer(I) -> slice(integer_to_list(I),Start,Len);
slice(F,Start,Len) when is_float(F) -> slice(float_to_list(F),Start,Len).

bits(<<>>,_) -> <<>>;
bits(B,_) when is_bitstring(B)==false -> ?nav;
bits(B,Start) when Start+bit_size(B)<0 -> 
    <<Result/bitstring>> =B,
    Result;
bits(B,Start) when Start>=bit_size(B) -> ?nav;
bits(B,Start) when Start>=0 -> 
    <<_:Start,Rest/bitstring>> = B,
    Rest;
bits(B,Start) ->
    PrefixSize = bit_size(B)+Start,
    <<_:PrefixSize,Rest/bitstring>> = B,
    Rest.

bits(B,_,_) when is_bitstring(B)==false -> ?nav;
bits(_,_,Len) when Len<0 -> ?nav;
bits(B,Start,Len) when Start<0 -> bits_pos(B,bit_size(B)+Start,Len);
bits(B,Start,Len) -> bits_pos(B,Start,Len).

bits_pos(_,Start,_) when Start<0 -> ?nav;
bits_pos(B,Start,Len) when Start+Len>bit_size(B) -> ?nav;
bits_pos(_,_,0) -> ?nav;
bits_pos(B,Start,Len) ->     
    <<_:Start,Result:Len,_/bitstring>> = B,
    Result.

bytes(<<>>,_) -> <<>>;
bytes(B,_) when is_binary(B)==false -> ?nav;
bytes(B,Start) when Start+size(B)<0 -> B;
bytes(B,Start) when Start>=size(B) -> <<>>;
bytes(B,Start) when Start>=0 -> binary:part(B,Start,size(B)-Start);
bytes(B,Start) -> binary:part(B,size(B),Start).

bytes(B,_,_) when is_binary(B)==false -> ?nav;
bytes(_,_,Len) when Len<0 -> ?nav;
bytes(B,Start,Len) when Start<0 -> bytes_pos(B,size(B)+Start,Len);
bytes(B,Start,Len) -> bytes_pos(B,Start,Len).

bytes_pos(_,Start,_) when Start<0 -> ?nav;
bytes_pos(B,Start,Len) when Start+Len>size(B) -> ?nav;
bytes_pos(_,_,0) -> <<>>;
bytes_pos(B,Start,Len) -> binary:part(B,Start,Len).

mfa(Mod,Func,Args) ->
    SKey = imem_sec:have_permission(?IMEM_SKEY_GET_FUN(),{eval_mfa,Mod,Func}),
    case SKey of
        true ->     apply(Mod,Func,Args);   
        false ->    ?SecurityException({"Function evaluation unauthorized",{Mod,Func,SKey,self()}})
    end.


%% TESTS ------------------------------------------------------------------
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

slice_test_() ->
    B = <<"1234567890">>,
    L = "1234567890",
    { inparallel
    , [{"l11", ?_assertEqual("1",slice(L,1,1))}
      ,{"l12", ?_assertEqual("12",slice(L,1,2))}
      ,{"l13", ?_assertEqual("1234567890",slice(L,1,10))}
      ,{"l14", ?_assertEqual("1234567890",slice(L,1,20))}
      ,{"l54", ?_assertEqual("5",slice(L,5,1))}
      ,{"l55", ?_assertEqual("567890",slice(L,5,6))}
      ,{"l56", ?_assertEqual("567890",slice(L,5,7))}
      ,{"l81", ?_assertEqual("890",slice(L,-3,3))}
      ,{"l18", ?_assertEqual("1234567890",slice(L,-10,10))}
      ,{"l57", ?_assertEqual("567890",slice(L,5))}
      ,{"l90", ?_assertEqual("90",slice(L,-2))}
      ,{"l50", ?_assertEqual("567890",slice(L,-6))}
      ,{"l-1", ?_assertEqual("1234567890",slice(L,-11))}
      ,{"l-3", ?_assertEqual("123",slice(L,-11,3))}
      ,{"b11", ?_assertEqual(<<"1">>,slice(B,1,1))}
      ,{"b12", ?_assertEqual(<<"12">>,slice(B,1,2))}
      ,{"b13", ?_assertEqual(<<"1234567890">>,slice(B,1,10))}
      ,{"b14", ?_assertEqual(<<"1234567890">>,slice(B,1,20))}
      ,{"b54", ?_assertEqual(<<"5">>,slice(B,5,1))}
      ,{"b55", ?_assertEqual(<<"567890">>,slice(B,5,6))}
      ,{"b56", ?_assertEqual(<<"567890">>,slice(B,5,7))}
      ,{"b81", ?_assertEqual(<<"890">>,slice(B,-3,3))}
      ,{"b08", ?_assertEqual(<<"1234567890">>,slice(B,-10,10))}
      ]
    }.

-endif.

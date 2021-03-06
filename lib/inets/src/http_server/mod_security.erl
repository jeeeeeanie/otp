%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1998-2010. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%
%%
-module(mod_security).

%% Security Audit Functionality

%% User API exports
-export([list_blocked_users/1, list_blocked_users/2, list_blocked_users/3, 
	 block_user/4, block_user/5, 
	 unblock_user/2, unblock_user/3, unblock_user/4,
	 list_auth_users/1, list_auth_users/2, list_auth_users/3]).

%% module API exports
-export([do/1, load/2, store/2, remove/1]).

-include("httpd.hrl").
-include("httpd_internal.hrl").
-include("inets_internal.hrl").

-define(VMODULE,"SEC").


%% do/1
do(Info) ->
    ?hdrt("do", [{info, Info}]),
    %% Check and see if any user has been authorized.
    case proplists:get_value(remote_user, Info#mod.data,not_defined_user) of
	not_defined_user ->
	    %% No user has been authorized.
	    case proplists:get_value(response, Info#mod.data) of
		%% A status code has been generated!
		{401, _Response} ->
		    case proplists:get_value("authorization",
					     Info#mod.parsed_header) of
			undefined ->
			    %% Not an authorization attempt (server
			    %% just replied to challenge for
			    %% authentication)
			    {proceed, Info#mod.data};
			[$B,$a,$s,$i,$c,$ |EncodedString] ->
			    %% Someone tried to authenticate, and
			    %% obviously failed!
			    DecodedString =  
				case (catch 
					  base64:decode_to_string(
					    EncodedString)) of
				    %% Decode failed 
				    {'EXIT',{function_clause, _}} ->
					EncodedString;
				    String ->
					String
				end,
				 
			    report_failed(Info, DecodedString,
					  "Failed authentication"),
			    take_failed_action(Info, DecodedString),
			    {proceed, Info#mod.data}
		    end;
		_ ->
		    {proceed, Info#mod.data}
	    end;
	User ->
	    %% A user has been authenticated, now is he blocked ?
	    Path = mod_alias:path(Info#mod.data,
				  Info#mod.config_db,
				  Info#mod.request_uri),
	    {_Dir, SDirData} = secretp(Path, Info#mod.config_db),
	    Addr = httpd_util:lookup(Info#mod.config_db, bind_address),
	    Port = httpd_util:lookup(Info#mod.config_db, port),
	    case mod_security_server:check_blocked_user(Info, User, 
							SDirData, 
							Addr, Port) of
		true ->
		    report_failed(Info, User ,"User Blocked"),
		    {proceed, [{status, {403, Info#mod.request_uri, ""}} |
			       Info#mod.data]};
		false ->
		    report_failed(Info, User,"Authentication Succedded"),
		    mod_security_server:store_successful_auth(Addr, Port, 
							      User, 
							      SDirData),
		    {proceed, Info#mod.data}
	    end
    end.

report_failed(Info, Auth, Event) ->
    Request = Info#mod.request_line,
    {_PortNumber,RemoteHost}=(Info#mod.init_data)#init_data.peername,
    String = RemoteHost ++ " : " ++ Event ++ " : " ++ Request ++ 
	" : " ++ Auth,
    mod_disk_log:security_log(Info,String),
    mod_log:security_log(Info, String).

take_failed_action(Info, Auth) ->
    ?hdrd("take failed action", [{auth, Auth}]),
    Path = mod_alias:path(Info#mod.data, Info#mod.config_db, 
			  Info#mod.request_uri),
    {_Dir, SDirData} = secretp(Path, Info#mod.config_db),
    Addr = httpd_util:lookup(Info#mod.config_db, bind_address),
    Port = httpd_util:lookup(Info#mod.config_db, port),
    mod_security_server:store_failed_auth(Info, Addr, Port, 
					  Auth, SDirData).

secretp(Path, ConfigDB) ->
    Directories = ets:match(ConfigDB,{directory,{'$1','_'}}),
    case secret_path(Path, Directories) of
	{yes, Directory} ->
	    ?hdrd("secretp - yes", [{dir, Directory}]),
	    SDirs0 = httpd_util:multi_lookup(ConfigDB, security_directory),
	    [SDir] = lists:filter(fun({Directory0, _}) 
				     when Directory0 == Directory ->
					  true;
				     (_) ->
					  false
				  end, SDirs0),
	    SDir;
	no ->
	    {[], []}
    end.

secret_path(Path,Directories) ->
    secret_path(Path, httpd_util:uniq(lists:sort(Directories)), to_be_found).

secret_path(_Path, [], to_be_found) ->
    no;
secret_path(_Path, [], Dir) ->
    {yes, Dir};
secret_path(Path, [[NewDir]|Rest], Dir) ->
    case inets_regexp:match(Path, NewDir) of
	{match, _, _} when Dir =:= to_be_found ->
	    secret_path(Path, Rest, NewDir);
	{match, _, Length} when Length > length(Dir) ->
	    secret_path(Path, Rest, NewDir);
	{match, _, _} ->
	    secret_path(Path, Rest, Dir);
	nomatch ->
	    secret_path(Path, Rest, Dir)
    end.


load("<Directory " ++ Directory, []) ->
    ?hdrt("load security directory - begin", [{directory, Directory}]),
    Dir = httpd_conf:custom_clean(Directory,"",">"),
    {ok, [{security_directory, {Dir, [{path, Dir}]}}]};
load(eof,[{security_directory, {Directory, _DirData}}|_]) ->
    {error, ?NICE("Premature end-of-file in "++Directory)};
load("SecurityDataFile " ++ FileName, 
     [{security_directory, {Dir, DirData}}]) ->
    ?hdrt("load security directory", 
	  [{file, FileName}, {dir, Dir}, {dir_data, DirData}]),
    File = httpd_conf:clean(FileName),
    {ok, [{security_directory, {Dir, [{data_file, File}|DirData]}}]};
load("SecurityCallbackModule " ++ ModuleName,
     [{security_directory, {Dir, DirData}}]) ->
    ?hdrt("load security directory", 
	  [{module, ModuleName}, {dir, Dir}, {dir_data, DirData}]),
    Mod = list_to_atom(httpd_conf:clean(ModuleName)),
    {ok, [{security_directory, {Dir, [{callback_module, Mod}|DirData]}}]};
load("SecurityMaxRetries " ++ Retries,
     [{security_directory, {Dir, DirData}}]) ->
    ?hdrt("load security directory", 
	  [{max_retries, Retries}, {dir, Dir}, {dir_data, DirData}]),
    load_return_int_tag("SecurityMaxRetries", max_retries, 
			httpd_conf:clean(Retries), Dir, DirData);
load("SecurityBlockTime " ++ Time,
      [{security_directory, {Dir, DirData}}]) ->
    ?hdrt("load security directory", 
	  [{block_time, Time}, {dir, Dir}, {dir_data, DirData}]),
    load_return_int_tag("SecurityBlockTime", block_time,
			httpd_conf:clean(Time), Dir, DirData);
load("SecurityFailExpireTime " ++ Time,
     [{security_directory, {Dir, DirData}}]) ->
    ?hdrt("load security directory", 
	  [{expire_time, Time}, {dir, Dir}, {dir_data, DirData}]),
    load_return_int_tag("SecurityFailExpireTime", fail_expire_time,
			httpd_conf:clean(Time), Dir, DirData);
load("SecurityAuthTimeout " ++ Time0,
     [{security_directory, {Dir, DirData}}]) ->
    ?hdrt("load security directory", 
	  [{auth_timeout, Time0}, {dir, Dir}, {dir_data, DirData}]),
    Time = httpd_conf:clean(Time0),
    load_return_int_tag("SecurityAuthTimeout", auth_timeout,
			httpd_conf:clean(Time), Dir, DirData);
load("AuthName " ++ Name0,
     [{security_directory, {Dir, DirData}}]) ->
    ?hdrt("load security directory", 
	  [{name, Name0}, {dir, Dir}, {dir_data, DirData}]),
    Name = httpd_conf:clean(Name0),
    {ok, [{security_directory, {Dir, [{auth_name, Name}|DirData]}}]};
load("</Directory>",[{security_directory, {Dir, DirData}}]) ->
    ?hdrt("load security directory - end", 
	  [{dir, Dir}, {dir_data, DirData}]),
    {ok, [], {security_directory, {Dir, DirData}}}.

load_return_int_tag(Name, Atom, Time, Dir, DirData) ->
    case Time of
	"infinity" ->
	    {ok, [{security_directory, {Dir, 
		   [{Atom, 99999999999999999999999999999} | DirData]}}]};
	_Int ->
	    case catch list_to_integer(Time) of
		{'EXIT', _} ->
		    {error, Time++" is an invalid "++Name};
		Val ->
		    {ok, [{security_directory, {Dir, [{Atom, Val}|DirData]}}]}
	    end
    end.

store({security_directory, {Dir, DirData}}, ConfigList) 
  when is_list(Dir) andalso is_list(DirData) ->
    ?hdrt("store security directory", [{dir, Dir}, {dir_data, DirData}]),
    Addr = proplists:get_value(bind_address, ConfigList),
    Port = proplists:get_value(port, ConfigList),
    mod_security_server:start(Addr, Port),
    SR = proplists:get_value(server_root, ConfigList),
    case proplists:get_value(data_file, DirData, no_data_file) of
	no_data_file ->
	    {error, {missing_security_data_file, {security_directory, {Dir, DirData}}}};
	DataFile0 ->
	    DataFile = 
		case filename:pathtype(DataFile0) of
		    relative ->
			filename:join(SR, DataFile0);
		    _ ->
			DataFile0
		end,
	    case mod_security_server:new_table(Addr, Port, DataFile) of
		{ok, TwoTables} ->
		    NewDirData0 = lists:keyreplace(data_file, 1, DirData, 
						   {data_file, TwoTables}),
		    NewDirData1 = case Addr of
				      undefined ->
					  [{port,Port}|NewDirData0];
				      _ ->
					  [{port,Port},{bind_address,Addr}|
					   NewDirData0]
				  end,
		    {ok, {security_directory, {Dir, NewDirData1}}};
		{error, Err} ->
		    {error, {{open_data_file, DataFile}, Err}}
	    end
    end;
store({directory, {Directory, DirData}}, _) ->
    {error, {wrong_type, {security_directory, {Directory, DirData}}}}.

remove(ConfigDB) ->
    Addr = case ets:lookup(ConfigDB, bind_address) of
	       [] -> 
		   undefined;
	       [{bind_address, Address}] ->
		   Address
	   end,
    [{port, Port}] = ets:lookup(ConfigDB, port),
    mod_security_server:delete_tables(Addr, Port),
    mod_security_server:stop(Addr, Port).
    

%%
%% User API
%%

%% list_blocked_users

list_blocked_users(Port) ->
    list_blocked_users(undefined, Port).

list_blocked_users(Port, Dir) when is_integer(Port) ->
    list_blocked_users(undefined,Port,Dir);
list_blocked_users(Addr, Port) when is_integer(Port) ->
    mod_security_server:list_blocked_users(Addr, Port).

list_blocked_users(Addr, Port, Dir) ->
    mod_security_server:list_blocked_users(Addr, Port, Dir).


%% block_user

block_user(User, Port, Dir, Time) ->
    block_user(User, undefined, Port, Dir, Time).
block_user(User, Addr, Port, Dir, Time) ->
    mod_security_server:block_user(User, Addr, Port, Dir, Time).


%% unblock_user

unblock_user(User, Port) ->
    unblock_user(User, undefined, Port).

unblock_user(User, Port, Dir) when is_integer(Port) ->
    unblock_user(User, undefined, Port, Dir);
unblock_user(User, Addr, Port) when is_integer(Port) ->
    mod_security_server:unblock_user(User, Addr, Port).

unblock_user(User, Addr, Port, Dir) ->
    mod_security_server:unblock_user(User, Addr, Port, Dir).


%% list_auth_users

list_auth_users(Port) ->
    list_auth_users(undefined,Port).

list_auth_users(Port, Dir) when is_integer(Port) ->
    list_auth_users(undefined, Port, Dir);
list_auth_users(Addr, Port) when is_integer(Port) ->
    mod_security_server:list_auth_users(Addr, Port).

list_auth_users(Addr, Port, Dir) ->
    mod_security_server:list_auth_users(Addr, Port, Dir).

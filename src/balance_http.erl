%%% -------------------------------------------------------------------
%%% Author  : skruger
%%% Description :
%%%
%%% Created : Nov 18, 2010
%%% -------------------------------------------------------------------
-module(balance_http).

-behaviour(gen_fsm).
%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------

-include("surrogate.hrl").

%% --------------------------------------------------------------------
%% External exports
-export([listen_master/2,accept_http/2,http_balance/2,accept_https/2,start_link/1]).

%% gen_fsm callbacks
-export([init/1,  handle_event/3,
	 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

%% -record(state, {}).

-record(socket_state,{type,listener,num_listeners,listeners,listen_port,proplist}).

-record(worker_state,{type,client_sock,listen_port,proplist,parent_pid}).

%% ====================================================================
%% External functions
%% ====================================================================

start_link(Args) ->
	gen_fsm:start_link(?MODULE,Args,[{debug,[log]}]).


%% ====================================================================
%% Server functions
%% ====================================================================
%% --------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%% --------------------------------------------------------------------
init({balance_http,Bind,Port,Props}=L) ->
	?INFO_MSG("~p HTTP listening: ~p~n",[?MODULE,L]),
	case gen_tcp:listen(Port,[Bind,inet,binary,{active,false},{reuseaddr,true}]) of
		{ok,Listen} ->
			gen_fsm:send_event(self(),check_listeners),
			{ok, listen_master, #socket_state{type=http,listener=Listen,num_listeners=1,listeners=[],listen_port=Port,proplist=Props}};
		Err ->
			?ERROR_MSG("~p could not start with args ~p~nError: ~p~n",[?MODULE,L,Err]),
			{stop,error}
	end;
init({http,Listen,Port,Props,Parent}=_L) ->
%% 	io:format("Got worker: ~p~n",[L]),
	gen_fsm:send_event(self(),wait),
	{ok,accept_http,#worker_state{type=http,client_sock=Listen,listen_port=Port,proplist=Props,parent_pid=Parent}};
init({balance_https,Bind,Port,KeyFile,CertFile,Props}=L)->
	?INFO_MSG("~p HTTPS listening: ~p~n",[?MODULE,L]),
	%Opts = [{certfile,CertFile},{keyfile,KeyFile},Bind,inet,binary,{active,true},{reuseaddr,true}],
	Opts = [{certfile,CertFile},{keyfile,KeyFile},Bind,binary,{active,false},{reuseaddr,true}],
	case ssl:listen(Port,Opts) of
		{ok,Listen} ->
			gen_fsm:send_event(self(),check_listeners),
			{ok,listen_master,#socket_state{type=https,listener=Listen,num_listeners=1,listeners=[],listen_port=Port,proplist=Props}};
		Err ->
			?ERROR_MSG("~p could not start ssl listener with args ~p~nOptions: ~p~nError: ~p~n",[?MODULE,L,Opts,Err]),
			{stop,error}
	end;
init({https,Listen,Port,Props,Parent}=_L) ->
%% 	io:format("Got worker: ~p~n",[L]),
	gen_fsm:send_event(self(),{wait,Listen}),
	{ok,accept_https,#worker_state{type=https,listen_port=Port,proplist=Props,parent_pid=Parent}}.


%% --------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% --------------------------------------------------------------------
listen_master(check_listeners,State)->
	case lists:flatlength(State#socket_state.listeners) of
		Num when Num < State#socket_state.num_listeners ->
			gen_fsm:send_event(self(),startchild);
		_ ->
			true
	end,
	{next_state,listen_master,State};
listen_master(startchild,State) ->
%% 	io:format("~p starting child...~n",[?MODULE]),
	gen_fsm:send_event(self(),check_listeners),
	case gen_fsm:start_link(?MODULE,{State#socket_state.type,State#socket_state.listener,State#socket_state.listen_port,State#socket_state.proplist,self()},[]) of
		{ok,Pid} ->
			erlang:monitor(process,Pid),
			erlang:register(list_to_atom(lists:append(atom_to_list(State#socket_state.type),pid_to_list(Pid))),Pid),
%% 			?FQDEBUG("Started child ~p~n",[Pid]),
			{next_state,listen_master,State#socket_state{listeners = [Pid|State#socket_state.listeners]}};
		Err ->
			?ERROR_MSG("Error starting child: ~p~n",[Err]),
			{next_state,listen_master,State}
	end;
listen_master({child_accepted,Pid},State) ->
	gen_fsm:send_event(self(),check_listeners),
	{next_state,listen_master,State#socket_state{listeners = lists:delete(Pid,State#socket_state.listeners)}}.


accept_http(wait,State) ->
	case gen_tcp:accept(State#worker_state.client_sock) of
		{ok,Sock0} ->
			{ok,Sock} = gen_socket:create(Sock0,gen_tcp),
			gen_fsm:send_event(State#worker_state.parent_pid,{child_accepted,self()}),
			gen_fsm:send_event(self(),get_headers),
%% 			io:format("~p Accepted ~p~n",[?MODULE,Sock]),
			{next_state,http_balance,State#worker_state{client_sock=Sock}};
		{error,timeout} ->
			?INFO_MSG("~p: Accept timeout, retrying.~n",[?MODULE]),
			gen_fsm:send_event(self(),wait),
			{next_state,accept,State};
		Err ->
			?ERROR_MSG("~p: Accept error: ~p~n",[?MODULE,Err]),
			gen_server:cast({State#worker_state.parent_pid,self()}),
			{stop,normal,State}
	end.

http_balance(get_headers,State) ->
	Sock = State#worker_state.client_sock,
	ReqHdr = header_parse:get_headers(Sock,request),
	ProxyPass = #proxy_pass{request=ReqHdr,proxy_type=ReqHdr#header_block.rstr},
	{ok,Pid} = proxy_pass:start(ProxyPass),
	gen_socket:controlling_process(Sock,Pid),
	Port = proplists:get_value(backend_port,State#worker_state.proplist,State#worker_state.listen_port),
	Pool = proplists:get_value(pool,State#worker_state.proplist,undefined),
	gen_fsm:send_event(Pid,{balance,Pool,Port,Sock}),
	{stop,normal,State}.

accept_https({wait,ListenSock},State) ->
%% 	io:format("~p accept_https(),~p",[?MODULE,State]),
	case ssl:transport_accept(ListenSock) of
		{ok,Sock0} ->
			case ssl:ssl_accept(Sock0) of
				ok ->
					{ok,Sock} = gen_socket:create(Sock0,ssl),
					gen_fsm:send_event(State#worker_state.parent_pid,{child_accepted,self()}),
					gen_fsm:send_event(self(),get_headers),
					{next_state,http_balance,State#worker_state{client_sock=Sock}};
				SSLErr ->
					?ERROR_MSG("SSL Error: ~p~n",[SSLErr]),
					{stop,normal,State}
			end;
		{error,timeout} ->
			?INFO_MSG("~p: Accept timeout, retrying.~n",[?MODULE]),
			gen_fsm:send_event(self(),wait),
			{next_state,accept,State};
		Err ->
			?ERROR_MSG("~p: Accept error: ~p~n",[?MODULE,Err]),
			gen_server:cast({State#worker_state.parent_pid,self()}),
			{stop,normal,State}
	end.

%% https_balance(get_headers,State) ->
%% 	{ok,Parse} = header_parse:start_link(),
%% 	Sock = State#worker_state.client_sock,
%% 	ProxyPass = header_parse:receive_ssl_headers(Parse,Sock),
%% 	{ok,Pid} = proxy_pass:start(ProxyPass#proxy_pass{userinfo=balancer}),
%% 	ssl:controlling_process(Sock,Pid),
%% 	Port = proplists:get_value(backend_port,State#worker_state.proplist,State#worker_state.listen_port),
%% 	Pool = proplists:get_value(pool,State#worker_state.proplist,undefined),
%% 	gen_fsm:send_event(Pid,{balance,Pool,Port,Sock}),
%% 	{stop,normal,State}.

%% --------------------------------------------------------------------
%% Func: StateName/3
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% --------------------------------------------------------------------
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

%% --------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%% --------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

%% --------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% --------------------------------------------------------------------
handle_info(_Info, StateName, StateData) ->
    {next_state, StateName, StateData}.

%% --------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%% --------------------------------------------------------------------
terminate(_Reason, _StateName, _StatData) ->
    ok.

%% --------------------------------------------------------------------
%% Func: code_change/4
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState, NewStateData}
%% --------------------------------------------------------------------
code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

%% --------------------------------------------------------------------
%%% Internal functions
%% --------------------------------------------------------------------


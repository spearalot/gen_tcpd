%% -*- coding: utf-8 -*-
%%% ----------------------------------------------------------------------------
%%% Copyright 2008
%%% Martin Carlson, spearalot@gmail.com
%%% Oscar Hellström, oscar@hellstrom.st
%%%
%%% All rights reserved
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are
%%% met:
%%%
%%%     * Redistributions of source code must retain the above copyright
%%%       notice, this list of conditions and the following disclaimer.
%%%     * Redistributions in binary form must reproduce the above copyright
%%%       notice, this list of conditions and the following disclaimer in the
%%%       documentation and/or other materials provided with the distribution.
%%%     * The names of its contributors may not be used to endorse or promote
%%%       products derived from this software without specific prior written
%%%       permission.
%%%
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
%%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED. IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
%%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
%%% SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%%% SUCH DAMAGE.
%%% ----------------------------------------------------------------------------
%%% @copyright 2008 Martin Carlson, Oscar Hellström
%%% @author Martin Carlson <spearalot@gmail.com>
%%% @author Oscar Hellström <oscar@hellstrom.st> [http://oscar.hellstrom.st]
%%% @version {@version}, {@date}, {@time}
%%% @doc
%%% The gen_tcpd behaviour is a generic way of accepting TCP connections.
%%%
%%% As with all OTP behaviours it is using a set of callbacks for the
%%% specific parts of the code.
%%% <pre>
%%% gen_tcpd module            Callback module
%%% ---------------            ---------------
%%% gen_tcpd:start_link -----> Module:init/1
%%% -                   -----> Module:handle_connection/2
%%% -                   -----> Module:handle_info/2
%%% -                   -----> Module:terminate/2
%%% </pre>
%%% == Callbacks ==
%%% <pre>
%%% Module:init(Args) -> Result
%%%     Types Args = term()
%%%           Result = {ok, State} | {stop, Reason}
%%% </pre>
%%% After {@link start_link/5} has been called this function is executed
%%% by the new process to initialise its state. If the initialisation is
%%% successful the function should return <code>{ok, State}</code> where
%%% <code>State</code> is the state which will be passed to the client in
%%% in the next callback. <code>Args</code> is the <code>Args</code> passed
%%% to {@link start_link/5}.
%%%
%%% <pre>
%%% Module:handle_connection(Socket, State) -> void()
%%%     Types Socket = {@link socket()}
%%%           State = term()
%%% </pre>
%%% When a TCP connection is accepted,
%%% `Module:handle_connection(Socket, State)' will be called from a new
%%% process. The process will terminate on return and the connection
%%% will be closed.
%%%
%%% The process which this is called from is linked to the `gen_tcpd'
%%% process. It is allowed to trap exits in the `gen_tcpd' process.
%%% It's also possible to pass the `gen_tcpd' process as
%%% part of the `State' argument to unlink from it.
%%%
%%% It might seem strange that the process is not under a individual
%%% supervisor, but it has been shown that starting children under
%%% supervisors in a vary rapid pace can overload a supervisor and become a
%%% bottleneck in accepting connections.
%%%
%%% <pre>
%%% Module:handle_info(Info, State) -> Result
%%%     Types Info = term()
%%%           State = term()
%%%           Result = noreply | {stop, Reason}
%%%           Reason = term()
%%% </pre>
%%% This function is called if the gen_tcpd process receives any messasge it
%%% dosen't recognise. E.g. <code>{'EXIT', Pid, Reason}</code> messages if
%%% the process is trapping exits.
%%%
%%% <pre>
%%% Module:terminate(Reason, State) -> void()
%%%     Types Reason = term()
%%%           State = term()
%%% </pre>
%%% This function will be called if any of the other callbacks return
%%% <code>{stop, Reason}</code>.
%%%
%%% @type socket()
%%% @end
%%% ----------------------------------------------------------------------------
-module(gen_tcpd).
-behaviour(gen_server).

-export([
	start_link/4,
	start_link/5
]).
-export([
	send/2,
	recv/2,
	recv/3,
	close/1,
	peername/1,
	port/1,
	sockname/1,
	setopts/2,
	controlling_process/2,
	stop/1
]).
-export([
	init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	code_change/3,
	terminate/2
]).
-export([init_acceptor/4]).


-type socket() :: gen_tcp:socket().
-type ip_address() :: inet:ip_address().
-type args() :: term().
-type reason() :: term().
-type cstate() :: term().

-callback init(term()) -> {ok, cstate()} | {stop, reason()}.
-callback terminate(reason(), cstate()) -> any().
-callback handle_info(term(), cstate()) -> noreply | {stop, reason()}.
-callback handle_connection(socket(), cstate()) -> any().
-optional_callbacks([terminate/2, handle_info/2]).

-record(state, {callback    :: {atom(), term()},
                socket      :: undefined | socket()}).

%% @spec start_link(Callback, CallbackArg, Port, Options) -> {ok, Pid}
%% Callback = module()
%% CallbackArg = args()
%% Port = integer()
%% Options = #{socket_options => SocketOptions, acceptors => Acceptors}
%%  
%% SocketOptions = [SocketOpt]
%% Acceptors = integer()
%% Timeout = infinity | integer()
%% Pid = pid()
%% @doc Starts a gen_tcpd process and links to it.
%% @end
-spec start_link(module(), args(), 0..65535, map()) ->
	{ok, pid()} | {error, term()} | ignore.
start_link(Callback, CallbackArg, Port, Options) ->
	Args = [Callback, CallbackArg, Port, Options],
	ok = check_options(Options),
	gen_server:start_link(?MODULE, Args, []).

%% @spec start_link(ServerName, Callback, CallbackArg, Port, Options) -> {ok, Pid}
%% ServerName = {local, Name} | {global, GlobalName}
%% Name = atom()
%% GlobalName = term()
%% Callback = module()
%% CallbackArg = args()
%% Port = integer()
%% Options = #{socket_options => SocketOptions, acceptors => Acceptors}
%% SocketOptions = [SocketOpt]
%% Acceptors = integer()
%% Timeout = infinity | integer()
%% Pid = pid()
%% @doc Starts a gen_tcpd process, links to it and register its name.
%% @end
-spec start_link({local, atom()} | {global, term()}, module(), args(), 0..65535, map()) ->
	{ok, pid()} | {error, term()} | ignore.
start_link(ServerName, Callback, CallbackArg, Port, Options) ->
	Args = [Callback, CallbackArg, Port, Options],
	ok = check_options(Options),
	gen_server:start_link(ServerName, ?MODULE, Args, []).

%% @spec port(Ref) -> Port::integer()
%% Ref = Name | {Name, Node} | {global, GlobalName} | pid()
%% Name = atom()
%% Node = atom()
%% GlobalName = term()
%% @doc
%% Returns the listening port for the gen_tcpd.
%% This is useful if gen_server was called with <code>Port</code> =
%% <code>0</code>.
%% @end
-spec port(pid()) -> 1..65535.
port(Ref) ->
	gen_server:call(Ref, port).

%% @spec stop(Ref) -> ok
%% Ref = Name | {Name, Node} | {global, GlobalName} | pid()
%% Name = atom()
%% Node = atom()
%% GlobalName = term()
%% @doc
%% Stops the gen_tcpd server and frees the listening port.
%% @end
-spec stop(pid()) -> ok.
stop(Ref) ->
	gen_server:cast(Ref, stop).

%% @spec recv(Socket::socket(), Size::integer()) -> Result
%% Result = {ok, Packet} | {error, Reason}
%% Reason = {error, timeout} | {error, posix()}
%% @doc Tries to read <code>Size</code> octets of data from
%% <code>Socket</code>. <code>Size</code> is only relevant if the socket is in
%% raw format.
-spec recv(socket(), non_neg_integer()) ->
	{ok, binary() | list()} | {error, atom()}.
recv(Socket, Size) ->
	gen_tcp:recv(Socket, Size).

%% @spec recv(Socket::socket(), Size::integer(), Timeout::integer()) -> Result
%% Result = {ok, Packet} | {error, Reason}
%% Reason = {error, timeout} | {error, posix()}
%% @doc Tries to read <code>Size</code> octets of data from
%% <code>Socket</code>. <code>Size</code> is only relevant if the socket is in
%% raw format. The recv request will return <code>{error, Timeout}</code> if
%% <code>Size</code> octets of data is not available within
%% <code>Timeout</code> milliseconds.
-spec recv(socket(), non_neg_integer(), timeout()) ->
	{ok, binary() | list()} | {error, atom()}.
recv(Socket, Size, Timeout) ->
	gen_tcp:recv(Socket, Size, Timeout).

%% @spec send(Socket::socket(), Packet) -> ok | {error, Reason}
%% Packet = [char()] | binary()
%% Reason = posix()
%% @doc Sends <code>Packet</code> on <code>Socket</code>.
-spec send(socket(), iolist() | binary()) -> ok | {error, atom()}.
send(Socket, Packet) ->
	gen_tcp:send(Socket, Packet).

%% @spec close(Socket::socket()) -> ok | {error, Reason}
%% Reason = posix()
%% @doc Closes <code>Socket</code>.
-spec close(socket()) -> ok | {error, atom()}.
close(Socket) ->
	gen_tcp:close(Socket).

%% @spec peername(Socket::socket()) -> {ok, {Address, Port}} | {error, Reason}
%% Address = ipaddress()
%% Port = integer()
%% Reason = posix()
%% @doc Returns the remote address and port of <code>Socket</code>.
-spec peername(socket()) -> {ok, {ip_address(), 1..65535}} | {error, atom()}.
peername(Socket) ->
	inet:peername(Socket).

%% @spec sockname(Socket::socket()) -> {ok, {Address, Port}} | {error, Reason}
%% Address = ipaddress()
%% Port = integer()
%% Reason = posix()
%% @doc Returns the local address and port of <code>Socket</code>.
-spec sockname(socket()) -> {ok, {ip_address(), 1..65535}} | {error, atom()}.
sockname(Socket) ->
	inet:sockname(Socket).

%% @spec controlling_process(Socket::socket(), Pid::pid()) ->
%%                                   ok | {error, Reason}
%% Reason = closed | not_owner | posix()
%% @doc Assigns a new controlling process <code>Pid</code> to
%% <code>Socket</code>.
-spec controlling_process(socket(), pid()) ->
	ok | {error, atom()}.
controlling_process(Socket, Pid) ->
	gen_tcp:controlling_process(Socket, Pid).

%% @spec setopts(Socket::socket(), Options) -> ok | {error, Reason}
%% Options = [{Option, Value} | Option]
%% Option = atom()
%% Value = term()
%% Reason = posix()
%% @doc Sets options for a socket.
%% See backend modules for more info.
-spec setopts(socket(), [{atom(), term()} | atom()]) ->
	ok | {error, atom()}.
setopts(Socket, Options) ->
	inet:setopts(Socket, Options).

%% @hidden
-spec init([any()]) ->
	{ok, #state{}} | {stop, #state{}}.
init([Mod, Args, Port, Options]) ->
	Acceptors = maps:get(acceptors, Options, 1),
	SocketOptions = maps:get(socket_options, Options, []),
	case Mod:init(Args) of
		{ok, CState} ->
			case listen(Port, SocketOptions) of
				{ok, Socket} ->
					start_acceptors(Acceptors, Mod, CState, Socket),
					{ok, #state{
						callback = {Mod, CState},
						socket = Socket
					}};
				{error, Reason} ->
					{stop, Reason}
			end;
		{stop, Reason} ->
			try_dispatch(Mod, terminate, Reason, undefined),
			{stop, Reason};
		Other ->
			{stop, {invalid_return_value, Other}}
	end.

%% @hidden
-spec handle_call(any(), {pid(), any()}, #state{}) ->
	{reply, any(), #state{}}.
handle_call(port, _, #state{socket = Socket} = State) ->
	{reply, sock_port(Socket), State};
handle_call(Request, _, State) ->
	{reply, {error, {bad_request, Request}}, State}.

%% @hidden
-spec handle_cast(any(), #state{}) ->
	{noreply, #state{}} | {stop, normal, #state{}}.
handle_cast(stop, State) ->
	{stop, normal, State};
handle_cast(_, State) ->
	{noreply, State}.

%% @hidden
-spec handle_info(any(), #state{}) ->
	{noreply, #state{}} | {stop, any(), #state{}}.
handle_info(Info, State) ->
	{CMod, CState} = State#state.callback,
	case try_dispatch(CMod, handle_info, Info, CState) of
		noreply ->
			{noreply, State};
		{stop, Reason} ->
			{stop, Reason, State};
		Other ->
			exit({invalid_return_value, Other})
	end.

%% @hidden
-spec terminate(any(), #state{}) -> any().
terminate(Reason, #state{callback = {CMod, CState}} = State) ->
	_ = close(State#state.socket),
	try_dispatch(CMod, terminate, Reason, CState).

%% @hidden
-spec code_change(any(), any(), #state{}) ->
	{ok, #state{}}.
code_change(_, _, State) ->
	{ok, State}.

%% @private
start_acceptors(0, _, _, _) ->
	ok;
start_acceptors(Acceptors, Callback, CState, Socket) ->
	Args = [self(), Callback, CState, Socket],
	proc_lib:spawn(?MODULE, init_acceptor, Args),
	start_acceptors(Acceptors - 1, Callback, CState, Socket).

%% @hidden
-spec init_acceptor(pid(), atom(), term(), any()) -> _.
init_acceptor(Parent, Callback, CState, Socket) ->
	try link(Parent)
		catch error:noproc -> exit(normal)
	end,
	put('$ancestors', tl(get('$ancestors'))),
	accept(Parent, Callback, CState, Socket).

accept(Parent, Callback, CState, Socket) ->
	case gen_tcp:accept(Socket) of
		{ok, Client} ->
			Args = [Parent, Callback, CState, Socket],
			proc_lib:spawn(?MODULE, init_acceptor, Args),
			Callback:handle_connection(Client, CState);
		{error, {_, closed}} ->
			unlink(Parent), % no need to send exit signals here
			exit(normal);
		{error, Reason} ->
            erlang:error({error, {{gen_tcp, accept}, Reason}});
		Other ->
			erlang:error(Other)
	end.

listen(Port, Options) ->
	case gen_tcp:listen(Port, Options) of
		{ok, Socket}    -> {ok, Socket};
		{error, Reason} -> {error, {{gen_tcp, listen}, Reason}}
	end.

sock_port(Socket) ->
	element(2, inet:port(Socket)).

check_options(Opts) when is_map(Opts) ->
    SockOpts = maps:get(socket_options, Opts, []),
    Acceptors = maps:get(acceptors, Opts, 1),
    if
        is_list(SockOpts) and is_integer(Acceptors) and (Acceptors > 0) ->
            ok;
        true ->
            erlang:error({bad_option, Opts})
    end;
check_options(Opts) ->
    erlang:error({bad_option, Opts}).

try_dispatch(Mod, Func, Arg, State) ->
    try
        Mod:Func(Arg, State)
    catch
        error:undef = R:Stacktrace ->
            case erlang:function_exported(Mod, Func, 2) of
                false -> noreply;
                true -> erlang:raise(error, R, Stacktrace)
            end
    end.

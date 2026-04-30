-module(mycelium_circuit_relay_masque).

%% Bridge between erlang_masque CONNECT-UDP sessions and the
%% erlang_quic `socket_backend => adapter' API.
%%
%% Given a masque proxy URI and a target `{Host, Port}', this module
%% opens a CONNECT-UDP tunnel and returns an adapter map that can be
%% passed to `quic:connect/4' or registered with
%% `mycelium_dist:set_relay/2' so the next dist `setup/5' to a peer
%% rides the tunnel.
%%
%% The QUIC connection pid is unknown at adapter-construction time
%% (the dist setup path spawns it inside `quic:connect/4'). The bridge
%% process learns it from the first outbound `send_fun' call - the
%% closure captures `self()' of its caller, which is the connection
%% process - and forwards inbound `{masque_data, _, _}' messages to
%% that pid as `{udp, SocketRef, PeerIP, PeerPort, Data}'.

-export([
    open/2,
    open/3,
    wire_to_node/3,
    wire_to_node/4,
    close/1
]).

-export_type([handle/0]).

-type proxy_uri() :: binary() | string().
-type target() :: {inet:hostname() | binary(), inet:port_number()}.

-record(handle, {
    bridge :: pid(),
    socket_ref :: reference(),
    session :: pid(),
    node :: node() | undefined
}).

-opaque handle() :: #handle{}.

%% @equiv open(ProxyURI, Target, #{})
-spec open(proxy_uri(), target()) ->
    {ok, handle(), Adapter :: map()} | {error, term()}.
open(ProxyURI, Target) ->
    open(ProxyURI, Target, #{}).

%% @doc Open a CONNECT-UDP tunnel to `Target' through `ProxyURI' and
%% return a handle plus an adapter map ready to feed
%% `quic:connect/4' (under `socket_adapter') or
%% `mycelium_dist:set_relay/2'.
-spec open(proxy_uri(), target(), masque:connect_opts()) ->
    {ok, handle(), Adapter :: map()} | {error, term()}.
open(ProxyURI, Target, Opts0) ->
    SocketRef = make_ref(),
    Bridge = spawn_link(fun() -> bridge_init(SocketRef, Target) end),
    Opts = Opts0#{owner => Bridge, protocol => udp},
    case masque:connect(ProxyURI, Target, Opts) of
        {ok, Sess} ->
            Bridge ! {session, Sess},
            Handle = #handle{bridge = Bridge, socket_ref = SocketRef, session = Sess},
            Adapter = #{
                send_fun => make_send_fun(Sess, Bridge),
                close_fun => make_close_fun(Bridge),
                socket_ref => SocketRef,
                local => {{127, 0, 0, 1}, 0}
            },
            {ok, Handle, Adapter};
        {error, _} = Err ->
            Bridge ! stop,
            Err
    end.

%% @equiv wire_to_node(Node, ProxyURI, Target, #{})
-spec wire_to_node(node(), proxy_uri(), target()) ->
    {ok, handle()} | {error, term()}.
wire_to_node(Node, ProxyURI, Target) ->
    wire_to_node(Node, ProxyURI, Target, #{}).

%% @doc Open a CONNECT-UDP tunnel and pre-register it with
%% `mycelium_dist' so the next `setup/5' to `Node' rides the tunnel.
%% The caller still has to trigger the dist handshake (typically via
%% `net_kernel:connect_node/1' or by sending a message that touches
%% the node).
-spec wire_to_node(node(), proxy_uri(), target(), masque:connect_opts()) ->
    {ok, handle()} | {error, term()}.
wire_to_node(Node, ProxyURI, Target, Opts) ->
    case open(ProxyURI, Target, Opts) of
        {ok, Handle, Adapter} ->
            ok = mycelium_dist:set_relay(Node, Adapter),
            {ok, Handle#handle{node = Node}};
        {error, _} = Err ->
            Err
    end.

%% @doc Tear down the tunnel and the bridge process. Also clears any
%% pending dist relay registered via `wire_to_node/3,4'.
-spec close(handle()) -> ok.
close(#handle{bridge = Bridge, node = Node}) ->
    case Node of
        undefined -> ok;
        _ -> mycelium_dist:clear_relay(Node)
    end,
    Bridge ! stop,
    ok.

%%====================================================================
%% Internal: bridge process
%%====================================================================

bridge_init(SocketRef, {_PeerHost, PeerPort}) ->
    PeerIP = peer_ip(),
    receive
        {session, Sess} ->
            erlang:monitor(process, Sess),
            bridge_loop(Sess, undefined, undefined, SocketRef, PeerIP, PeerPort);
        stop ->
            ok
    after 30000 ->
        ok
    end.

bridge_loop(Sess, Connection, MRef, SocketRef, PeerIP, PeerPort) ->
    receive
        {sender, Pid} when is_pid(Pid), Connection =:= undefined ->
            NewMRef = erlang:monitor(process, Pid),
            bridge_loop(Sess, Pid, NewMRef, SocketRef, PeerIP, PeerPort);
        {sender, _Pid} ->
            bridge_loop(Sess, Connection, MRef, SocketRef, PeerIP, PeerPort);
        {masque_data, Sess, Data} when is_pid(Connection) ->
            Connection ! {udp, SocketRef, PeerIP, PeerPort, Data},
            bridge_loop(Sess, Connection, MRef, SocketRef, PeerIP, PeerPort);
        {masque_data, Sess, _Data} ->
            %% Drop until the QUIC connection has identified itself.
            bridge_loop(Sess, Connection, MRef, SocketRef, PeerIP, PeerPort);
        {'DOWN', _, process, Sess, _Reason} ->
            ok;
        {'DOWN', MRef, process, Connection, _Reason} ->
            catch masque:close(Sess),
            ok;
        stop ->
            catch masque:close(Sess),
            ok;
        _Other ->
            bridge_loop(Sess, Connection, MRef, SocketRef, PeerIP, PeerPort)
    end.

%%====================================================================
%% Internal: closures
%%====================================================================

%% Capture self() of the caller (the QUIC connection process) so the
%% bridge can target inbound packets at it. Sending the registration
%% on every send is cheap and idempotent.
make_send_fun(Sess, Bridge) ->
    fun(_IP, _Port, Packet) ->
        Bridge ! {sender, self()},
        case masque:send(Sess, Packet) of
            ok -> ok;
            {error, _} = Err -> Err
        end
    end.

make_close_fun(Bridge) ->
    fun() ->
        Bridge ! stop,
        ok
    end.

%% The peer IP we hand the QUIC connection in inbound `{udp, _, IP,
%% Port, _}' messages is symbolic - masque obscures the real source
%% address. Use a fixed loopback so the QUIC connection's
%% `#state.remote_addr' check accepts the packets.
peer_ip() ->
    {127, 0, 0, 1}.

-module(mycelium_circuit_relay_masque).

%% Bridge between erlang_masque CONNECT-UDP sessions and the
%% erlang_quic `socket_backend => adapter' API.
%%
%% Given a masque proxy URI and a target `{Host, Port}', this module
%% opens a CONNECT-UDP tunnel and returns an adapter map that can be
%% passed straight to `quic:connect(_, _, #{socket_backend => adapter,
%% socket_adapter => Adapter}, _)'. Outbound packets sent on that QUIC
%% connection are tunneled through the proxy via `masque:send/2', and
%% inbound `{masque_data, _, _}' messages are reshaped into
%% `{udp, SocketRef, PeerIP, PeerPort, Data}' for the QUIC connection
%% to consume.
%%
%% Currently used as the building block for a future "circuit dist
%% over masque relay" path. The mycelium-side wiring that elects this
%% transport over a hop chain is intentionally not part of this module
%% — see docs/features.md.

-export([
    open/3,
    open/4,
    close/1
]).

-export_type([handle/0]).

-type proxy_uri() :: binary() | string().
-type target() :: {inet:hostname() | binary(), inet:port_number()}.

-record(handle, {
    bridge :: pid(),
    socket_ref :: reference(),
    session :: pid()
}).

-opaque handle() :: #handle{}.

%% @equiv open(ProxyURI, Target, Connection, #{})
-spec open(proxy_uri(), target(), pid()) ->
    {ok, handle(), Adapter :: map()} | {error, term()}.
open(ProxyURI, Target, Connection) ->
    open(ProxyURI, Target, Connection, #{}).

%% @doc Open a CONNECT-UDP tunnel to `Target' through `ProxyURI' and
%% return both the handle (for later `close/1') and the adapter map
%% to pass into `quic:connect/4'.
%%
%% `Connection' is the pid of the QUIC connection process that should
%% receive `{udp, SocketRef, PeerIP, PeerPort, Data}' messages for
%% inbound packets. The same `socket_ref' is embedded in the returned
%% adapter map so the QUIC stack stores it as `#state.socket'.
%%
%% `Opts' is forwarded to `masque:connect/3' (auth headers, transport
%% list, verify/cacerts, etc.).
-spec open(proxy_uri(), target(), pid(), masque:connect_opts()) ->
    {ok, handle(), Adapter :: map()} | {error, term()}.
open(ProxyURI, Target, Connection, Opts0) ->
    SocketRef = make_ref(),
    Self = self(),
    %% The bridge owns the masque session so its `{masque_data, _, _}'
    %% messages land on a process whose only job is reshaping them.
    Bridge = spawn_link(fun() -> bridge_init(Self, Connection, SocketRef, Target) end),
    Opts = Opts0#{owner => Bridge, protocol => udp},
    case masque:connect(ProxyURI, Target, Opts) of
        {ok, Sess} ->
            Bridge ! {session, Sess},
            Handle = #handle{bridge = Bridge, socket_ref = SocketRef, session = Sess},
            Adapter = #{
                send_fun => make_send_fun(Sess),
                close_fun => make_close_fun(Bridge),
                socket_ref => SocketRef,
                local => {{127, 0, 0, 1}, 0}
            },
            {ok, Handle, Adapter};
        {error, _} = Err ->
            Bridge ! stop,
            Err
    end.

%% @doc Tear down the tunnel and the bridge process.
-spec close(handle()) -> ok.
close(#handle{bridge = Bridge}) ->
    Bridge ! stop,
    ok.

%%====================================================================
%% Internal: bridge process
%%====================================================================

%% Owns the masque session, reshapes inbound packets and forwards them
%% to the QUIC connection. The bridge starts before the session pid is
%% known so the spawn is synchronous; the parent feeds the session pid
%% in via `{session, Pid}' once `masque:connect/3' returns.
bridge_init(_Parent, Connection, SocketRef, {_PeerHost, PeerPort}) ->
    PeerIP = peer_ip(),
    receive
        {session, Sess} ->
            erlang:monitor(process, Sess),
            erlang:monitor(process, Connection),
            bridge_loop(Sess, Connection, SocketRef, PeerIP, PeerPort);
        stop ->
            ok
    after 30000 ->
        ok
    end.

bridge_loop(Sess, Connection, SocketRef, PeerIP, PeerPort) ->
    receive
        {masque_data, Sess, Data} ->
            Connection ! {udp, SocketRef, PeerIP, PeerPort, Data},
            bridge_loop(Sess, Connection, SocketRef, PeerIP, PeerPort);
        {'DOWN', _, process, Sess, _Reason} ->
            ok;
        {'DOWN', _, process, Connection, _Reason} ->
            catch masque:close(Sess),
            ok;
        stop ->
            catch masque:close(Sess),
            ok;
        _Other ->
            bridge_loop(Sess, Connection, SocketRef, PeerIP, PeerPort)
    end.

%%====================================================================
%% Internal: closures
%%====================================================================

make_send_fun(Sess) ->
    fun(_IP, _Port, Packet) ->
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
%% Port, _}' messages is symbolic — masque obscures the real source
%% address. Use a fixed loopback so the QUIC connection's
%% `#state.remote_addr' check accepts the packets.
peer_ip() ->
    {127, 0, 0, 1}.

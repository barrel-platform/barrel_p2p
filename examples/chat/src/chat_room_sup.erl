-module(chat_room_sup).
-behaviour(supervisor).

-export([start_link/0, create_room/1, stop_room/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

create_room(Room) ->
    supervisor:start_child(?MODULE, [Room]).

stop_room(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

init([]) ->
    ChildSpec = #{
        id => chat_server,
        start => {chat_server, start_link, []},
        restart => temporary,
        type => worker
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 5, period => 10}, [ChildSpec]}}.

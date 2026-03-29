-module(chat_server).
-behaviour(gen_server).

%% API
-export([start_link/1]).
-export([send/2, join_room/2, leave_room/1, list_rooms/0, get_members/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    room :: atom(),
    members = [] :: [{pid(), reference()}]
}).

%%% API

start_link(Room) ->
    gen_server:start_link(?MODULE, Room, []).

send(Room, Message) ->
    case find_room(Room) of
        {ok, Pid} ->
            gen_server:cast(Pid, {message, node(), Message});
        {error, not_found} ->
            {error, room_not_found}
    end.

join_room(Room, ListenerPid) ->
    case find_room(Room) of
        {ok, Pid} ->
            gen_server:call(Pid, {join, ListenerPid});
        {error, not_found} ->
            {error, room_not_found}
    end.

leave_room(Room) ->
    case find_room(Room) of
        {ok, Pid} ->
            gen_server:call(Pid, {leave, self()});
        {error, not_found} ->
            ok
    end.

list_rooms() ->
    Services = mycelium:list_services(),
    [Room || {chat_room, Room} <- Services].

get_members(Room) ->
    case find_room(Room) of
        {ok, Pid} ->
            gen_server:call(Pid, get_members);
        {error, not_found} ->
            {error, room_not_found}
    end.

%% Internal: find room service, handling both local and remote results
find_room(Room) ->
    case mycelium:whereis_service({chat_room, Room}) of
        {ok, Pid} -> {ok, Pid};
        {ok, _Node, Pid} -> {ok, Pid};
        {error, not_found} -> {error, not_found}
    end.

%%% gen_server callbacks

init(Room) ->
    process_flag(trap_exit, true),
    ServiceName = {chat_room, Room},
    case mycelium:register_service(ServiceName, #{created => erlang:timestamp()}) of
        ok ->
            io:format("[~p] Room '~p' created~n", [node(), Room]),
            {ok, #state{room = Room}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({join, Pid}, _From, State = #state{room = Room, members = Members}) ->
    case lists:keyfind(Pid, 1, Members) of
        false ->
            Ref = monitor(process, Pid),
            io:format("[~p] Process joined room '~p'~n", [node(), Room]),
            {reply, ok, State#state{members = [{Pid, Ref} | Members]}};
        _ ->
            {reply, {error, already_joined}, State}
    end;

handle_call({leave, Pid}, _From, State = #state{room = Room, members = Members}) ->
    case lists:keyfind(Pid, 1, Members) of
        {Pid, Ref} ->
            demonitor(Ref, [flush]),
            io:format("[~p] Process left room '~p'~n", [node(), Room]),
            {reply, ok, State#state{members = lists:keydelete(Pid, 1, Members)}};
        false ->
            {reply, ok, State}
    end;

handle_call(get_members, _From, State = #state{members = Members}) ->
    Pids = [Pid || {Pid, _Ref} <- Members],
    {reply, {ok, Pids}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({message, FromNode, Text}, State = #state{room = Room, members = Members}) ->
    Message = {chat_message, Room, FromNode, Text, erlang:timestamp()},
    lists:foreach(fun({Pid, _Ref}) ->
        Pid ! Message
    end, Members),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, _Reason}, State = #state{room = Room, members = Members}) ->
    case lists:keyfind(Ref, 2, Members) of
        {Pid, Ref} ->
            io:format("[~p] Member left room '~p' (process down)~n", [node(), Room]),
            {noreply, State#state{members = lists:keydelete(Pid, 1, Members)}};
        false ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{room = Room}) ->
    io:format("[~p] Room '~p' shutting down~n", [node(), Room]),
    mycelium:unregister_service({chat_room, Room}),
    ok.

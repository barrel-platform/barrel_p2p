-module(mycelium_hyparview_shuffle).
-behaviour(gen_server).

%% API
-export([start_link/1]).
-export([trigger_shuffle/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {
    shuffle_period :: pos_integer(),
    shuffle_length :: pos_integer(),
    timer_ref :: reference() | undefined
}).

%%====================================================================
%% API
%%====================================================================

start_link(Config) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Config, []).

-spec trigger_shuffle() -> ok.
trigger_shuffle() ->
    gen_server:cast(?SERVER, trigger_shuffle).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Config) ->
    Period = maps:get(shuffle_period, Config, 10000),
    Length = maps:get(shuffle_length, Config, 8),
    State = #state{
        shuffle_period = Period,
        shuffle_length = Length
    },
    {ok, schedule_shuffle(State)}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(trigger_shuffle, State) ->
    do_shuffle(State),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(shuffle_timeout, State) ->
    do_shuffle(State),
    {noreply, schedule_shuffle(State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.timer_ref of
        undefined -> ok;
        Ref -> erlang:cancel_timer(Ref)
    end,
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

schedule_shuffle(State) ->
    Ref = erlang:send_after(State#state.shuffle_period, self(), shuffle_timeout),
    State#state{timer_ref = Ref}.

do_shuffle(State) ->
    case mycelium_hyparview:active_view() of
        [] ->
            ok;
        ActiveNodes ->
            %% Pick random active peer
            Target = lists:nth(rand:uniform(length(ActiveNodes)), ActiveNodes),
            mycelium_hyparview:initiate_shuffle(Target, State#state.shuffle_length)
    end.

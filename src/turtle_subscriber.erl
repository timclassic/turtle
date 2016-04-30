%%% @doc subscribe to a channel, consume messages, process messages by a function
%% This module will subscribe to a target channel and start consuming on the channel.
%% Once consumption is started, it will process each incoming message by invoking a
%% function on each incoming message.
%%% @end
%% @private
-module(turtle_subscriber).
-behaviour(gen_server).
-include_lib("amqp_client/include/amqp_client.hrl").

%% Lifetime
-export([
	start_link/1
]).

%% API
-export([
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
	conn_name,
	name,
	invoke,
	invoke_state = init,
	handle_info = undefined,
	channel,
	channel_ref,
	consumer_tag
 }).

%% LIFETIME MAINTENANCE
%% ----------------------------------------------------------
start_link(Config) ->
    gen_server:start_link(?MODULE, [Config], []).
	
%% CALLBACKS
%% -------------------------------------------------------------------

%% @private
init([#{
        channel := Channel,
        consume_queue := Queue,
        function := Fun,
        connection := ConnName,
        name := Name } = Conf]) ->
    process_flag(trap_exit, true),
    {ok, Tag} = turtle:consume(Channel, Queue),
    MRef = monitor(process, Channel),
    {ok, #state {
        consumer_tag = Tag, 
        invoke = Fun,
        invoke_state = invoke_state(Conf),
        handle_info = handle_info(Conf),
        channel = Channel,
        channel_ref = MRef,
        conn_name = ConnName,
        name = Name }}.

%% @private
handle_call(Call, From, State) ->
    lager:warning("Unknown call from ~p: ~p", [From, Call]),
    {reply, {error, unknown_call}, State}.

%% @private
handle_cast(Cast, State) ->
    lager:warning("Unknown cast: ~p", [Cast]),
    {noreply, State}.

%% @private
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};
handle_info(#'basic.cancel_ok'{}, State) ->
    lager:info("Consumption canceled"),
    {stop, normal, State};
handle_info({#'basic.deliver' {delivery_tag = Tag, routing_key = Key}, Content},
	#state {
	  invoke = Fun, invoke_state = IState,
	  channel = Channel, conn_name = CN, name = N } = State) ->
    S = turtle_time:monotonic_time(),
    try handle_message(Fun, Key, Content, IState, Channel) of
        {ack, IState2} ->
           E = turtle_time:monotonic_time(),
           exometer:update([CN, N, msgs], 1),
           exometer:update([CN, N, latency],
             turtle_time:convert_time_unit(E-S, native, milli_seconds)),
           ok = amqp_channel:cast(Channel, #'basic.ack' { delivery_tag = Tag }),
           {noreply, State#state { invoke_state = IState2 }};
        {reject, IState2} ->
           exometer:update([CN, N, rejects], 1),
           ok = amqp_channel:cast(Channel,
           	#'basic.reject' { delivery_tag = Tag, requeue=true }),
           {noreply, State#state { invoke_state = IState2}};
        {remove, IState2} ->
           exometer:update([CN, N, removals], 1),
           ok = amqp_channel:cast(Channel,
           	#'basic.reject' { delivery_tag = Tag, requeue = false}),
           {noreply, State#state { invoke_state = IState2}};
        {stop, Reason, IState2} ->
            ok = amqp_channel:cast(Channel,
            	#'basic.reject' { delivery_tag = Tag, requeue = true }),
            {stop, Reason, State#state { invoke_state = IState2}};
        ok ->
           {noreply, State}
    catch
        Class:Error ->
           lager:error("Handler function crashed: {~p, ~p}, stack: ~p, content: ~p",
               [Class, Error, erlang:get_stacktrace(), format_amqp_msg(Content)]),
           lager:error("Mailbox size ~p", [erlang:process_info(self(), message_queue_len)]),
           ok = amqp_channel:call(Channel, #'basic.reject' { delivery_tag = Tag, requeue = false }),
           {stop, {Class, Error}, State}
    end;
handle_info({'DOWN', MRef, process, _, normal}, #state { channel_ref = MRef } = State) ->
    {stop, normal, State#state { channel = none }};
handle_info({'DOWN', MRef, process, _, Reason}, #state { channel_ref = MRef } = State) ->
    {stop, {channel_down, Reason}, State#state { channel = none }};
handle_info(Info, #state { handle_info = undefined } = State) ->
    lager:warning("Unknown info message: ~p", [Info]),
    {noreply, State};
handle_info(Info, #state { handle_info = HandleInfo, invoke_state = IState } = State) ->
    try HandleInfo(Info, IState) of
        {ok, IState2} -> {noreply, State#state { invoke_state = IState2 }}
    catch
        Class:Error ->
            lager:error("Handle info crashed: {~p, ~p}, stack: ~p",
                [Class, Error, erlang:get_stacktrace()]),
            {stop, {Class, Error}, State}
    end.

%% @private
terminate(_, #state { consumer_tag = Tag, channel = Ch }) when is_pid(Ch) ->
    turtle:cancel(Ch, Tag),
    await_cancel_ok(),
    %% Once we know we have cancellation, drain the queue of the remaining
    %% messages.
    drain_reject_messages(Ch),
    ok;    
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_, State, _) ->
    {ok, State}.

%%
%% INTERNAL FUNCTIONS
%%
handle_message(Fun, Key,
	#amqp_msg {
	    payload = Payload,
	    props = #'P_basic' {
	        content_type = Type,
	        correlation_id = CorrID,
	        reply_to = ReplyTo } = Props}, IState, Channel) ->
    Return = case erlang:fun_info(Fun, arity) of
                 {arity, 4} -> Fun(Key, Type, Payload, IState);
                 {arity, 5} -> Fun(Key, Type, Payload, Props, IState)
             end,
    case Return of
        ack -> {ack, IState};
        {ack, IState2} -> {ack, IState2};
        {reply, CType, Msg} ->
            reply(Channel, CorrID, ReplyTo, CType, Msg),
            {ack, IState};
        {reply, CType, Msg, #'P_basic'{} = RProps} ->
            reply(Channel, CorrID, ReplyTo, CType, Msg, RProps),
            {ack, IState};
        {reply, CType, Msg, IState2} ->
            reply(Channel, CorrID, ReplyTo, CType, Msg),
            {ack, IState2};
        {reply, CType, Msg, RProps, IState2} ->
            reply(Channel, CorrID, ReplyTo, CType, Msg, RProps),
            {ack, IState2};
        reject -> {reject, IState};
        {reject, IState2} -> {reject, IState2};
        remove -> {remove, IState};
        {remove, IState2} -> {remove, IState2};
        {stop, Reason, IState2} -> {stop, Reason, IState2};
        ok -> ok
    end.
    
format_amqp_msg(#amqp_msg { payload = Payload, props = Props }) ->
    Pl = case byte_size(Payload) of
        K when K < 64 -> Payload;
        _ ->
            <<Cut:64/binary, _/binary>> = Payload,
            Cut
    end,
    {Pl, Props}.

%% Compute the initial state of the function
invoke_state(#{ init_state := S }) -> S;
invoke_state(_) -> init.

handle_info(#{ handle_info := Handler }) -> Handler;
handle_info(_) -> undefined.


reply(Ch, CorrID, ReplyTo, CType, Msg) ->
    reply(Ch, CorrID, ReplyTo, CType, Msg, #'P_basic'{}).

reply(_Ch, _CorrID, undefined, _CType, _Msg, _Props) ->
    lager:warning("Replying to target with no reply-to queue defined"),
    ok;
reply(Ch, CorrID, ReplyTo, CType, Msg, Props) ->
    Publish = #'basic.publish' {
        exchange = <<>>,
        routing_key = ReplyTo
    },
    NewProps = Props#'P_basic' { content_type = CType, correlation_id = CorrID },
    AMQPMsg = #amqp_msg { props = NewProps, payload = Msg},
    amqp_channel:cast(Ch, Publish, AMQPMsg).

await_cancel_ok() ->
    receive
       #'basic.cancel_ok'{} ->
           ok
    after 5000 ->
           lager:error("No basic.cancel_ok received"),
           not_cancelled
    end.

drain_reject_messages(Channel) ->
    receive
        {#'basic.deliver' {delivery_tag = Tag }, _Content} ->
            ok = amqp_channel:call(Channel,
                #'basic.reject' { delivery_tag = Tag, requeue = true }),
            drain_reject_messages(Channel)
    after 0 ->
        ok
    end.

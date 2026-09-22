-module(music_synth).

-export([prepare/1, prepare/2, render/1, tracks/1]).

-define(RATE, 44100).
-define(CHUNK, 4410).
-define(PI2, 6.283185307179586).

prepare(Module) ->
    prepare(Module, all).

prepare(Module, Selection) ->
    {module, Module} = code:ensure_loaded(Module),
    Bpm = Module:bpm(),
    case select_tracks(Module:tracks(), Selection) of
        {ok, Selected} -> prepare_tracks(Selected, Bpm);
        {error, _} = Error -> Error
    end.

tracks(Module) ->
    {module, Module} = code:ensure_loaded(Module),
    numbered_presets(Module:tracks(), 1).

numbered_presets([], _) -> [];
numbered_presets([{Preset, _} | Rest], Number) ->
    [{Number, Preset} | numbered_presets(Rest, Number + 1)].

select_tracks(Tracks, all) ->
    {ok, Tracks};
select_tracks(Tracks, {solo, Number}) when is_integer(Number), Number > 0 ->
    case Number =< length(Tracks) of
        true -> {ok, [lists:nth(Number, Tracks)]};
        false -> {error, {track_out_of_range, Number}}
    end;
select_tracks(Tracks, {mute, Numbers}) when is_list(Numbers) ->
    Count = length(Tracks),
    case lists:all(fun(Number) ->
                           is_integer(Number) andalso Number > 0 andalso Number =< Count
                   end, Numbers) of
        true ->
            Indexed = lists:zip(lists:seq(1, Count), Tracks),
            {ok, [Track || {Number, Track} <- Indexed,
                           not lists:member(Number, Numbers)]};
        false -> {error, bad_track_selection}
    end;
select_tracks(_, _) ->
    {error, bad_track_selection}.

prepare_tracks(Tracks, Bpm) ->
    {Voices, _} = lists:foldl(
      fun(Track, {Vs, Id}) -> track(Track, Bpm, Id, Vs) end,
      {[], 1}, Tracks),
    Total = lists:foldl(fun({_, _, _, End, _, _}, N) -> max(End, N) end, 0, Voices),
    #{voices => Voices, total => Total, pos => 0}.

render(#{pos := Pos, total := Total}) when Pos >= Total -> done;
render(State = #{voices := Voices, total := Total, pos := Pos}) ->
    Count = min(?CHUNK, Total - Pos),
    Last = Pos + Count,
    Active = [V || V = {_, Start, _, End, _, _} <- Voices,
                   Start < Last, End > Pos],
    PCM = iolist_to_binary([pcm(sample(I, Active)) || I <- lists:seq(Pos, Last - 1)]),
    {PCM, State#{pos := Last}}.

pitch(Note) when is_atom(Note) ->
    [Letter | Rest0] = atom_to_list(Note),
    {Sharp, Rest} = case Rest0 of [$s | R] -> {1, R}; _ -> {0, Rest0} end,
    Base = case Letter of
               $c -> 0; $d -> 2; $e -> 4; $f -> 5;
               $g -> 7; $a -> 9; $b -> 11
           end,
    Octave = list_to_integer(Rest),
    Midi = (Octave + 1) * 12 + Base + Sharp,
    440.0 * math:pow(2.0, (Midi - 69) / 12).

beat_sample(Beat, Bpm) -> round(Beat * 60 * ?RATE / Bpm).

track({Preset, Events}, Bpm, Id, Acc) ->
    lists:foldl(fun(Event, {Vs, Next}) ->
                        event(Event, Preset, Bpm, Next, Vs)
                end, {Acc, Id}, Events).

event(Beat, Preset, Bpm, Id, Acc) when is_number(Beat) ->
    Start = beat_sample(Beat, Bpm),
    End = Start + round(tail(Preset) * ?RATE),
    {[{Preset, Start, Start, End, 0.0, Id} | Acc], Id + 1};
event({Beat, Duration, Notes}, Preset, Bpm, Id, Acc) ->
    Start = beat_sample(Beat, Bpm),
    Gate = beat_sample(Beat + Duration, Bpm),
    End = Gate + round(tail(Preset) * ?RATE),
    Pitches = case Notes of N when is_atom(N) -> [N]; T when is_tuple(T), tuple_size(T) > 0 -> tuple_to_list(T) end,
    lists:foldl(fun(Note, {Vs, Next}) ->
                        {[{Preset, Start, Gate, End, pitch(Note), Next} | Vs], Next + 1}
                end, {Acc, Id}, Pitches).

tail(kick) -> 0.45;
tail(snare) -> 0.30;
tail(closed_hat) -> 0.08;
tail(tom) -> 0.35;
tail(cymbal) -> 0.75;
tail(bass) -> 0.04;
tail(lead) -> 0.12;
tail(pad) -> 0.50;
tail(piano) -> 0.30;
tail(organ) -> 0.10;
tail(guitar) -> 0.20;
tail(strings) -> 0.40;
tail(brass) -> 0.16.

sample(I, Voices) ->
    clamp(lists:sum([voice(I, V) || V <- Voices]) * 0.1).

voice(I, {_, Start, _, _, _, _}) when I < Start -> 0.0;
voice(I, {_, _, _, End, _, _}) when I >= End -> 0.0;
voice(I, {Preset, Start, Gate, _End, Freq, Seed}) ->
    T = (I - Start) / ?RATE,
    G = (Gate - Start) / ?RATE,
    tone(Preset, T, G, Freq, I, Seed).

tone(kick, T, _, _, _, _) ->
    0.9 * math:sin(?PI2 * (140 * T - 90 * T * T)) * math:exp(-9 * T);
tone(snare, T, _, _, I, Seed) ->
    0.45 * noise(I, Seed) * math:exp(-14 * T) +
    0.25 * math:sin(?PI2 * 180 * T) * math:exp(-18 * T);
tone(closed_hat, T, _, _, I, Seed) ->
    0.22 * noise(I, Seed) * math:exp(-55 * T);
tone(tom, T, _, _, _, _) ->
    0.45 * math:sin(?PI2 * (150 * T - 35 * T * T)) * math:exp(-8 * T);
tone(cymbal, T, _, _, I, Seed) ->
    0.18 * noise(I, Seed) * math:exp(-5 * T) +
    0.05 * square(?PI2 * 6200 * T) * math:exp(-9 * T);
tone(bass, T, G, F, _, _) ->
    0.32 * square(?PI2 * F * T) * envelope(T, G, 0.005, 0.04);
tone(lead, T, G, F, _, _) ->
    0.22 * saw(?PI2 * F * T) * envelope(T, G, 0.01, 0.12);
tone(pad, T, G, F, _, _) ->
    0.12 * triangle(?PI2 * F * T) * envelope(T, G, 0.18, 0.50);
tone(piano, T, G, F, _, _) ->
    (0.18 * math:sin(?PI2 * F * T) +
     0.08 * math:sin(?PI2 * F * 2 * T) +
     0.03 * math:sin(?PI2 * F * 3 * T)) *
    math:exp(-1.3 * T) * envelope(T, G, 0.004, 0.30);
tone(organ, T, G, F, _, _) ->
    (0.13 * math:sin(?PI2 * F * T) +
     0.07 * math:sin(?PI2 * F * 2 * T) +
     0.04 * math:sin(?PI2 * F * 3 * T)) * envelope(T, G, 0.02, 0.10);
tone(guitar, T, G, F, _, _) ->
    0.20 * triangle(?PI2 * F * T) * math:exp(-0.9 * T) *
    envelope(T, G, 0.003, 0.20);
tone(strings, T, G, F, _, _) ->
    (0.08 * saw(?PI2 * F * T) + 0.05 * triangle(?PI2 * F * 1.003 * T)) *
    envelope(T, G, 0.10, 0.40);
tone(brass, T, G, F, _, _) ->
    (0.13 * square(?PI2 * F * T) + 0.06 * math:sin(?PI2 * F * T)) *
    envelope(T, G, 0.025, 0.16).

envelope(T, _Gate, Attack, _Release) when T < Attack -> T / Attack;
envelope(T, Gate, _Attack, _Release) when T < Gate -> 1.0;
envelope(T, Gate, _Attack, Release) -> max(0.0, 1.0 - (T - Gate) / Release).

square(Phase) -> case math:sin(Phase) >= 0 of true -> 1.0; false -> -1.0 end.
saw(Phase) -> 2.0 * (Phase / ?PI2 - math:floor(Phase / ?PI2)) - 1.0.
triangle(Phase) -> 2.0 * abs(saw(Phase)) - 1.0.

noise(I, Seed) ->
    X = (I * 1103515245 + Seed * 12345) band 16#7fffffff,
    X / 1073741824.0 - 1.0.

clamp(X) when X > 1.0 -> 1.0;
clamp(X) when X < -1.0 -> -1.0;
clamp(X) -> X.

pcm(X) -> <<(round(X * 32767)):16/little-signed>>.

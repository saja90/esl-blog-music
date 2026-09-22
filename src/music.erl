-module(music).

-export([play/1, play/2, tracks/1]).

play(Song) when is_atom(Song) ->
    music_player:play(Song);
play(_) ->
    {error, bad_song_module}.

play(Song, Selection) when is_atom(Song) ->
    music_player:play(Song, Selection);
play(_, _) ->
    {error, bad_song_module}.

tracks(Song) when is_atom(Song) ->
    music_synth:tracks(Song);
tracks(_) ->
    {error, bad_song_module}.


# Chiptune synthesizer in Erlang

## (esl-blog-music fork)

### Adding Linux support

To be able to compile on debian based system, install erlang and rebar from standard package repository and run `rebar3 compile`.
To try it out, need to use `erl music.app` in the _build/default/lib/music/ebin directory.
Then within the erlang shell you can use `music_player:play(demo_song).` to try it out.

### TODO

Write easy-to-use script to control the compilation and application.

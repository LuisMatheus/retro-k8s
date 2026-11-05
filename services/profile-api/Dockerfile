FROM elixir:1.19.6-otp-26

ENV MIX_ENV=prod MIX_HOME=/opt/mix HEX_HOME=/tmp/hex HOME=/tmp PHX_SERVER=true
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
RUN mix compile && chmod -R a+rX /app /opt/mix
USER 1000:1000
EXPOSE 4000
CMD ["sh", "-c", "mix ecto.migrate && exec mix phx.server"]

REBAR3_URL=https://s3.amazonaws.com/rebar3/rebar3

# If there is a rebar in the current directory, use it
ifeq ($(wildcard rebar3),rebar3)
REBAR3 = $(CURDIR)/rebar3
endif

# Fallback to rebar on PATH
REBAR3 ?= $(shell which rebar3)

# And finally, prep to download rebar if all else fails
ifeq ($(REBAR3),)
REBAR3 = $(CURDIR)/rebar3
endif

clean: $(REBAR3)
	@$(REBAR3) clean
	rm -rf _build

all: $(REBAR3)
	@$(REBAR3) do clean, compile, eunit, ct, dialyzer

rel: all
	@$(REBAR3) release

$(REBAR3):
	curl -Lo rebar3 $(REBAR3_URL) || wget $(REBAR3_URL)
	chmod a+x rebar3

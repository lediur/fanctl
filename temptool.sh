#!/usr/bin/bash

# Temperature script for ambient thermometer
# Place `temper.py` from https://github.com/urwen/temper in working dir
# Must have `jq` installed

./temper.py --json | jq '.[0]."internal temperature" - 1'

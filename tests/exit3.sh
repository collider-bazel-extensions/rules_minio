#!/usr/bin/env bash
# Inner test for server_died_test: fails on its own with status 3.
[[ "$#" == 2 && "$1" == a && "$2" == b ]] || exit 9
exit 3

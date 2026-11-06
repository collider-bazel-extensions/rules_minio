#!/usr/bin/env bash
# Inner test for server_died_test: stops the server behind the launcher's
# back (not minio_stop), then would carry on.
source "$MINIO_TESTLIB"
mc admin service stop minio >/dev/null 2>&1 || true
sleep 60
echo "BODY FINISHED"

#!/bin/bash
# Model one installer parent so the competing managers exercise the inner
# domain and route locks even after installation-wide exclusion was added.
exec {KVS_SCRIPTS_LOCK_FD}>> "$1/.kvs-scripts.lock"
flock -xn "$KVS_SCRIPTS_LOCK_FD"
export KVS_SITE_LOCKS_INHERITED=1

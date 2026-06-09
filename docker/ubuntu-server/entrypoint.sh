#!/bin/bash
set -e

service ssh start
nginx -g "daemon off;"

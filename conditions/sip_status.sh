#!/bin/bash


script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$script_dir/lib/util.sh"


set_fact sip_status "$( /usr/bin/csrutil status || echo "Unknown" )"

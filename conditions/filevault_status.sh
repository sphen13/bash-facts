#!/bin/bash


script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$script_dir/lib/util.sh"


set_fact filevault_status "$( /usr/bin/fdesetup status || echo "Unknown" )"

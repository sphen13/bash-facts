#!/bin/bash


script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$script_dir/lib/util.sh"


admins=( $( dscacheutil -q group -a name admin | grep '^users:' | cut -d" " -f2- ) )
set_fact admin_users array string "${admins[@]}"

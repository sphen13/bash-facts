#!/bin/bash


script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$script_dir/lib/util.sh"


cd /Users
user_dirs=()
for name in *; do
    case "$name" in
    "Deleted Users" | "Shared" | "admin")
        continue
        ;;
    *)
        user_dirs+=("$name")
        ;;
    esac
done

set_fact local_user_dirs array string "${user_dirs[@]}"

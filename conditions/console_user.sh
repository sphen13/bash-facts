#!/bin/bash


script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$script_dir/lib/util.sh"


console_user=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
set_fact console_user string "$console_user"
case "$console_user" in
"" | "root" | "loginwindow" | "_mbsetupuser")
	set_fact console_user_logged_in bool false
	;;
*)
	set_fact console_user_logged_in bool true
	;;
esac

#!/bin/bash


script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$script_dir/lib/util.sh"


if is_virtual; then
	set_fact physical_or_virtual "virtual"
else
	set_fact physical_or_virtual "physical"
fi

## Introduction

This is a collection of "admin-provided conditions" for Munki as described [here.](https://github.com/munki/munki/wiki/Conditional-Items#admin-provided-conditions)

`munki-facts` used to be a set of Python modules with a common runner to generate facts. With the removal of Python in munki 7 they have instead been ported to bash to provide a smooth upgrade path for organizations that previously deployed the Python facts.

## Usage

The shell scripts and the `lib` directory should be installed in `/usr/local/munki/conditions`.
The scripts must be marked as executable.

Munki will run the scripts and insert any facts they generate into the dictionary of items that are used in [manifest `conditional_items` predicates](https://github.com/munki/munki/wiki/Conditional-Items) and in [`installable_condition` items in pkginfo files](https://github.com/munki/munki/wiki/Pkginfo-Files#installable_condition).

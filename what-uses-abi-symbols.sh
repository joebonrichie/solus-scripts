#!/bin/bash

# A dirty bash script to find packages that use abi symbols
# Mostly useful when a package update stops providing some symbols
# and we need to check if any packages use said symbols to mark them to be rebuilt.

# Uses https://github.com/DataDrake/abi-wizard but standard tools like objdump and nm can also be used.

PACKAGES="$(cat "/home/ninya/Downloads/glibc-2.32-requires-rebuild.txt")"

PACKAGE_COUNT=`cat packages.txt | wc -w`

for i in ${PACKAGES}
do
	var=$((var+1))
	echo "Checking package" ${i} ${var} "out of" ${PACKAGE_COUNT}
	mkdir ${i}
	pushd ${i}
	eopkg fetch ${i}
	uneopkg *.eopkg
    ~/abi-wizard/abi-wizard install/
	# Relies on the exit codes of grep
	# !! Put your own symbols here
	if egrep -c 'libpthread.so.0:pthread_sigmask|libpthread.so.0:pthread_getattr_np' abi_used_symbols
	then
		echo "Found match against ${i} ${BINARY}"
		echo -e ${i} >> ~/glibc-2.32-libpthread-matches.txt
	fi
	popd
	rm -r ${i}
done

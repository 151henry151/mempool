#!/bin/bash
DESTDIR=/dev/shm/mempool-btc
MEMPOOLHOME=/home/mempool/mempool

# the path to a dir containing your bitcoin-cli
PATH="$PATH":/usr/local/bin

mempool=$MEMPOOLHOME/mempool.log

# do not dump the raw mem pool while the last pass is still running
dump_lock=$DESTDIR/LOCK

# do not attempt to handle the same set of data twice at the same time
data_lock=$DESTDIR/DATALOCK

order=(2h 8h 24h 2d 4d 1w 2w 30d 3m 6m 1y)
declare -A intervals=(
	[2h]=1
	[8h]=1
	[24h]=1
	[2d]=2
	[4d]=4
	[1w]=7
	[2w]=14
	[30d]=30
	[3m]=90
	[6m]=180
	[1y]=360
)

declare -A period_minutes=(
	[2h]=120
	[8h]=480
	[24h]=1440
	[2d]=2880
	[4d]=5760
	[1w]=10080
	[2w]=20160
	[30d]=43200
	[3m]=131040
	[6m]=262080
	[1y]=524160
)

is-locked () {
	[[ -e $1 ]]
}

make-lock () {
	if is-locked "$1"; then
		return 1
	fi
	mkdir -p -- "$1" 2>/dev/null
}

rm-lock () {
	rmdir -- "$1" 2>/dev/null
}

create-js () {
	local name="$1" data="$2"
	local tmp=$(mktemp -p "$DESTDIR")
	printf 'call([\n%s\n])\n' "$data" > "$tmp"
	mv -- "$tmp" "$DESTDIR/$name.js"
}

create-missing-js () {
	local name="$1" data="$2"
	[[ -f $DESTDIR/${name}.js ]] && return
	create-js "$name" "$data"
}

mempool-filtered () {
	local lines="$1" interval="$2"

	if [[ -z $lines ]] ; then
		# include only the trailing number of lines
		if [[ -z $interval ]] ; then
			 : be reasonable
			# include lines only every so often
		else
			sed -ne "1~${interval}p" "$mempool"
		fi
	else
		if [[ -z $interval ]] ; then
			tail -n "$lines" "$mempool"
		else
			tail -n "$lines" "$mempool" | sed -ne "1~${interval}p"
		fi
	fi
}

# create the JSON files delivering the summarized mempool
mkdata () {
	local period minutes interval
	for period in "${order[@]}" ; do
		minutes="${period_minutes[$period]}"
		interval="${intervals[$period]}"

		if [[ $interval == 1 ]] ; then
			interval=
		fi

		create-missing-js "$period" "$(mempool-filtered "$minutes" "$interval")"
	done

	# all is special
	create-missing-js all "$(mempool-filtered '' 360)"
}

# cycle the first line of data out, add a new line at the end
rewrite-js () {
	local name="$1" data="$2"
	if ! [[ -f $DESTDIR/${name}.js ]] ; then
		printf '%s: no such file. Did mkdata run OK?\n' "$DESTDIR"/"${name}.js"
		exit 1
	fi
	sed -i -e $'2d;/^\])$/i'"$data"$'\n' "$DESTDIR"/"$name".js

}

# update the JSON files delivering the summarized mempool
#
# LINE is set to the last line in mempool.
# for each file:
#   check if current minute divisible by IVAL
#   if divisible:
#      remove first line (after 'call([').
#      add LINE to this file (before last line '])').
updatedata () {
	local minute_boundary=$(( $(date +%s) / 60 ))
	local line=$(tail -n 1 "$mempool")
	local period

	for period in "${order[@]}" ; do
		interval="${intervals[$period]}"

		if [[ $(( minute_boundary % interval )) -eq 0 ]] ; then
			rewrite-js "$period" "$line"
		fi
	done

	# all is different; the entire file gets replaced with just the line. Apparently
	if [[ $(( minute_boundary % 360 )) -eq 0 ]] ; then
		create-js all "$line"
	fi
}

cd "$MEMPOOLHOME" || exit 1

if ! make-lock "$dump_lock" ; then
	# locked or could not take lock
	printf 'unable to take lock "%s" -- is another copy already running?\n' "$dump_lock"
	exit
fi


tmp=$(mktemp -p "$MEMPOOLHOME")
bitcoin-cli getrawmempool true > "$tmp"

# internally appends to mempool.log
python mempool_sql.py < "$tmp"

# create ram-disk directory if it does not exists
if ! [[ -e $DESTDIR ]] ; then
	mkdir -p "$DESTDIR"
fi

# read mempool.log once sequentially to quickly load it in buffers
cat "$mempool" >/dev/null

# initialize
mkdata

# unlock
rm-lock "$dump_lock" || {
	printf 'unable to release lock "%s"\n' "$dump_lock"
	exit 1
}

# update ram-disk directory, protected by DATALOCK
if ! make-lock "$data_lock" ; then
	printf 'unable to take lock "%s" -- is another copy already running?\n' "$data_lock"
	exit
fi

updatedata

rm-lock "$data_lock"

# be sure to report success back to cron unconditionally
exit 0

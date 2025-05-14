RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
PLAIN='\033[0m'
START_SEC=$(date +%s)

_usage_msg() {
	local msg="$1"
	echo -e "${RED}usage:${PLAIN} $msg"
	_usage
}

_usage() {
	exit 22
}

_err() {
	local msg="$1"
	echo -e "${RED}FAIL:${PLAIN} $msg"
}

_fail() {
	_err $@
	exit 1
}

_ok() {
	echo -e "${GREEN}OK${PLAIN}"
	exit 0
}

_kmsg() {
	echo $@ > /dev/kmsg
}

_log() {
	echo -e "${BLUE}$@${PLAIN}"
	_kmsg $@
}

_sleep() {
	local time=${1-60}
	local now=$(date +%s)
	local end=$((now + time))
	while [ $now -lt $end ];
	do
		echo "SLEEP: $((end - now))s left. Sleep 10."
		sleep 10
		now=$(date +%s)
	done
}

_elapsed() {
	echo "elapsed: $(($(date +%s) - $START_SEC))"
}

_pid() {
	exec sh -c 'echo "$PPID"'
}

_cleanup() {
	for pid in ${PIDS[@]}
	do
		_log "kill spawned pid $pid"
		kill $pid
	done
	wait
}
